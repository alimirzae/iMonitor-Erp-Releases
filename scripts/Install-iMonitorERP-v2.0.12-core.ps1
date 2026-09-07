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
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdministrator)) { throw 'Run PowerShell as Administrator.' }

$repo = 'alimirzae/iMonitor-Erp-Releases'
$assetName = 'iMonitor-EcomERP-win-x64.zip'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$PackageCacheDirectory = [IO.Path]::GetFullPath($PackageCacheDirectory)
$stateRoot = Join-Path $InstallRoot 'state'
$installerHome = Join-Path $InstallRoot 'installer'
$legacyRoot = 'C:\ProgramData\iMonitorERP'
New-Item -ItemType Directory -Force -Path $InstallRoot,$PackageCacheDirectory,$stateRoot,$installerHome | Out-Null

Write-Host 'iMonitor ERP installer v2.0.12 core' -ForegroundColor Cyan
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
            $exitCode = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            if ($exitCode -ne 0) { throw "curl exit code $exitCode" }
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
    if (-not (Test-Path "$env:windir\System32\inetsrv\appcmd.exe")) {
        Write-Host 'IIS is not installed. Installing IIS...' -ForegroundColor Yellow
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            Install-WindowsFeature Web-Server,Web-WebSockets -IncludeManagementTools | Out-Null
        } else {
            $features = @('IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-StaticContent','IIS-DefaultDocument','IIS-HttpErrors','IIS-HealthAndDiagnostics','IIS-HttpLogging','IIS-Performance','IIS-HttpCompressionStatic','IIS-Security','IIS-RequestFiltering','IIS-ApplicationDevelopment','IIS-WebSockets','IIS-ManagementConsole')
            foreach ($feature in $features) {
                try { Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop | Out-Null }
                catch { Write-Verbose "Optional IIS feature ${feature}: $($_.Exception.Message)" }
            }
        }
    }
    Import-Module WebAdministration -ErrorAction Stop
    Write-Host '[OK] IIS ready.' -ForegroundColor Green
}

function Test-AspNetCore8Runtime {
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $false }
    try {
        $runtimes = & $dotnet.Source --list-runtimes 2>$null
        [bool]($runtimes | Where-Object { $_ -match '^Microsoft\.AspNetCore\.App 8\.' })
    } catch { $false }
}
function Test-AspNetCoreModuleV2 {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        [bool](Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue)
    } catch { $false }
}
function Ensure-DotNet8HostingBundle {
    $runtimeOk = Test-AspNetCore8Runtime
    $moduleOk = Test-AspNetCoreModuleV2
    if ($runtimeOk -and $moduleOk) {
        Write-Host '[OK] .NET 8 Hosting Bundle ready.' -ForegroundColor Green
        return
    }
    Write-Host ".NET 8 Hosting Bundle incomplete (runtime=$runtimeOk module=$moduleOk). Installing..." -ForegroundColor Yellow
    $hostingInstaller = Join-Path $env:TEMP 'dotnet-hosting-8-win.exe'
    Invoke-CurlDownload 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe' $hostingInstaller '.NET 8 Hosting Bundle' 600
    try {
        $p = Start-Process -FilePath $hostingInstaller -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
        if ($p.ExitCode -notin @(0,1641,3010)) { throw ".NET Hosting Bundle installer returned $($p.ExitCode)." }
    } finally { Remove-Item $hostingInstaller -Force -ErrorAction SilentlyContinue }
    & iisreset.exe /restart | Out-Null
    $global:LASTEXITCODE = 0
    if (-not (Test-AspNetCore8Runtime)) { throw '.NET 8 ASP.NET Core runtime still unavailable.' }
    if (-not (Test-AspNetCoreModuleV2)) { throw 'ASP.NET Core Module V2 still unavailable in IIS.' }
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

    if (-not (Test-Path "IIS:\AppPools\$poolName")) { New-WebAppPool -Name $poolName | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedPipelineMode -Value 'Integrated'
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name processModel.identityType -Value 4
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name startMode -Value 'AlwaysRunning'
    Grant-AppPoolAccess $poolName

    $preferredName = "iMonitorERP-$Name"
    $site = $null
    if (Test-Path "IIS:\Sites\$preferredName") { $site = Get-Website -Name $preferredName }
    if (-not $site) {
        $portSites = @(Get-Website | Where-Object {
            $candidate = $_
            @($candidate.Bindings.Collection) | Where-Object { $_.protocol -eq 'http' -and $_.bindingInformation -match ":${Port}(:|$)" }
        })
        if ($portSites.Count -eq 1) { $site = $portSites[0] }
        elseif ($portSites.Count -gt 1) { throw "Multiple IIS sites already use port ${Port}: $($portSites.Name -join ', ')" }
    }
    if (-not $site) {
        New-Website -Name $preferredName -Port $Port -IPAddress '127.0.0.1' -PhysicalPath $current -ApplicationPool $poolName | Out-Null
        $site = Get-Website -Name $preferredName
    } else {
        Set-ItemProperty "IIS:\Sites\$($site.Name)" -Name physicalPath -Value $current
        Set-ItemProperty "IIS:\Sites\$($site.Name)" -Name applicationPool -Value $poolName
        $hasPort = [bool](@($site.Bindings.Collection | Where-Object { $_.protocol -eq 'http' -and $_.bindingInformation -match ":${Port}(:|$)" }))
        if (-not $hasPort) { New-WebBinding -Name $site.Name -Protocol http -IPAddress '127.0.0.1' -Port $Port | Out-Null }
    }
    [string]$site.Name
}

function Get-GitHubReleaseCatalog {
    $tmp = Join-Path $env:TEMP ("imonitor-release-catalog-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $uri = "https://api.github.com/repos/$repo/releases?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        Invoke-CurlDownload $uri $tmp 'Release metadata download over GitHub IPv4'
        @(Get-Content $tmp -Raw | ConvertFrom-Json)
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Get-VersionFromTag([string]$Tag) {
    if ($Tag -match '-v(\d+)\.(\d+)\.(\d+)$') { [version]("{0}.{1}.{2}" -f $matches[1],$matches[2],$matches[3]) } else { [version]'0.0.0' }
}
function Get-LatestRelease([object[]]$Catalog,[string]$GitChannel) {
    $prefix = "imonitor-ecomerp-$GitChannel-v"
    $items = @($Catalog | Where-Object { -not $_.draft -and ([string]$_.tag_name).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and ($GitChannel -eq 'test' -or -not $_.prerelease) })
    if (-not $items) { throw "No published release found for channel $GitChannel." }
    $items | Sort-Object @{Expression={ Get-VersionFromTag ([string]$_.tag_name) };Descending=$true}, @{Expression={ if ($_.published_at) {[datetime]$_.published_at} else {[datetime]$_.created_at} };Descending=$true} | Select-Object -First 1
}
function Test-PackageLayout([string]$Root) {
    $required = @((Join-Path $Root 'Ecomm.dll'),(Join-Path $Root 'web.config'),(Join-Path $Root 'wwwroot'),(Join-Path $Root 'Reports'),(Join-Path $Root 'Reports\Invoice.mrt'),(Join-Path $Root 'Reports\Label.mrt'))
    $missing = @($required | Where-Object { -not (Test-Path $_) })
    if ($missing.Count) { throw "Package layout validation failed. Missing: $($missing -join ', ')" }
}
function Copy-PersistentData([string]$OldCurrent,[string]$Staging) {
    if (Test-Path (Join-Path $OldCurrent 'appsettings.json')) { Copy-Item (Join-Path $OldCurrent 'appsettings.json') (Join-Path $Staging 'appsettings.json') -Force }
    if (Test-Path (Join-Path $OldCurrent 'App_Data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'App_Data') | Out-Null
        Copy-Item (Join-Path $OldCurrent 'App_Data\*') (Join-Path $Staging 'App_Data') -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Get-LegacyCurrent([string]$Name) {
    $legacyChannel = $Name.ToLowerInvariant()
    $candidate = Join-Path $legacyRoot "$legacyChannel\current"
    if (([IO.Path]::GetFullPath($InstallRoot)).TrimEnd('\') -ieq ([IO.Path]::GetFullPath($legacyRoot)).TrimEnd('\')) { return $null }
    if (Test-Path $candidate -PathType Container) { return $candidate }
    return $null
}
function Import-LegacyPersistentData([string]$Name,[string]$Staging) {
    $legacyCurrent = Get-LegacyCurrent $Name
    if (-not $legacyCurrent) { return $false }
    $copied = $false
    $legacyConfig = Join-Path $legacyCurrent 'appsettings.json'
    if (Test-Path $legacyConfig -PathType Leaf) {
        Copy-Item $legacyConfig (Join-Path $Staging 'appsettings.json') -Force
        Write-Host "Migrated legacy appsettings.json for $Name from $legacyCurrent" -ForegroundColor Green
        $copied = $true
    }
    $legacyAppData = Join-Path $legacyCurrent 'App_Data'
    if (Test-Path $legacyAppData -PathType Container) {
        $targetData = Join-Path $Staging 'App_Data'
        New-Item -ItemType Directory -Force -Path $targetData | Out-Null
        Copy-Item (Join-Path $legacyAppData '*') $targetData -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Migrated legacy App_Data for $Name from $legacyCurrent" -ForegroundColor Green
        $copied = $true
    }
    return $copied
}
function Show-Diagnostics([string]$Name,[string]$SiteName,[string]$PoolName,[string]$Current,[int]$Port) {
    Write-Host "===== $Name diagnostics =====" -ForegroundColor Yellow
    try { $s=Get-Website -Name $SiteName; Write-Host "Site=$($s.Name) state=$($s.State) path=$($s.PhysicalPath)" } catch { Write-Host $_.Exception.Message }
    try { $p=Get-WebAppPoolState -Name $PoolName; Write-Host "AppPool=$PoolName state=$($p.Value)" } catch { Write-Host $_.Exception.Message }
    Write-Host "Health=http://127.0.0.1:${Port}/health"
    try { & dotnet.exe --list-runtimes | ForEach-Object { Write-Host "  $_" } } catch {}
    $logs = Join-Path $Current 'logs'
    if (Test-Path $logs) { Get-ChildItem $logs -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { Write-Host "--- $($_.FullName) ---"; Get-Content $_.FullName -Tail 100 -ErrorAction SilentlyContinue } }
    try { Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddMinutes(-15)} | Where-Object { $_.ProviderName -match 'IIS|AspNetCore|\.NET Runtime|Application Error' } | Select-Object -First 12 TimeCreated,ProviderName,Id,LevelDisplayName,Message | Format-List | Out-String | Write-Host } catch {}
}

function Install-Channel([string]$Name,[int]$Port,[object[]]$Catalog) {
    $gitChannel = if ($Name -eq 'Production') { 'master' } else { 'test' }
    $release = Get-LatestRelease $Catalog $gitChannel
    $tag = [string]$release.tag_name
    $asset = @($release.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
    $sumAsset = @($release.assets | Where-Object { $_.name -eq "$assetName.sha256" }) | Select-Object -First 1
    if (-not $asset -or -not $sumAsset) { throw "Release $tag is missing package/checksum." }

    $base = Join-Path $InstallRoot $Name.ToLowerInvariant(); $current = Join-Path $base 'current'; $versions = Join-Path $base 'releases'; $versionFile = Join-Path $stateRoot "$gitChannel-version"
    New-Item -ItemType Directory -Force -Path $base,$versions | Out-Null
    $siteName = Ensure-IISChannel $Name $Port; $poolName = "iMonitorERP-$Name"

    $installed = if (Test-Path $versionFile) {(Get-Content $versionFile -Raw).Trim()} else {''}
    $layoutHealthy = (Test-Path (Join-Path $current 'Ecomm.dll')) -and (Test-Path (Join-Path $current 'wwwroot'))
    $httpHealthy = $false
    if ($layoutHealthy) { try { $r=Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:${Port}/health" -TimeoutSec 5; $httpHealthy=([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 400) } catch {} }
    Write-Host "${Name}: installed='$installed', latest='$tag', layoutHealthy=$layoutHealthy, httpHealthy=$httpHealthy"
    if (-not $Force -and $installed -eq $tag -and $layoutHealthy -and $httpHealthy) { Write-Host "$Name is already current and healthy."; return }

    $releaseCache = Join-Path $PackageCacheDirectory $tag; New-Item -ItemType Directory -Force -Path $releaseCache | Out-Null
    $zip = Join-Path $releaseCache $assetName; $sum = "$zip.sha256"
    Invoke-CurlDownload ([string]$sumAsset.browser_download_url) $sum "$Name checksum"
    $expected = ((Get-Content $sum -Raw) -split '\s+')[0].Trim().ToLowerInvariant()
    $reuse = $false
    if (Test-Path $zip) { if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected) {$reuse=$true; Write-Host "Using verified cached package: $zip"} else {Remove-Item $zip -Force} }
    if (-not $reuse) {
        $partial="$zip.partial"; Invoke-CurlDownload ([string]$asset.browser_download_url) $partial "$Name package $tag" 1800
        $actual=(Get-FileHash $partial -Algorithm SHA256).Hash.ToLowerInvariant(); if ($actual -ne $expected) {Remove-Item $partial -Force -ErrorAction SilentlyContinue; throw "SHA-256 mismatch for $tag"}; Move-Item $partial $zip -Force
    }

    $extract=Join-Path $versions (".$tag.extract-"+[guid]::NewGuid().ToString('N')); $staging=Join-Path $base (".current-staging-"+[guid]::NewGuid().ToString('N')); $backup=Join-Path $base (".current-backup-"+[guid]::NewGuid().ToString('N')); $target=Join-Path $versions $tag
    try {
        New-Item -ItemType Directory -Force -Path $extract | Out-Null; Expand-Archive $zip $extract -Force
        $packageRoot=$extract
        if (-not (Test-Path (Join-Path $packageRoot 'Ecomm.dll'))) { $children=@(Get-ChildItem $extract -Directory); if ($children.Count -eq 1 -and (Test-Path (Join-Path $children[0].FullName 'Ecomm.dll'))) {$packageRoot=$children[0].FullName} }
        Test-PackageLayout $packageRoot
        New-Item -ItemType Directory -Force -Path $staging | Out-Null; Copy-Item (Join-Path $packageRoot '*') $staging -Recurse -Force; Test-PackageLayout $staging
        $persistentImported = $false
        if (Test-Path $current) {
            $currentHasConfig = Test-Path (Join-Path $current 'appsettings.json') -PathType Leaf
            $currentHasData = Test-Path (Join-Path $current 'App_Data') -PathType Container
            if ($currentHasConfig -or $currentHasData) {
                Copy-PersistentData $current $staging
                $persistentImported = $true
            }
        }
        if (-not $persistentImported) { [void](Import-LegacyPersistentData $Name $staging) }
        Import-Module WebAdministration
        if (Test-Path "IIS:\Sites\$siteName") { Stop-WebSite -Name $siteName -ErrorAction SilentlyContinue }
        if (Test-Path "IIS:\AppPools\$poolName") { Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
        Start-Sleep 2
        if (Test-Path $current) { Move-Item $current $backup -Force }
        Move-Item $staging $current -Force
        if (Test-Path $target) {Remove-Item $target -Recurse -Force}; New-Item -ItemType Directory -Force -Path $target | Out-Null; Copy-Item (Join-Path $packageRoot '*') $target -Recurse -Force
        Grant-AppPoolAccess $poolName
        Start-WebAppPool -Name $poolName; Start-WebSite -Name $siteName
        $healthy=$false; $lastError=$null
        for($i=1;$i -le 30;$i++){try{$r=Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:${Port}/health" -TimeoutSec 5;if([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 400){$healthy=$true;break}}catch{$lastError=$_.Exception.Message};Start-Sleep 2}
        if(-not $healthy){Show-Diagnostics $Name $siteName $poolName $current $Port;throw "$Name health check failed after activation: $lastError"}
        Set-Content $versionFile $tag -Encoding ASCII; Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "$Name activated successfully: $tag" -ForegroundColor Green
    } catch {
        Write-Warning "$Name activation failed: $($_.Exception.Message)"
        try {Stop-WebSite -Name $siteName -ErrorAction SilentlyContinue;Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue}catch{}
        if((Test-Path $current)-and(Test-Path $backup)){Remove-Item $current -Recurse -Force -ErrorAction SilentlyContinue}
        if(Test-Path $backup){Move-Item $backup $current -Force;try{Start-WebAppPool -Name $poolName -ErrorAction SilentlyContinue;Start-WebSite -Name $siteName -ErrorAction SilentlyContinue}catch{};Write-Warning "$Name rolled back."}
        throw
    } finally {Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue}
}

Ensure-IISInstalled
Ensure-DotNet8HostingBundle
$catalog=Get-GitHubReleaseCatalog
$targets=if($Channel -eq 'Both'){@('Test','Production')}else{@($Channel)}
foreach($target in $targets){if($target -eq 'Test'){Install-Channel 'Test' $TestPort $catalog}else{Install-Channel 'Production' $ProductionPort $catalog}}

$self=Join-Path $installerHome 'Install-iMonitorERP-v2.0.12.ps1'
$bootstrapSource=Join-Path $PSScriptRoot 'Install-iMonitorERP-v2.0.12.ps1'
if(Test-Path $bootstrapSource){Copy-Item $bootstrapSource $self -Force}else{Copy-Item $PSCommandPath $self -Force}
$testAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort"
$prodAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $prodAction | Out-Null
$global:LASTEXITCODE=0
Write-Host 'iMonitor ERP v2.0.12 completed.' -ForegroundColor Green
Write-Host "Install root: $InstallRoot"