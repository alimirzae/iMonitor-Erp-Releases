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
$core = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.12-core.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$uri = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.12-core.ps1?cb=$cb"

Write-Host 'Downloading iMonitor ERP installer core v2.0.12 over IPv4...'
& curl.exe -4 --http1.1 --fail --location --connect-timeout 8 --max-time 180 --retry 3 --retry-all-errors $uri -o $core
$curlExit = $LASTEXITCODE
$global:LASTEXITCODE = 0
if ($curlExit -ne 0 -or -not (Test-Path $core -PathType Leaf) -or (Get-Item $core).Length -le 0) {
    throw "Could not download installer core. curl exit code=$curlExit"
}

$argsList = @(
    '-NoProfile',
    '-ExecutionPolicy','Bypass',
    '-File',$core,
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
} finally {
    Remove-Item $core -Force -ErrorAction SilentlyContinue
}
