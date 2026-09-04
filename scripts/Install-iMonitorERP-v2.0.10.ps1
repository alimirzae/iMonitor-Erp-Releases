[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP',
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}

$repo = 'alimirzae/iMonitor-Erp-Releases'
$assetName = 'iMonitor-EcomERP-win-x64.zip'
$stateRoot = Join-Path $InstallRoot 'state'
$installerHome = Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $InstallRoot,$stateRoot,$installerHome,$PackageCacheDirectory | Out-Null

function Invoke-CurlDownload([string]$Uri,[string]$OutFile,[string]$Label) {
    $curl = Get-Command curl.exe -ErrorAction Stop
    $last = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Host "$Label (attempt $attempt/4)..."
            & $curl.Source -4 --http1.1 --fail --location --connect-timeout 8 --max-time 300 --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Updater/2.0.10' $Uri -o $OutFile
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

function Get-GitHubReleaseCatalog {
    $tmp = Join-Path $env:TEMP ("imonitor-release-catalog-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $uri = "https://api.github.com/repos/$repo/releases?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        Invoke-CurlDownload $uri $tmp 'Release metadata download over GitHub IPv4'
        return @(Get-Content $tmp -Raw | ConvertFrom-Json)
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-VersionFromTag([string]$Tag) {
    if ($Tag -match '-v(\d+)\.(\d+)\.(\d+)$') {
        return [version]("{0}.{1}.{2}" -f $matches[1],$matches[2],$matches[3])
    }
    return [version]'0.0.0'
}

function Get-LatestRelease([object[]]$Catalog,[string]$GitChannel) {
    $prefix = "imonitor-ecomerp-$GitChannel-v"
    $items = @($Catalog | Where-Object {
        -not $_.draft -and
        ([string]$_.tag_name).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        ($GitChannel -eq 'test' -or -not $_.prerelease)
    })
    if (-not $items) { throw "No published release found for channel $GitChannel." }
    return $items | Sort-Object @{Expression={ Get-VersionFromTag ([string]$_.tag_name) };Descending=$true}, @{Expression={ [datetime]($_.published_at ?? $_.created_at) };Descending=$true} | Select-Object -First 1
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
    if ($missing.Count -gt 0) {
        throw "Package layout validation failed. Missing: $($missing -join ', ')"
    }
}

function Copy-PersistentData([string]$OldCurrent,[string]$Staging) {
    $config = Join-Path $OldCurrent 'appsettings.json'
    if (Test-Path $config -PathType Leaf) {
        Copy-Item $config (Join-Path $Staging 'appsettings.json') -Force
    }

    $appData = Join-Path $OldCurrent 'App_Data'
    if (Test-Path $appData -PathType Container) {
        $targetData = Join-Path $Staging 'App_Data'
        New-Item -ItemType Directory -Force -Path $targetData | Out-Null
        Copy-Item (Join-Path $appData '*') $targetData -Recurse -Force -ErrorAction SilentlyContinue
    }
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

    $installed = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
    $currentHealthy = (Test-Path (Join-Path $current 'Ecomm.dll')) -and (Test-Path (Join-Path $current 'wwwroot')) -and (Test-Path (Join-Path $current 'Reports'))
    Write-Host "${Name}: installed='$installed', latest='$tag', currentHealthy=$currentHealthy"

    if (-not $Force -and $installed -eq $tag -and $currentHealthy) {
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
        if ($actualCached -eq $expected) {
            Write-Host "Using verified cached package: $zip"
            $reuse = $true
        } else {
            Remove-Item $zip -Force
        }
    }
    if (-not $reuse) {
        $partial = "$zip.partial"
        Invoke-CurlDownload ([string]$asset.browser_download_url) $partial "$Name package $tag"
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
            if ($children.Count -eq 1 -and (Test-Path (Join-Path $children[0].FullName 'Ecomm.dll'))) {
                $packageRoot = $children[0].FullName
            }
        }
        Test-PackageLayout $packageRoot

        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        Copy-Item (Join-Path $packageRoot '*') $staging -Recurse -Force
        Test-PackageLayout $staging
        if (Test-Path $current) { Copy-PersistentData $current $staging }

        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $poolName = "iMonitorERP-$Name"
        if (Test-Path "IIS:\AppPools\$poolName") {
            Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue
        }

        if (Test-Path $current) { Move-Item $current $backup -Force }
        Move-Item $staging $current -Force

        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Copy-Item (Join-Path $packageRoot '*') $target -Recurse -Force
        Test-PackageLayout $current
        Set-Content $versionFile $tag -Encoding ASCII

        if (Test-Path "IIS:\AppPools\$poolName") {
            Start-WebAppPool -Name $poolName
        }

        $healthUri = "http://127.0.0.1:$Port/health"
        $healthy = $false
        $lastError = $null
        for ($i=1; $i -le 30; $i++) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec 5
                if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500) { $healthy=$true; break }
            } catch { $lastError=$_.Exception.Message }
            Start-Sleep -Seconds 2
        }
        if (-not $healthy) { throw "$Name health check failed after activation: $lastError" }

        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "$Name activated successfully: $tag" -ForegroundColor Green
    } catch {
        Write-Warning "$Name activation failed: $($_.Exception.Message)"
        if (Test-Path $current -and Test-Path $backup) {
            Remove-Item $current -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $backup) {
            Move-Item $backup $current -Force
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $poolName = "iMonitorERP-$Name"
            if (Test-Path "IIS:\AppPools\$poolName") { Start-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
            Write-Warning "$Name rolled back to the previous current directory."
        }
        throw
    } finally {
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$catalog = Get-GitHubReleaseCatalog
$targets = if ($Channel -eq 'Both') { @('Test','Production') } else { @($Channel) }
foreach ($target in $targets) {
    if ($target -eq 'Test') { Install-Channel 'Test' $TestPort $catalog }
    else { Install-Channel 'Production' $ProductionPort $catalog }
}

$self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.10.ps1'
Copy-Item $PSCommandPath $self -Force
$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /TR $prodAction | Out-Null
$global:LASTEXITCODE = 0

Write-Host ''
Write-Host 'iMonitor ERP updater v2.0.10 completed.'
Write-Host 'Release metadata authority: GitHub over IPv4.'
Write-Host 'Activation policy: validate -> stage -> preserve config/App_Data -> atomic swap -> health check -> rollback on failure.'
