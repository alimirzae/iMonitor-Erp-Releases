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
$base = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.10-iis-safe.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$uri = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.10.ps1?cb=$cb"

Write-Host 'Downloading compatibility updater v2.0.10 over IPv4...'
& curl.exe -4 --http1.1 --fail --location --connect-timeout 8 --max-time 120 --retry 3 --retry-all-errors $uri -o $base
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $base)) { throw 'Could not download v2.0.10 updater.' }
$global:LASTEXITCODE = 0

$text = Get-Content $base -Raw

$oldStop = @'
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $poolName = "iMonitorERP-$Name"
        if (Test-Path "IIS:\AppPools\$poolName") {
            Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue
        }

        if (Test-Path $current) { Move-Item $current $backup -Force }
        Move-Item $staging $current -Force
'@

$newStop = @'
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $poolName = "iMonitorERP-$Name"
        $siteNames = @()
        try {
            $siteNames = @(Get-Website | Where-Object {
                $_.applicationPool -eq $poolName -or
                ([string]$_.physicalPath).TrimEnd('\\') -ieq $current.TrimEnd('\\')
            } | Select-Object -ExpandProperty Name)
        } catch { }

        foreach ($siteName in $siteNames) {
            Write-Host "Stopping IIS site: $siteName"
            Stop-WebSite -Name $siteName -ErrorAction SilentlyContinue
        }
        if (Test-Path "IIS:\AppPools\$poolName") {
            Write-Host "Stopping IIS app pool: $poolName"
            Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 2
        if (Test-Path $current) {
            $moved = $false
            $moveError = $null
            for ($attempt = 1; $attempt -le 15; $attempt++) {
                try {
                    Move-Item $current $backup -Force
                    $moved = $true
                    break
                } catch {
                    $moveError = $_.Exception.Message
                    Write-Host "Waiting for IIS/file handles to release current directory ($attempt/15)..."
                    Start-Sleep -Seconds 2
                }
            }
            if (-not $moved) { throw "Could not move current directory after stopping IIS. Last error: $moveError" }
        }
        Move-Item $staging $current -Force
'@

if (-not $text.Contains($oldStop)) { throw 'Compatibility patch failed: activation block not found in v2.0.10.' }
$text = $text.Replace($oldStop, $newStop)

$oldStart = @'
        if (Test-Path "IIS:\AppPools\$poolName") {
            Start-WebAppPool -Name $poolName
        }

        $healthUri = "http://127.0.0.1:$Port/health"
'@
$newStart = @'
        if (Test-Path "IIS:\AppPools\$poolName") {
            Start-WebAppPool -Name $poolName
        }
        foreach ($siteName in $siteNames) {
            if (Test-Path "IIS:\Sites\$siteName") {
                Start-WebSite -Name $siteName -ErrorAction SilentlyContinue
            }
        }

        $healthUri = "http://127.0.0.1:$Port/health"
'@
if (-not $text.Contains($oldStart)) { throw 'Compatibility patch failed: startup block not found in v2.0.10.' }
$text = $text.Replace($oldStart, $newStart)

$oldRollback = @'
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $poolName = "iMonitorERP-$Name"
            if (Test-Path "IIS:\AppPools\$poolName") { Start-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
            Write-Warning "$Name rolled back to the previous current directory."
'@
$newRollback = @'
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $poolName = "iMonitorERP-$Name"
            if (Test-Path "IIS:\AppPools\$poolName") { Start-WebAppPool -Name $poolName -ErrorAction SilentlyContinue }
            if ($siteNames) {
                foreach ($siteName in $siteNames) {
                    if (Test-Path "IIS:\Sites\$siteName") { Start-WebSite -Name $siteName -ErrorAction SilentlyContinue }
                }
            }
            Write-Warning "$Name rolled back to the previous current directory."
'@
if (-not $text.Contains($oldRollback)) { throw 'Compatibility patch failed: rollback block not found in v2.0.10.' }
$text = $text.Replace($oldRollback, $newRollback)

Set-Content $base $text -Encoding UTF8

$invoke = @{
    Channel = $Channel
    InstallRoot = $InstallRoot
    PackageCacheDirectory = $PackageCacheDirectory
    TestPort = $TestPort
    ProductionPort = $ProductionPort
}
if ($Force) { $invoke.Force = $true }

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $base @(
        '-Channel', $Channel,
        '-InstallRoot', $InstallRoot,
        '-PackageCacheDirectory', $PackageCacheDirectory,
        '-TestPort', [string]$TestPort,
        '-ProductionPort', [string]$ProductionPort
    ) $(if ($Force) { '-Force' })
    if ($LASTEXITCODE -ne 0) { throw "Updater returned exit code $LASTEXITCODE" }
} finally {
    Remove-Item $base -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}

$installerHome = Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $installerHome | Out-Null
$self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.11.ps1'
Copy-Item $PSCommandPath $self -Force
$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -PackageCacheDirectory `"$PackageCacheDirectory`""
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -PackageCacheDirectory `"$PackageCacheDirectory`""
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /TR $prodAction | Out-Null
$global:LASTEXITCODE = 0

Write-Host 'iMonitor ERP updater v2.0.11 completed.'
Write-Host 'IIS activation policy: stop site -> stop app pool -> wait for handles -> atomic swap -> start pool/site -> health check.'
