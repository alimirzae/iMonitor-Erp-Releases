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

$repo='alimirzae/iMonitor-Erp-Releases'
# Pin the already-fixed 2.0.17-r2 core by commit so branch/CDN changes cannot alter execution.
$pinnedCommit='7d22f21a93870c46cea7b6c0aa98b0d8bbae6d22'
$pinned=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.18-pinned-'+[guid]::NewGuid().ToString('N')+'.ps1')
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/$pinnedCommit/scripts/Install-iMonitorERP-v2.0.17-core.ps1?cb=$cb"

try {
    Write-Host '=== iMonitor ERP CORE v2.0.18 ===' -ForegroundColor Cyan
    Write-Host 'Core revision : 2.0.18-r1 (pinned 2.0.17-r2 logic)' -ForegroundColor DarkCyan
    Write-Host 'MySQL policy  : existing installation only; no download/install/update' -ForegroundColor Cyan
    Write-Host 'Test DB       : ecomm_dev'
    Write-Host 'Production DB : ecomm'
    Write-Host 'Migration     : deferred/disabled during installer run'

    & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $uri -o $pinned 2>$null
    $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
    if($ec -ne 0 -or -not(Test-Path $pinned -PathType Leaf) -or (Get-Item $pinned).Length -le 0){
        throw "Could not download pinned installer core. curl exit=$ec"
    }

    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$pinned,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
    if($MySqlBinPath){$args+=@('-MySqlBinPath',$MySqlBinPath)}
    if($MySqlHost){$args+=@('-MySqlHost',$MySqlHost)}
    if($MySqlPort -gt 0){$args+=@('-MySqlPort',[string]$MySqlPort)}
    if($MySqlRootUser){$args+=@('-MySqlRootUser',$MySqlRootUser)}
    if($MySqlRootPassword){$args+=@('-MySqlRootPassword',$MySqlRootPassword)}
    if($Force){$args+='-Force'}
    if($UpdateOnly){$args+='-UpdateOnly'}

    $p=Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}
finally {
    Remove-Item $pinned -Force -ErrorAction SilentlyContinue
}
