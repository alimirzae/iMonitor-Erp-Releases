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
$configRoot = Join-Path $InstallRoot 'config'
$credentialFile = Join-Path $configRoot 'mysql-credentials.json'
$installerHome = Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $InstallRoot,$configRoot,$installerHome | Out-Null

function Get-SavedProperty([object]$Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function First-NonEmpty([object[]]$Values) {
    foreach ($value in $Values) {
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text)) { return $value }
    }
    return $null
}

function Get-RuntimeConfigValue([string]$ChannelName,[string]$PropertyName) {
    $path = Join-Path $InstallRoot (Join-Path $ChannelName.ToLowerInvariant() 'current\appsettings.json')
    if (-not (Test-Path $path)) { return $null }
    try {
        $settings = Get-Content $path -Raw | ConvertFrom-Json
        $mysql = $settings.Database.MySql
        switch ($PropertyName) {
            'Server' { return $mysql.Server }
            'Port' { return $mysql.Port }
            'User' { return (First-NonEmpty @($mysql.UserId,$mysql.User)) }
            'Database' {
                $cs = [string](First-NonEmpty @($mysql.ConnectionString,$settings.ConnectionStrings.MySql))
                if ($cs -match '(?i)(?:^|;)\s*(?:Database|Initial Catalog)\s*=\s*([^;]+)') { return $matches[1].Trim() }
                return $null
            }
        }
    } catch {
        Write-Warning "Could not read runtime config $path: $($_.Exception.Message)"
    }
    return $null
}

$saved = $null
if (Test-Path $credentialFile) {
    try { $saved = Get-Content $credentialFile -Raw | ConvertFrom-Json }
    catch { throw "Invalid MySQL credential file: $credentialFile. $($_.Exception.Message)" }
}

# v2.0.3 rule: explicit CLI value > persisted credential file > currently installed appsettings > built-in default.
# This prevents scheduled -UpdateOnly runs from silently resetting custom database/user names.
if (-not $PSBoundParameters.ContainsKey('MySqlServer')) {
    $MySqlServer = [string](First-NonEmpty @((Get-SavedProperty $saved 'Server'),(Get-RuntimeConfigValue 'Test' 'Server'),(Get-RuntimeConfigValue 'Production' 'Server'),'127.0.0.1'))
}
if (-not $PSBoundParameters.ContainsKey('MySqlPort') -or $MySqlPort -le 0) {
    $savedPort = First-NonEmpty @((Get-SavedProperty $saved 'Port'),(Get-RuntimeConfigValue 'Test' 'Port'),(Get-RuntimeConfigValue 'Production' 'Port'),3306)
    $MySqlPort = [int]$savedPort
}
if (-not $PSBoundParameters.ContainsKey('TestDatabase')) {
    $TestDatabase = [string](First-NonEmpty @((Get-SavedProperty $saved 'TestDatabase'),(Get-RuntimeConfigValue 'Test' 'Database'),'imonitor_erp_test'))
}
if (-not $PSBoundParameters.ContainsKey('ProductionDatabase')) {
    $ProductionDatabase = [string](First-NonEmpty @((Get-SavedProperty $saved 'ProductionDatabase'),(Get-RuntimeConfigValue 'Production' 'Database'),'imonitor_erp_production'))
}
if (-not $PSBoundParameters.ContainsKey('TestUser')) {
    $TestUser = [string](First-NonEmpty @((Get-SavedProperty $saved 'TestUser'),(Get-RuntimeConfigValue 'Test' 'User'),'imonitor_test'))
}
if (-not $PSBoundParameters.ContainsKey('ProductionUser')) {
    $ProductionUser = [string](First-NonEmpty @((Get-SavedProperty $saved 'ProductionUser'),(Get-RuntimeConfigValue 'Production' 'User'),'imonitor_production'))
}
if ([string]::IsNullOrWhiteSpace($TestPassword)) { $TestPassword = [string](Get-SavedProperty $saved 'TestPassword') }
if ([string]::IsNullOrWhiteSpace($ProductionPassword)) { $ProductionPassword = [string](Get-SavedProperty $saved 'ProductionPassword') }

Write-Host "Resolved MySQL Test: $MySqlServer`:$MySqlPort / $TestDatabase / $TestUser"
Write-Host "Resolved MySQL Production: $MySqlServer`:$MySqlPort / $ProductionDatabase / $ProductionUser"

# Persist non-secret connection identity before calling the base installer. Passwords are written by the base installer.
# If the file already contains passwords, preserve them here so a failed download cannot destroy valid credentials.
$credentialSnapshot = [ordered]@{
    Server = $MySqlServer
    Port = $MySqlPort
    TestDatabase = $TestDatabase
    TestUser = $TestUser
    TestPassword = $TestPassword
    ProductionDatabase = $ProductionDatabase
    ProductionUser = $ProductionUser
    ProductionPassword = $ProductionPassword
}
$credentialSnapshot | ConvertTo-Json | Set-Content $credentialFile -Encoding UTF8
& icacls $configRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null

$baseInstaller = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.2-base.ps1'
$uri = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.2.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Invoke-WebRequest -UseBasicParsing $uri -OutFile $baseInstaller

$invoke = @{
    Channel = $Channel
    InstallRoot = $InstallRoot
    PackageCacheDirectory = $PackageCacheDirectory
    TestPort = $TestPort
    ProductionPort = $ProductionPort
    MySqlServer = $MySqlServer
    MySqlPort = $MySqlPort
    TestDatabase = $TestDatabase
    ProductionDatabase = $ProductionDatabase
    TestUser = $TestUser
    ProductionUser = $ProductionUser
    MySqlAdminUser = $MySqlAdminUser
}
if (-not [string]::IsNullOrWhiteSpace($TestPassword)) { $invoke.TestPassword = $TestPassword }
if (-not [string]::IsNullOrWhiteSpace($ProductionPassword)) { $invoke.ProductionPassword = $ProductionPassword }
if (-not [string]::IsNullOrWhiteSpace($MySqlAdminPassword)) { $invoke.MySqlAdminPassword = $MySqlAdminPassword }
if (-not [string]::IsNullOrWhiteSpace($BootstrapAdminNationalCode)) { $invoke.BootstrapAdminNationalCode = $BootstrapAdminNationalCode }
if (-not [string]::IsNullOrWhiteSpace($BootstrapAdminMobile)) { $invoke.BootstrapAdminMobile = $BootstrapAdminMobile }
if ($SkipMySqlProvisioning) { $invoke.SkipMySqlProvisioning = $true }
if ($UpdateOnly) { $invoke.UpdateOnly = $true }
if ($Force) { $invoke.Force = $true }

try {
    & $baseInstaller @invoke
} finally {
    Remove-Item $baseInstaller -Force -ErrorAction SilentlyContinue
}

# v2.0.2 creates tasks that point back to v2.0.2. Replace them with v2.0.3.
# Passwords are intentionally NOT placed in Task Scheduler command lines; v2.0.3 reloads them from the protected credential file.
$self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.3.ps1'
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.3.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $self

$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC DAILY /ST 02:30 /RU SYSTEM /TR $prodAction | Out-Null

Write-Host ''
Write-Host 'iMonitor ERP installer v2.0.3 completed.'
Write-Host "Persistent MySQL settings: $credentialFile"
Write-Host "Production: http://localhost:$ProductionPort"
Write-Host "Test: http://localhost:$TestPort"
Write-Host 'Future UpdateOnly runs preserve Server/Port/Database/User/Password unless explicitly overridden.'
