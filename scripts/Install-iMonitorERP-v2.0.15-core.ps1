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
Write-Host 'v2.0.15 core is retired; forwarding to v2.0.16 core...' -ForegroundColor Yellow
Write-Host 'MySQL is existing-only; no MySQL package/update is downloaded.' -ForegroundColor Cyan

$repo='alimirzae/iMonitor-Erp-Releases'
$core=Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.16-core.ps1'
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.16-core.ps1?cb=$cb"
& curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors $uri -o $core 2>$null
$ec=$LASTEXITCODE; $global:LASTEXITCODE=0
if($ec -ne 0 -or -not(Test-Path $core -PathType Leaf) -or (Get-Item $core).Length -le 0){throw "Could not download v2.0.16 core. curl exit=$ec"}

$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$core,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
if($MySqlBinPath){$args+=@('-MySqlBinPath',$MySqlBinPath)}
if($MySqlHost){$args+=@('-MySqlHost',$MySqlHost)}
if($MySqlPort -gt 0){$args+=@('-MySqlPort',[string]$MySqlPort)}
if($MySqlRootUser){$args+=@('-MySqlRootUser',$MySqlRootUser)}
if($MySqlRootPassword){$args+=@('-MySqlRootPassword',$MySqlRootPassword)}
if($Force){$args+='-Force'}
if($UpdateOnly){$args+='-UpdateOnly'}
$p=Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
Remove-Item $core -Force -ErrorAction SilentlyContinue
exit $p.ExitCode
