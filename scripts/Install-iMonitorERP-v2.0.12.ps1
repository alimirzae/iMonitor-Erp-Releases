[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = (Get-Location).Path,
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) { throw 'Run PowerShell as Administrator.' }

$repo = 'alimirzae/iMonitor-Erp-Releases'
$assetName = 'iMonitor-EcomERP-win-x64.zip'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$PackageCacheDirectory = [IO.Path]::GetFullPath($PackageCacheDirectory)
$stateRoot = Join-Path $InstallRoot 'state'
$installerHome = Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $InstallRoot,$PackageCacheDirectory,$stateRoot,$installerHome | Out-Null

Write-Host "iMonitor ERP installer v2.0.12" -ForegroundColor Cyan
Write-Host "Install root : $InstallRoot"
Write-Host "Package cache: $PackageCacheDirectory"
Write-Host "Channel      : $Channel"

function Invoke-CurlDownload([string]$Uri,[string]$OutFile,[string]$Label,[int]$MaxTime = 300) {
    $curl = Get-Command curl.exe -ErrorAction Stop
    $last = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Host "$Label (attempt $attempt/4)..."
            & $curl.Source -4 --http1.1 --fail --location --connect-timeout 8 --max-time $MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.12' $Uri -o $OutFile
            $exit = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            if ($exit -ne 0) { throw "curl exit code $exit" }
            if (-not (Test-Path $OutFile -PathType Leaf) -or (Get-Item $OutFile).Length -le 0) { throw 'Downloaded file is empty.' }
            return
        } catch {
            $last = $_.Exception.Message
            Start-Sleep -Seconds ([Math]::Min($attempt * 2, 6))
        }
    }
    throw "$Label failed. Last error: $last"
}

function Ensure-IISInstalled {
    $iisInstalled = Test-Path "$env:windir\System32\inetsrv\appcmd.exe"
    if (-not $iisInstalled) {
        Write-Host 'IIS is not installed. Installing IIS and management tools...' -ForegroundColor Yellow
        $serverFeature = Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue
        if ($serverFeature) {
            Install-WindowsFeature Web-Server,Web-WebSockets -IncludeManagementTools | Out-Null
        } else {
            $features = @(
                'IIS-WebServerRole',
                'IIS-WebServer',
                'IIS-CommonHttpFeatures',
                'IIS-StaticContent',
                'IIS-DefaultDocument',
                'IIS-HttpErrors',
                'IIS-HealthAndDiagnostics',
                'IIS-HttpLogging',
                'IIS-Performance',
                'IIS-HttpCompressionStatic',
                'IIS-Security',
                'IIS-RequestFiltering',
                'IIS-ApplicationDevelopment',
                'IIS-WebSockets',
                'IIS-ManagementConsole'
            )
            foreach ($feature in $features) {
                try { Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop | Out-Null }
                catch { Write-Verbose "Optional IIS feature $feature: $($_.Exception.Message)" }
            }
        }
    }

    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Test-Path 'IIS:\')) { throw 'IIS installation completed but WebAdministration provider is unavailable.' }
    Write-Host '[OK] IIS is installed.' -ForegroundColor Green
}

function Test-AspNetCore8Runtime {
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $false }
    try {
        $runtimes = & $dotnet.Source --list-runtimes 2>$null
        return [bool]($runtimes | Where-Object { $_ -match '^Microsoft\.AspNetCore\.App 8\.' })
    } catch { return $false }
}

function Test-AspNetCoreModuleV2 {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        return [bool](Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Ensure-DotNet8HostingBundle {
    $runtimeOk = Test-AspNetCore8Runtime
    $moduleOk = Test-AspNetCoreModuleV2
    if ($runtimeOk -and $moduleOk) {
        Write-Host '[OK] .NET 8 ASP.NET Core runtime and IIS Hosting Module are installed.' -ForegroundColor Green
        return
    }

    Write-Host ".NET 8 Hosting Bundle is missing/incomplete (runtime=$runtimeOk, IISModule=$moduleOk). Installing..." -ForegroundColor Yellow
    $installer = Join-Path $env:TEMP 'dotnet-hosting-8-win.exe'
    Invoke-CurlDownload 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe' $installer '.NET 8 Hosting Bundle download' 600
    try {
        $p = Start-Process -FilePath $installer -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
        if ($p.ExitCode -notin @(0,1641,3010)) { throw ".NET Hosting Bundle installer returned exit code $($p.ExitCode)." }
    } finally {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }

    & "$env:windir\System32\inetsrv\appcmd.exe" stop apppool /apppool.name:DefaultAppPool 2>$null | Out-Null
    & iisreset.exe /restart | Out-Null
    $global:LASTEXITCODE = 0

    if (-not (Test-AspNetCore8Runtime)) { throw '.NET 8 ASP.NET Core runtime is still unavailable after Hosting Bundle installation.' }
    if (-not (Test-AspNetCoreModuleV2)) { throw 'ASP.NET Core Module V2 is still unavailable in IIS after Hosting Bundle installation.' }
    Write-Host '[OK] .NET 8 Hosting Bundle installed.' -ForegroundColor Green
}

function Grant-AppPoolAccess([string]$PoolName) {
    $identity = "IIS AppPool\$PoolName"
    & icacls.exe $InstallRoot /grant "${identity}:(OI)(CI)M" /T /C /Q | Out-Null
    $global:LASTEXITCODE = 0
}

function Ensure-IISChannel([string]$Name,[int]$Port) {
    Import-Module WebAdministration -ErrorAction Stop
    $poolName = "iMonitorERP-$Name"
    $base = Join-Path $InstallRoot $Name.ToLowerInvariant()
    $current = Join-Path $base 'current'
    New-Item -ItemType Directory -Force -Path $base,$current | Out-Null

    if (-not (Test-Path "IIS:\AppPools\$poolName")) {
        Write-Host "Creating IIS app pool: $poolName"
        New-WebAppPool -Name $poolName | Out-Null
    }
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedPipelineMode -Value 'Integrated'
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name processModel.identityType -Value 4
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name startMode -Value 'AlwaysRunning'
    Grant-AppPoolAccess $poolName

    $portSites = @(Get-Website | Where-Object {
        $site = $_
        @($site.Bindings.Collection) | Where-Object { $_.protocol -eq 'http' -and $_.bindingInformation -match ":$Port(:|$)" }
    })

    $site = $null
    $preferredName = "iMonitorERP-$Name"
    if (Test-Path "IIS:\Sites\$preferredName") {
        $site = Get-Website -Name $preferredName
    } elseif ($portSites.Count -eq 1) {
        $site = $portSites[0]
        Write-Host "Reusing IIS site '$($site.Name)' already bound to port $Port."
    } elseif ($portSites.Count -gt 1) {
        throw "Multiple IIS sites already use port $Port: $($portSites.Name -join ', '). Resolve the binding conflict and rerun."
    }

    if (-not $site) {
        Write-Host "Creating IIS site: $preferredName on port $Port"
        New-Website -Name $preferredName -Port $Port -IPAddress '127.0.0.1' -PhysicalPath $current -ApplicationPool $poolName | Out-Null
        $site = Get-Website -Name $preferredName
    } else {
        Set-ItemProperty "IIS:\Sites\$($site.Name)" -Name physicalPath -Value $current
        Set-ItemProperty "IIS:\Sites\$($site.Name)" -Name applicationPool -Value $poolName
        $bindings = @($site.Bindings.Collection | Where-Object { $_.protocol -eq 'http' })
        $hasPort = [bool]($bindings | Where-Object { $_.bindingInformation -match ":$Port(:|$)" })
        if (-not $hasPort) { New-WebBinding -Name $site.Name -Protocol http -IPAddress '127.0.0.1' -Port $Port | Out-Null }
    }

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $site.Name -Filter 'system.webServer/serverRuntime' -Name 'uploadReadAheadSize' -Value 49152 -ErrorAction SilentlyContinue
    return [string]$site.Name
}

function Get-GitHubReleaseCatalog {
    $tmp = Join-Path $env:TEMP ("imonitor-release-catalog-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $uri = "https://api.github.com/repos/$repo/releases?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        Invoke-CurlDownload $uri $tmp 'Release metadata download over GitHub IPv4'
        return @(Get-Content $tmp -Raw | ConvertFrom-Json)
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-VersionFromTag([string]$Tag) {
    if ($Tag -match '-v(\d+)\.(\d+)\.(\d+)$') { return [version]("{0}.{1}.{2}" -f $matches[1],$matches[2],$matches[3]) }
    return [version]'0.0.0'
}
function Get-PublishedDate([object]$Release) {
    if ($Release.published_at) { return [datetime]$Release.published_at }
    if ($Release.created_at) { return [datetime]$Release.created_at }
    return [datetime]::MinValue
}
function Get-LatestRelease([object[]]$Catalog,[string]$GitChannel) {
    $prefix = "imonitor-ecomerp-$GitChannel-v"
    $items = @($Catalog | Where-Object {
        -not $_.draft -and ([string]$_.tag_name).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and ($GitChannel -eq 'test' -or -not $_.prerelease)
    })
    if (-not $items) { throw "No published release found for channel $GitChannel." }
    return $items | Sort-Object @{Expression={ Get-VersionFromTag ([string]$_.tag_name) };Descending=$true}, @{Expression={ Get-PublishedDate $_ };Descending=$true} | Select-Object -First 1
}

function Test-PackageLayout([string]$Root) {
    $required = @(
        (Join-Path $Root 'Ecomm.dll'),
        (Join-Path $Root 'web.config'),
        (Join-Path $Root 'wwwroot'),
        (Join-Path $Root 'Reports'),
        (Join-Path $Root 'Reports\Invoice.mrt'),
        (Join-Path $Root 'Reports\Label.mrt')
    )
    $missing = @($required | Where-Object { -not (Test-Path $_) })
    if ($missing.Count -gt 0) { throw "Package layout validation failed. Missing: $($missing -join ', ')" }
}

function Copy-PersistentData([string]$OldCurrent,[string]$Staging) {
    $config = Join-Path $OldCurrent 'appsettings.json'
    if (Test-Path $config -PathType Leaf) { Copy-Item $config (Join-Path $Staging 'appsettings.json') -Force }
    $appData = Join-Path $OldCurrent 'App_Data'
    if (Test-Path $appData -PathType Container) {
        $targetData = Join-Path $Staging 'App_Data'
        New-Item -ItemType Directory -Force -Path $targetData | Out-Null
        Copy-Item (Join-Path $appData '*') $targetData -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-IISDiagnostics([string]$Name,[string]$SiteName,[string]$PoolName,[string]$Current,[int]$Port) {
    Write-Host ''
    Write-Host "===== $Name IIS diagnostics =====" -ForegroundColor Yellow
    try {
        $site = Get-Website -Name $SiteName -ErrorAction Stop
        Write-Host "Site: $($site.Name) state=$($site.State) path=$($site.PhysicalPath)"
    } catch { Write-Host "Site query failed: $($_.Exception.Message)" }
    try {
        $pool = Get-WebAppPoolState -Name $PoolName -ErrorAction Stop
        Write-Host "AppPool: $PoolName state=$($pool.Value)"
    } catch { Write-Host "AppPool query failed: $($_.Exception.Message)" }
    Write-Host "Health URL: http://127.0.0.1:$Port/health"

    try {
        $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if ($dotnet) {
            Write-Host 'Installed .NET runtimes:'
            & $dotnet.Source --list-runtimes | ForEach-Object { Write-Host "  $_" }
        }
    } catch { }

    $stdout = Join-Path $Current 'logs'
    if (Test-Path $stdout) {
        Get-ChildItem $stdout -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
            Write-Host "--- stdout: $($_.FullName) ---"
            Get-Content $_.FullName -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        }
    }

    try {
        Write-Host 'Recent IIS/ASP.NET Core event log entries:'
        Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction Stop |
            Where-Object { $_.ProviderName -match 'IIS|AspNetCore|IIS AspNetCore Module|.NET Runtime|Application Error' } |
            Select-Object -First 12 TimeCreated,ProviderName,Id,LevelDisplayName,Message |
            Format-List | Out-String | Write-Host
    } catch { Write-Host "Event log read failed: $($_.Exception.Message)" }
    Write-Host '================================' -ForegroundColor Yellow
}

function Install-Channel([string]$Name,[int]$Port,[object[]]$Catalog) {
    $gitChannel = if ($Name -eq 'Production') { 'master' } else { 'test' }
    $release = Get-LatestRelease $Catalog $gitChannel
    $tag = [string]$release.tag_name
    $asset = @($release.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
    $sumAsset = @($release.assets | Where-Object { $_.name -eq "$assetName.sha256" }) | Select-Object -First 1
    if (-not $asset -or -not $sumAsset) { throw "Release $tag is missing package or checksum asset." }

    $base = Join-Path $InstallRoot $Name.ToLowerInvariant()
    $current = Join-Path $base 'current'
    $versions = Join-Path $base 'releases'
    $versionFile = Join-Path $stateRoot "$gitChannel-version"
    New-Item -ItemType Directory -Force -Path $base,$versions | Out-Null

    $siteName = Ensure-IISChannel $Name $Port
    $poolName = "iMonitorERP-$Name"

    $installed = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
    $layoutHealthy = (Test-Path (Join-Path $current 'Ecomm.dll')) -and (Test-Path (Join-Path $current 'wwwroot')) -and (Test-Path (Join-Path $current 'Reports'))
    $httpHealthy = $false
    if ($layoutHealthy) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5
            $httpHealthy = ([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 400)
        } catch { $httpHealthy = $false }
    }
    Write-Host "${Name}: installed='$installed', latest='$tag', layoutHealthy=$layoutHealthy, httpHealthy=$httpHealthy"

    if (-not $Force -and $installed -eq $tag -and $layoutHealthy -and $httpHealthy) {
        Write-Host "$Name is already current and healthy."
        return
    }

    $releaseCache = Join-Path $PackageCacheDirectory $tag
    New-Item -ItemType Directory -Force -Path $releaseCache | Out-Null
    $zip = Join-Path $releaseCache $assetName
    $sum = "$zip.sha256"
    Invoke-CurlDownload ([string]$sumAsset.browser_download_url) $sum "$Name checksum"
    $expected = ((Get-Content $sum -Raw) -split '\s+')[0].Trim().ToLowerInvariant()

    $reuse = $false
    if (Test-Path $zip -PathType Leaf) {
        $actualCached = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualCached -eq $expected) { Write-Host "Using verified cached package: $zip"; $reuse = $true }
        else { Remove-Item $zip -Force }
    }
    if (-not $reuse) {
        $partial = "$zip.partial"
        Invoke-CurlDownload ([string]$asset.browser_download_url) $partial "$Name package $tag" 1800
        $actual = (Get-FileHash $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Remove-Item $partial -Force -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch for $tag. Expected $expected, actual $actual"
        }
        Move-Item $partial $zip -Force
    }

    $target = Join-Path $versions $tag
    $extract = Join-Path $versions (".$tag.extract-" + [guid]::NewGuid().ToString('N'))
    $staging = Join-Path $base (".current-staging-" + [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $base (".current-backup-" + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Force -Path $extract | Out-Null
        Expand-Archive $zip $extract -Force
        $packageRoot = $extract
        if (-not (Test-Path (Join-Path $packageRoot 'Ecomm.dll'))) {
            $children = @(Get-ChildItem $extract -Directory)
            if ($children.Count -eq 1 -and (Test-Path (Join-Path $children[0].FullName 'Ecomm.dll'))) { $packageRoot = $children[0].FullName }
        }
        Test-PackageLayout $packageRoot

        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        Copy-Item (Join-Path $packageRoot '*') $staging -Recurse -Force
        Test-PackageLayout $staging
        if (Test-Path $current) { Copy-PersistentData $current $staging }

        Import-Module WebAdministration -ErrorAction Stop
        if (Test-Path "IIS:\Sites\$siteName") { Write-Host "Stopping IIS site: $siteName"; Stop-WebSite -Name $siteName -ErrorAction SilentlyContinue }
        if (Test-Path "IIS:\AppPools\$poolName") { Write-Host "Stopping IIS app pool: $poolName"; Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2

        if (Test-Path $current) {
            $moved = $false; $moveError = $null
            for ($attempt = 1; $attempt -le 15; $attempt++) {
                try { Move-Item $current $backup -Force; $moved = $true; break }
                catch { $moveError = $_.Exception.Message; Start-Sleep -Seconds 2 }
            }
            if (-not $moved) { throw "Could not move current directory. Last error: $moveError" }
        }
        Move-Item $staging $current -Force

        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Copy-Item (Join-Path $packageRoot '*') $target -Recurse -Force
        Test-PackageLayout $current
        Grant-AppPoolAccess $poolName

        if (Test-Path "IIS:\AppPools\$poolName") { Start-WebAppPool -Name $poolName }
        if (Test-Path "IIS:\Sites\$siteName") { Start-WebSite -Name $siteName }

        $healthUri = "http://127.0.0.1:$Port/health"
        $healthy = $false; $lastError = $null
        for ($i=1; $i -le 30; $i++) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec 5
                if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400) { $healthy=$true; break }
                $lastError = "HTTP $([int]$response.StatusCode)"
            } catch { $lastError=$_.Exception.Message }
            Start-Sleep -Seconds 2
        }
        if (-not $healthy) {
            Show-IISDiagnostics $Name $siteName $poolName $current $Port
            throw "$Name health check failed after activation: $lastError"
        }

        Set-Content $versionFile $tag -Encoding ASCII
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "$Name activated successfully: $tag" -ForegroundColor Green
    } catch {
        Write-Warning "$Name activation failed: $($_.Exception.Message)"
        try {
            if (Test-Path "IIS:\Sites\$siteName") { Stop-WebSite -Name $siteName -ErrorAction SilentlyContinue }
            if (Test-Path "IIS:\AppPools\$poolName") { Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
        } catch { }
        if ((Test-Path $current) -and (Test-Path $backup)) { Remove-Item $current -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $backup) {
            Move-Item $backup $current -Force
            try {
                if (Test-Path "IIS:\AppPools\$poolName") { Start-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
                if (Test-Path "IIS:\Sites\$siteName") { Start-WebSite -Name $siteName -ErrorAction SilentlyContinue }
            } catch { }
            Write-Warning "$Name rolled back to the previous current directory."
        }
        throw
    } finally {
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Ensure-IISInstalled
Ensure-DotNet8HostingBundle

$catalog = Get-GitHubReleaseCatalog
$targets = if ($Channel -eq 'Both') { @('Test','Production') } else { @($Channel) }
foreach ($target in $targets) {
    if ($target -eq 'Test') { Install-Channel 'Test' $TestPort $catalog }
    else { Install-Channel 'Production' $ProductionPort $catalog }
}

$self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.12.ps1'
Copy-Item $PSCommandPath $self -Force
$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $prodAction | Out-Null
$global:LASTEXITCODE = 0

Write-Host ''
Write-Host 'iMonitor ERP installer/updater v2.0.12 completed.' -ForegroundColor Green
Write-Host "Applications are installed under: $InstallRoot"
Write-Host "Test       : http://127.0.0.1:$TestPort"
Write-Host "Production : http://127.0.0.1:$ProductionPort"
Write-Host 'Automatic prerequisites: IIS + WebSockets + .NET 8 Hosting Bundle + AppPools + IIS Sites.'
