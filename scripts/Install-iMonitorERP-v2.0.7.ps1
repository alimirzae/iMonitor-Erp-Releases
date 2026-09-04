[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP',
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [string]$MySqlServer,
    [int]$MySqlPort = 0,
    [string]$TestDatabase,
    [string]$ProductionDatabase,
    [string]$TestUser,
    [string]$ProductionUser,
    [string]$TestPassword,
    [string]$ProductionPassword,
    [string]$MySqlAdminUser = 'root',
    [string]$MySqlAdminPassword,
    [switch]$SkipMySqlProvisioning,
    [switch]$UpdateOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = 'alimirzae/iMonitor-Erp-Releases'
$next = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.8.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$url = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.8.ps1?cb=$cb"

Write-Host 'Installer v2.0.7 is superseded by v2.0.8; loading current updater...'
& curl.exe -4 --silent --show-error --http1.1 --fail --location --connect-timeout 8 --max-time 120 --retry 3 --retry-all-errors $url -o $next
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $next)) { throw 'Could not download installer v2.0.8.' }
$global:LASTEXITCODE = 0

$invoke = @{
    Channel=$Channel
    InstallRoot=$InstallRoot
    PackageCacheDirectory=$PackageCacheDirectory
    TestPort=$TestPort
    ProductionPort=$ProductionPort
    MySqlAdminUser=$MySqlAdminUser
}
foreach ($name in @('MySqlServer','MySqlPort','TestDatabase','ProductionDatabase','TestUser','ProductionUser','TestPassword','ProductionPassword','MySqlAdminPassword')) {
    if ($PSBoundParameters.ContainsKey($name)) { $invoke[$name] = $PSBoundParameters[$name] }
}
if ($SkipMySqlProvisioning) { $invoke.SkipMySqlProvisioning = $true }
if ($UpdateOnly) { $invoke.UpdateOnly = $true }
if ($Force) { $invoke.Force = $true }

try { & $next @invoke }
finally { Remove-Item $next -Force -ErrorAction SilentlyContinue }
