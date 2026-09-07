[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = (Get-Location).Path,
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [string]$MySqlBinPath = '',
    [string]$MySqlHost = '',
    [int]$MySqlPort = 0,
    [string]$MySqlRootUser = '',
    [string]$MySqlRootPassword = '',
    [switch]$Force,
    [switch]$UpdateOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator.' }
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
$PackageCacheDirectory=[IO.Path]::GetFullPath($PackageCacheDirectory)
$installerHome=Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $InstallRoot,$PackageCacheDirectory,$installerHome | Out-Null
Write-Host '=== iMonitor ERP Windows installer v2.0.21 ===' -ForegroundColor Cyan
Write-Host 'Installer revision: 2.0.21-r1 (AppPool recovery + ANCM diagnostics)' -ForegroundColor DarkCyan
Write-Host "Install root : $InstallRoot"
Write-Host "Package cache: $PackageCacheDirectory"
Write-Host "Channel      : $Channel"
Write-Host 'MySQL        : existing installation only; no MySQL download/install/update' -ForegroundColor Cyan
$self=Join-Path $installerHome 'Install-iMonitorERP-v2.0.21.ps1'
Copy-Item $PSCommandPath $self -Force
foreach($old in @('Install-iMonitorERP-v2.0.15.ps1','Install-iMonitorERP-v2.0.16.ps1','Install-iMonitorERP-v2.0.17.ps1','Install-iMonitorERP-v2.0.18.ps1','Install-iMonitorERP-v2.0.19.ps1','Install-iMonitorERP-v2.0.20.ps1')){ $p=Join-Path $installerHome $old; if(Test-Path $p){Remove-Item $p -Force -ErrorAction SilentlyContinue} }
function Register-Updaters {
  $testAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort -UpdateOnly"
  $prodAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -InstallRoot `"$InstallRoot`" -PackageCacheDirectory `"$PackageCacheDirectory`" -TestPort $TestPort -ProductionPort $ProductionPort -UpdateOnly"
  & schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $testAction | Out-Null
  & schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $prodAction | Out-Null
  $global:LASTEXITCODE=0
  Write-Host '[OK] Automatic updater tasks now point to v2.0.21 (every 5 minutes).' -ForegroundColor Green
}
Register-Updaters
$repo='alimirzae/iMonitor-Erp-Releases'
$core=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.21-core-'+[guid]::NewGuid().ToString('N')+'.ps1')
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.21-core.ps1?cb=$cb"
Write-Host 'Downloading installer core v2.0.21 over IPv4...'
& curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $uri -o $core 2>$null
$curlExit=$LASTEXITCODE; $global:LASTEXITCODE=0
if($curlExit -ne 0 -or -not(Test-Path $core -PathType Leaf)){throw "Could not download installer core. curl exit code=$curlExit"}
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$core,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
if($MySqlBinPath){$args+=@('-MySqlBinPath',$MySqlBinPath)}
if($MySqlHost){$args+=@('-MySqlHost',$MySqlHost)}
if($MySqlPort -gt 0){$args+=@('-MySqlPort',[string]$MySqlPort)}
if($MySqlRootUser){$args+=@('-MySqlRootUser',$MySqlRootUser)}
if($MySqlRootPassword){$args+=@('-MySqlRootPassword',$MySqlRootPassword)}
if($Force){$args+='-Force'}
if($UpdateOnly){$args+='-UpdateOnly'}
try {
  $p=Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
  if($p.ExitCode -ne 0){throw "Installer core returned exit code $($p.ExitCode)"}
} finally { Remove-Item $core -Force -ErrorAction SilentlyContinue; Register-Updaters }
Write-Host 'iMonitor ERP v2.0.21 completed.' -ForegroundColor Green
Write-Host "Installer: $self"
