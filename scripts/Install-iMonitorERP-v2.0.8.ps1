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
$ErrorActionPreference='Stop'
$repo='alimirzae/iMonitor-Erp-Releases'
$next=Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.9.ps1'
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$url="https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.9.ps1?cb=$cb"
& curl.exe -4 --silent --show-error --fail --location --connect-timeout 8 --max-time 120 --retry 3 --retry-all-errors $url -o $next
if($LASTEXITCODE -ne 0){throw 'Could not download installer v2.0.9 from GitHub over IPv4.'}
$invoke=@{Channel=$Channel;InstallRoot=$InstallRoot;PackageCacheDirectory=$PackageCacheDirectory;TestPort=$TestPort;ProductionPort=$ProductionPort;MySqlAdminUser=$MySqlAdminUser}
foreach($name in @('MySqlServer','MySqlPort','TestDatabase','ProductionDatabase','TestUser','ProductionUser','TestPassword','ProductionPassword','MySqlAdminPassword')){if($PSBoundParameters.ContainsKey($name)){$invoke[$name]=Get-Variable -Name $name -ValueOnly}}
if($SkipMySqlProvisioning){$invoke.SkipMySqlProvisioning=$true};if($UpdateOnly){$invoke.UpdateOnly=$true};if($Force){$invoke.Force=$true}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $next @($invoke.GetEnumerator() | ForEach-Object { "-$($_.Key)"; [string]$_.Value })
exit $LASTEXITCODE
