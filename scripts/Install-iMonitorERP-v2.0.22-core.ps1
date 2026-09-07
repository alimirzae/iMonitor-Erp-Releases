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

$repo='alimirza/iMonitor-Erp-Releases'
$pinnedCommit='d30ba7b25f6ee9f97a3fabe5a1ccb9ac0ca6a54c'
$source=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.21-core-source-'+[guid]::NewGuid().ToString('N')+'.ps1')
$patched=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.22-core-patched-'+[guid]::NewGuid().ToString('N')+'.ps1')
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/$pinnedCommit/scripts/Install-iMonitorERP-v2.0.21-core.ps1?cb=$cb"

try {
    Write-Host '=== iMonitor ERP CORE v2.0.22 ===' -ForegroundColor Cyan
    Write-Host 'Core revision : 2.0.22-r1 (PowerShell parser fix + AppPool recovery)' -ForegroundColor DarkCyan

    & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $uri -o $source 2>$null
    $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
    if($ec -ne 0 -or -not(Test-Path $source -PathType Leaf)){ throw "Could not download pinned v2.0.21 core. curl exit=$ec" }

    $text=Get-Content $source -Raw
    $bad='Write-Host "$Name IIS state: Site=$siteState; AppPool=$poolState; Binding=*:$Port:" -ForegroundColor Cyan'
    $good='Write-Host "$Name IIS state: Site=$siteState; AppPool=$poolState; Binding=*:${Port}:" -ForegroundColor Cyan'
    if(-not $text.Contains($bad)){ throw 'Could not locate the v2.0.21 parser bug for patching.' }
    $text=$text.Replace($bad,$good)
    $text=$text.Replace("=== iMonitor ERP CORE v2.0.21 ===","=== iMonitor ERP CORE v2.0.22 (patched v2.0.21 logic) ===")
    Set-Content $patched $text -Encoding UTF8

    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$patched,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
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
    Remove-Item $source,$patched -Force -ErrorAction SilentlyContinue
}
