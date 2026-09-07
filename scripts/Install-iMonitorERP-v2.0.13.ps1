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

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}

$repo = 'alimirzae/iMonitor-Erp-Releases'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$PackageCacheDirectory = [IO.Path]::GetFullPath($PackageCacheDirectory)
$core = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.13-core.ps1'
$sourceCore = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.12-core-source.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$uri = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.12-core.ps1?cb=$cb"

Write-Host 'iMonitor ERP Windows installer v2.0.13' -ForegroundColor Cyan
Write-Host "Install root : $InstallRoot"
Write-Host "Package cache: $PackageCacheDirectory"
Write-Host "Channel      : $Channel"
Write-Host 'Downloading installer core over IPv4...'

& curl.exe -4 --http1.1 --fail --location --connect-timeout 8 --max-time 180 --retry 3 --retry-all-errors $uri -o $sourceCore
$curlExit = $LASTEXITCODE
$global:LASTEXITCODE = 0
if ($curlExit -ne 0 -or -not (Test-Path $sourceCore -PathType Leaf) -or (Get-Item $sourceCore).Length -le 0) {
    throw "Could not download installer core. curl exit code=$curlExit"
}

# Refresh PATH after prerequisites may have been installed in a previous run.
$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
$env:Path = (($machinePath,$userPath) -join ';').Trim(';')
$dotnetDir = Join-Path $env:ProgramFiles 'dotnet'
if ((Test-Path (Join-Path $dotnetDir 'dotnet.exe')) -and ($env:Path -notlike "*$dotnetDir*")) {
    $env:Path = "$dotnetDir;$env:Path"
}
if (Test-Path (Join-Path $dotnetDir 'dotnet.exe')) { Write-Host "Detected dotnet host: $dotnetDir\dotnet.exe" }

# v2.0.13 hardens IIS lifecycle operations so reruns are safe when a Site/AppPool is already stopped/started.
$text = Get-Content $sourceCore -Raw
$text = $text.Replace("if (Test-Path `"IIS:\Sites\`$siteName`") { Stop-WebSite -Name `$siteName -ErrorAction SilentlyContinue }", "if (Test-Path `"IIS:\Sites\`$siteName`") { try { if ((Get-WebsiteState -Name `$siteName).Value -ne 'Stopped') { Stop-WebSite -Name `$siteName -ErrorAction Stop } } catch { if (`$_.Exception.Message -notmatch 'already stopped') { throw } } }")
$text = $text.Replace("if (Test-Path `"IIS:\AppPools\`$poolName`") { Stop-WebAppPool -Name `$poolName -ErrorAction SilentlyContinue }", "if (Test-Path `"IIS:\AppPools\`$poolName`") { try { if ((Get-WebAppPoolState -Name `$poolName).Value -ne 'Stopped') { Stop-WebAppPool -Name `$poolName -ErrorAction Stop } } catch { if (`$_.Exception.Message -notmatch 'already stopped') { throw } } }")
$text = $text.Replace("Start-WebAppPool -Name `$poolName; Start-WebSite -Name `$siteName", "if ((Get-WebAppPoolState -Name `$poolName).Value -ne 'Started') { Start-WebAppPool -Name `$poolName }; if ((Get-WebsiteState -Name `$siteName).Value -ne 'Started') { Start-WebSite -Name `$siteName }")
$text = $text.Replace("try {Stop-WebSite -Name `$siteName -ErrorAction SilentlyContinue;Stop-WebAppPool -Name `$poolName -ErrorAction SilentlyContinue}catch{}", "try { if ((Test-Path `"IIS:\Sites\`$siteName`") -and (Get-WebsiteState -Name `$siteName).Value -ne 'Stopped') { Stop-WebSite -Name `$siteName -ErrorAction SilentlyContinue }; if ((Test-Path `"IIS:\AppPools\`$poolName`") -and (Get-WebAppPoolState -Name `$poolName).Value -ne 'Stopped') { Stop-WebAppPool -Name `$poolName -ErrorAction SilentlyContinue } } catch {}")
$text = $text.Replace("try{Start-WebAppPool -Name `$poolName -ErrorAction SilentlyContinue;Start-WebSite -Name `$siteName -ErrorAction SilentlyContinue}catch{}", "try { if ((Test-Path `"IIS:\AppPools\`$poolName`") -and (Get-WebAppPoolState -Name `$poolName).Value -ne 'Started') { Start-WebAppPool -Name `$poolName -ErrorAction SilentlyContinue }; if ((Test-Path `"IIS:\Sites\`$siteName`") -and (Get-WebsiteState -Name `$siteName).Value -ne 'Started') { Start-WebSite -Name `$siteName -ErrorAction SilentlyContinue } } catch {}")
Set-Content -Path $core -Value $text -Encoding UTF8

$argsList = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$core,
    '-Channel',$Channel,
    '-InstallRoot',$InstallRoot,
    '-PackageCacheDirectory',$PackageCacheDirectory,
    '-TestPort',[string]$TestPort,
    '-ProductionPort',[string]$ProductionPort
)
if ($Force) { $argsList += '-Force' }

try {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "Installer core returned exit code $($p.ExitCode)" }

    # Replace v2.0.12 scheduled updater tasks with v2.0.13 so future runs remain on the hardened installer.
    $installerHome = Join-Path $InstallRoot 'installer'
    New-Item -ItemType Directory -Force -Path $installerHome | Out-Null
    $self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.13.ps1'
    Copy-Item $PSCommandPath $self -Force

    $testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort"
    $prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort"
    & schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $testAction | Out-Null
    & schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $prodAction | Out-Null
    $global:LASTEXITCODE = 0

    Write-Host ''
    Write-Host 'iMonitor ERP installer/updater v2.0.13 completed.' -ForegroundColor Green
    Write-Host "Automatic updater path: $self"
} finally {
    Remove-Item $sourceCore,$core -Force -ErrorAction SilentlyContinue
}
