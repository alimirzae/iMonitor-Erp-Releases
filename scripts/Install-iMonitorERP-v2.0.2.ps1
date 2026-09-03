[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP',
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [string]$MySqlServer = '127.0.0.1',
    [int]$MySqlPort = 3306,
    [string]$TestDatabase = 'imonitor_erp_test',
    [string]$ProductionDatabase = 'imonitor_erp_production',
    [string]$TestUser = 'imonitor_test',
    [string]$ProductionUser = 'imonitor_production',
    [string]$TestPassword,
    [string]$ProductionPassword,
    [string]$MySqlAdminUser = 'root',
    [string]$MySqlAdminPassword,
    [string]$BootstrapAdminNationalCode = $env:IMONITOR_BOOTSTRAP_NATIONAL_CODE,
    [string]$BootstrapAdminMobile = $env:IMONITOR_BOOTSTRAP_MOBILE,
    [switch]$SkipMySqlProvisioning,
    [switch]$UpdateOnly,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}

$repo = 'alimirzae/iMonitor-Erp-Releases'
$baseInstaller = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.1-hardened.ps1'
$uri = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.1.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Invoke-WebRequest -UseBasicParsing $uri -OutFile $baseInstaller

# Keep all verified v2.0.1 download/cache/MySQL/IIS behavior, but do not let an EF
# migration failure kill the IIS worker before the emergency recovery page is reachable.
$text = Get-Content $baseInstaller -Raw
$needle = "Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$true"
$replacement = "Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$false"
if (-not $text.Contains($needle)) { throw 'Compatibility check failed: MigrateOnStartup assignment was not found in v2.0.1.' }
$text = $text.Replace($needle, $replacement)
Set-Content $baseInstaller $text -Encoding UTF8

$invoke = @{
    Channel=$Channel; InstallRoot=$InstallRoot; PackageCacheDirectory=$PackageCacheDirectory;
    TestPort=$TestPort; ProductionPort=$ProductionPort; MySqlServer=$MySqlServer; MySqlPort=$MySqlPort;
    TestDatabase=$TestDatabase; ProductionDatabase=$ProductionDatabase; TestUser=$TestUser; ProductionUser=$ProductionUser;
    MySqlAdminUser=$MySqlAdminUser
}
if ($TestPassword) { $invoke.TestPassword=$TestPassword }
if ($ProductionPassword) { $invoke.ProductionPassword=$ProductionPassword }
if ($MySqlAdminPassword) { $invoke.MySqlAdminPassword=$MySqlAdminPassword }
if ($SkipMySqlProvisioning) { $invoke.SkipMySqlProvisioning=$true }
if ($UpdateOnly) { $invoke.UpdateOnly=$true }
if ($Force) { $invoke.Force=$true }
try { & $baseInstaller @invoke } finally { Remove-Item $baseInstaller -Force -ErrorAction SilentlyContinue }

function Ensure-Object([object]$Parent,[string]$Name) {
    $p=$Parent.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { $v=[pscustomobject]@{}; if($p){$p.Value=$v}else{$Parent|Add-Member NoteProperty $Name $v}; return $v }
    return $p.Value
}
function Set-Value([object]$Parent,[string]$Name,[object]$Value) {
    $p=$Parent.PSObject.Properties[$Name]; if($p){$p.Value=$Value}else{$Parent|Add-Member NoteProperty $Name $Value}
}
function Harden-Config([string]$Name) {
    $path=Join-Path $InstallRoot (Join-Path $Name.ToLowerInvariant() 'current\appsettings.json')
    if(-not(Test-Path $path)){return}
    $settings=Get-Content $path -Raw|ConvertFrom-Json
    $database=Ensure-Object $settings 'Database'; Set-Value $database 'MigrateOnStartup' $false; Set-Value $database 'AutoMigrate' $false
    $maintenance=Ensure-Object $settings 'Maintenance'; Set-Value $maintenance 'OtpExpiryMinutes' 5; Set-Value $maintenance 'AuthorizationMinutes' 15; Set-Value $maintenance 'MaxOtpAttempts' 5; Set-Value $maintenance 'ResendCooldownSeconds' 60
    $sms=Ensure-Object $settings 'SMS'; Set-Value $sms 'AllowSystemFallbackWhenDatabaseUnavailable' $true
    $bootstrap=Ensure-Object $settings 'BootstrapAdmin'
    if($BootstrapAdminNationalCode){Set-Value $bootstrap 'NationalCode' $BootstrapAdminNationalCode.Trim()}
    if($BootstrapAdminMobile){Set-Value $bootstrap 'Mobile' $BootstrapAdminMobile.Trim()}
    $settings|ConvertTo-Json -Depth 100|Set-Content $path -Encoding UTF8
}
if($Channel -in @('Both','Test')){Harden-Config 'Test'}
if($Channel -in @('Both','Production')){Harden-Config 'Production'}

Import-Module WebAdministration -ErrorAction SilentlyContinue
foreach($name in @('Test','Production')){
    if($Channel -ne 'Both' -and $Channel -ne $name){continue}
    $pool="iMonitorERP-$name"
    if(Test-Path "IIS:\AppPools\$pool"){Restart-WebAppPool -Name $pool}
}

$installerHome=Join-Path $InstallRoot 'installer'; New-Item -ItemType Directory -Force -Path $installerHome|Out-Null
$self=Join-Path $installerHome 'Install-iMonitorERP-v2.0.2.ps1'
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.2.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $self
$testAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction|Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC DAILY /ST 02:30 /RU SYSTEM /TR $prodAction|Out-Null

Write-Host 'iMonitor ERP installer v2.0.2 completed.'
Write-Host "Production: http://localhost:$ProductionPort"
Write-Host "Test: http://localhost:$TestPort"
Write-Host 'Emergency recovery: /Admin/Database/Migrate or /Account/Reset'
