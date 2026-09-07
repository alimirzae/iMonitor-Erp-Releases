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

Write-Host 'v2.0.15 is retired; forwarding to installer v2.0.16...' -ForegroundColor Yellow
Write-Host 'MySQL is existing-only; no MySQL package/update will be downloaded.' -ForegroundColor Cyan

$repo='alimirzae/iMonitor-Erp-Releases'
$next=Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.16.ps1'
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.16.ps1?cb=$cb"

& curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors $uri -o $next 2>$null
$ec=$LASTEXITCODE; $global:LASTEXITCODE=0
if($ec -ne 0 -or -not(Test-Path $next -PathType Leaf) -or (Get-Item $next).Length -le 0){throw "Could not download v2.0.16 bootstrap. curl exit=$ec"}

$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$next,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
if($MySqlBinPath){$args+=@('-MySqlBinPath',$MySqlBinPath)}
if($MySqlHost){$args+=@('-MySqlHost',$MySqlHost)}
if($MySqlPort -gt 0){$args+=@('-MySqlPort',[string]$MySqlPort)}
if($MySqlRootUser){$args+=@('-MySqlRootUser',$MySqlRootUser)}
if($MySqlRootPassword){$args+=@('-MySqlRootPassword',$MySqlRootPassword)}
if($Force){$args+='-Force'}
if($UpdateOnly){$args+='-UpdateOnly'}

$p=Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
Remove-Item $next -Force -ErrorAction SilentlyContinue
exit $p.ExitCode
