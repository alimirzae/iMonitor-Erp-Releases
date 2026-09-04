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
$mirrorRoot = 'https://testerp.imonitor.ir/downloads/erp'
$configRoot = Join-Path $InstallRoot 'config'
$credentialFile = Join-Path $configRoot 'mysql-credentials.json'
$installerHome = Join-Path $InstallRoot 'installer'
$stateRoot = Join-Path $InstallRoot 'state'
$sourcePreferenceFile = Join-Path $stateRoot 'download-source.txt'
New-Item -ItemType Directory -Force -Path $InstallRoot,$configRoot,$installerHome,$stateRoot | Out-Null

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

function Test-UrlLatency([string]$Uri,[bool]$ForceIpv4=$false) {
    try {
        $sw=[Diagnostics.Stopwatch]::StartNew()
        $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
        if($curl){
            $args=@('--silent','--show-error','--fail','--location','--head','--connect-timeout','3','--max-time','6')
            if($ForceIpv4){$args=@('-4')+$args}
            & $curl.Source @args $Uri | Out-Null
            if($LASTEXITCODE -ne 0){return [double]::PositiveInfinity}
        } else {
            Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Uri -TimeoutSec 6 | Out-Null
        }
        $sw.Stop(); return $sw.Elapsed.TotalMilliseconds
    } catch { return [double]::PositiveInfinity }
}

function Get-PreferredSource {
    $mirrorProbe="$mirrorRoot/test/latest.json?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $githubProbe="https://api.github.com/repos/$repo/releases?per_page=1&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $mirrorMs=Test-UrlLatency $mirrorProbe $false
    $githubMs=Test-UrlLatency $githubProbe $true
    Write-Host ("Download source probe: mirror={0} ms, github-ipv4={1} ms" -f ([math]::Round($mirrorMs)),([math]::Round($githubMs)))
    if([double]::IsPositiveInfinity($mirrorMs) -and [double]::IsPositiveInfinity($githubMs)){
        if(Test-Path $sourcePreferenceFile){return (Get-Content $sourcePreferenceFile -Raw).Trim()}
        return 'mirror'
    }
    $selected=if($mirrorMs -le $githubMs){'mirror'}else{'github'}
    Set-Content $sourcePreferenceFile $selected -Encoding ASCII
    return $selected
}

function Invoke-SourceDownload([string]$MirrorUri,[string]$GithubUri,[string]$OutFile,[string]$Label) {
    $preferred=Get-PreferredSource
    $sources=if($preferred -eq 'mirror'){@(@('mirror',$MirrorUri,$false),@('github',$GithubUri,$true))}else{@(@('github',$GithubUri,$true),@('mirror',$MirrorUri,$false))}
    $last=$null
    foreach($source in $sources){
        $name=$source[0]; $uri=$source[1]; $ipv4=[bool]$source[2]
        try {
            Write-Host "$Label via $name..."
            $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
            if($curl){
                $args=@('--http1.1','--fail','--location','--connect-timeout','8','--max-time','120','--retry','3','--retry-all-errors',$uri,'-o',$OutFile)
                if($ipv4){$args=@('-4')+$args}
                & $curl.Source @args
                if($LASTEXITCODE -ne 0){throw "curl exit code $LASTEXITCODE"}
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $OutFile -TimeoutSec 120
            }
            if(!(Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0){throw 'Downloaded file is empty.'}
            Set-Content $sourcePreferenceFile $name -Encoding ASCII
            return
        } catch {
            $last=$_.Exception.Message
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Warning "$Label via $name failed: $last"
        }
    }
    throw "$Label failed from domestic mirror and GitHub IPv4. Last error: $last"
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
        Write-Warning "Could not read runtime config ${path}: $($_.Exception.Message)"
    }
    return $null
}

$saved = $null
if (Test-Path $credentialFile) {
    try { $saved = Get-Content $credentialFile -Raw | ConvertFrom-Json }
    catch { throw "Invalid MySQL credential file: $credentialFile. $($_.Exception.Message)" }
}

# Explicit CLI > persisted credentials > installed appsettings > defaults.
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
Invoke-SourceDownload `
    "$mirrorRoot/install/Install-iMonitorERP-v2.0.2.ps1.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.2.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    $baseInstaller 'Base installer download'

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

$self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.5.ps1'
Invoke-SourceDownload `
    "$mirrorRoot/install/Install-iMonitorERP-v2.0.5.ps1.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.5.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    $self 'Installer self-refresh'

$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /TR $prodAction | Out-Null

Write-Host ''
Write-Host 'iMonitor ERP installer/updater v2.0.5 completed.'
Write-Host "Persistent MySQL settings: $credentialFile"
Write-Host "Preferred download source: $sourcePreferenceFile"
Write-Host "Production: http://localhost:$ProductionPort"
Write-Host "Test: http://localhost:$TestPort"
Write-Host 'Automatic update checks: Test every 5 minutes; Production every 5 minutes.'
Write-Host 'Domestic mirror and GitHub IPv4 are probed; the faster healthy source is preferred and the other is automatic fallback.'
