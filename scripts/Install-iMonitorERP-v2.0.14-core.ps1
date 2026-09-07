[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = (Get-Location).Path,
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [int]$ManagedMySqlPort = 3307,
    [switch]$Force,
    [switch]$UpdateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-IsAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdministrator)) { throw 'Run PowerShell as Administrator.' }

$repo = 'alimirzae/iMonitor-Erp-Releases'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$PackageCacheDirectory = [IO.Path]::GetFullPath($PackageCacheDirectory)
$configRoot = Join-Path $InstallRoot 'config'
$mysqlRoot = Join-Path $InstallRoot 'mysql'
$mysqlServerRoot = Join-Path $mysqlRoot 'server'
$mysqlDataRoot = Join-Path $mysqlRoot 'data'
$mysqlLogRoot = Join-Path $mysqlRoot 'logs'
$mysqlIni = Join-Path $mysqlRoot 'my.ini'
$mysqlState = Join-Path $configRoot 'mysql-managed.json'
$serviceName = 'iMonitorERP-MySQL'
$mysqlVersion = '8.4.11'
$mysqlZipName = "mysql-$mysqlVersion-winx64.zip"
$mysqlZipUrl = "https://dev.mysql.com/get/Downloads/MySQL-8.4/$mysqlZipName"
$vcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

New-Item -ItemType Directory -Force -Path $InstallRoot,$PackageCacheDirectory,$configRoot,$mysqlRoot,$mysqlLogRoot | Out-Null

Write-Host 'iMonitor ERP installer core v2.0.14' -ForegroundColor Cyan
Write-Host "Install root : $InstallRoot"
Write-Host "Package cache: $PackageCacheDirectory"
Write-Host "Channel      : $Channel"
Write-Host "MySQL port   : $ManagedMySqlPort"

function New-Secret([int]$Length = 32) {
    $chars = (48..57) + (65..90) + (97..122)
    -join (1..$Length | ForEach-Object { [char]($chars | Get-Random) })
}

function Invoke-CurlDownload([string]$Uri,[string]$OutFile,[string]$Label,[int]$MaxTime = 1800) {
    $curl = Get-Command curl.exe -ErrorAction Stop
    $last = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Host "$Label (attempt $attempt/4)..."
            & $curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time $MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.14' $Uri -o $OutFile
            $code = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            if ($code -ne 0) { throw "curl exit code $code" }
            if (-not (Test-Path $OutFile -PathType Leaf) -or (Get-Item $OutFile).Length -le 0) { throw 'Downloaded file is empty.' }
            return
        } catch {
            $last = $_.Exception.Message
            Start-Sleep -Seconds ([Math]::Min($attempt * 2, 6))
        }
    }
    throw "$Label failed. Last error: $last"
}

function Ensure-VcRuntime {
    $vc = Join-Path $env:TEMP 'vc_redist.x64.exe'
    try {
        Invoke-CurlDownload $vcRedistUrl $vc 'Visual C++ runtime' 600
        $p = Start-Process -FilePath $vc -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
        if ($p.ExitCode -notin @(0,1638,1641,3010)) { throw "Visual C++ runtime installer returned $($p.ExitCode)." }
    } finally { Remove-Item $vc -Force -ErrorAction SilentlyContinue }
}

function Get-MySqlBinaries {
    if (-not (Test-Path $mysqlServerRoot -PathType Container)) { return $null }
    $mysqld = Get-ChildItem $mysqlServerRoot -Filter mysqld.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mysqld) { return $null }
    $mysql = Join-Path $mysqld.Directory.FullName 'mysql.exe'
    if (-not (Test-Path $mysql -PathType Leaf)) { return $null }
    [pscustomobject]@{ MySqlD=$mysqld.FullName; MySql=$mysql; BaseDir=$mysqld.Directory.Parent.FullName }
}

function Install-ManagedMySqlFiles {
    $bins = Get-MySqlBinaries
    if ($bins) { return $bins }

    Ensure-VcRuntime
    $cacheDir = Join-Path $PackageCacheDirectory 'mysql'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $zip = Join-Path $cacheDir $mysqlZipName
    if (-not (Test-Path $zip -PathType Leaf) -or (Get-Item $zip).Length -lt 50MB) {
        Invoke-CurlDownload $mysqlZipUrl $zip "MySQL $mysqlVersion package" 3600
    } else {
        Write-Host "Using cached MySQL package: $zip" -ForegroundColor Green
    }

    Remove-Item $mysqlServerRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $mysqlServerRoot | Out-Null
    Expand-Archive $zip $mysqlServerRoot -Force
    $bins = Get-MySqlBinaries
    if (-not $bins) { throw 'MySQL package extracted but mysql.exe/mysqld.exe was not found.' }
    return $bins
}

function Write-MySqlIni([string]$BaseDir) {
    New-Item -ItemType Directory -Force -Path $mysqlDataRoot,$mysqlLogRoot | Out-Null
    $base = $BaseDir.Replace('\','/')
    $data = $mysqlDataRoot.Replace('\','/')
    $log = (Join-Path $mysqlLogRoot 'mysql-error.log').Replace('\','/')
    @"
[mysqld]
basedir=$base
datadir=$data
port=$ManagedMySqlPort
bind-address=127.0.0.1
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_connections=250
log-error=$log
sql_mode=STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION

[client]
port=$ManagedMySqlPort
host=127.0.0.1
default-character-set=utf8mb4
"@ | Set-Content $mysqlIni -Encoding ASCII
}

function Test-TcpPort([int]$Port) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1',$Port,$null,$null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1500,$false)) { $c.Close(); return $false }
        $c.EndConnect($iar); $c.Close(); return $true
    } catch { return $false }
}

function Invoke-MySql([string]$Client,[string]$User,[string]$Password,[string]$Sql) {
    $previous = $env:MYSQL_PWD
    try {
        if ([string]::IsNullOrEmpty($Password)) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } else { $env:MYSQL_PWD = $Password }
        $result = $Sql | & $Client --protocol=TCP --host=127.0.0.1 --port=$ManagedMySqlPort --user=$User --batch --skip-column-names 2>&1
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) { throw ($result -join [Environment]::NewLine) }
        return $result
    } finally {
        if ($null -eq $previous) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } else { $env:MYSQL_PWD = $previous }
    }
}

function Test-MySqlLogin([string]$Client,[string]$User,[string]$Password,[string]$Database='') {
    try {
        $sql = if ($Database) { "USE $Database; SELECT 1;" } else { 'SELECT 1;' }
        Invoke-MySql $Client $User $Password $sql | Out-Null
        return $true
    } catch { return $false }
}

function Ensure-ManagedMySql {
    $bins = Install-ManagedMySqlFiles
    Write-MySqlIni $bins.BaseDir

    $state = $null
    if (Test-Path $mysqlState -PathType Leaf) {
        try { $state = Get-Content $mysqlState -Raw | ConvertFrom-Json } catch {}
    }
    if (-not $state) {
        $state = [pscustomobject]@{
            RootPassword = New-Secret 40
            TestDatabase = 'imonitor_erp_test'
            TestUser = 'imonitor_test'
            TestPassword = New-Secret 36
            ProductionDatabase = 'imonitor_erp_production'
            ProductionUser = 'imonitor_production'
            ProductionPassword = New-Secret 36
            Port = $ManagedMySqlPort
            Version = $mysqlVersion
        }
        $state | ConvertTo-Json | Set-Content $mysqlState -Encoding UTF8
        & icacls.exe $configRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' /Q | Out-Null
        $global:LASTEXITCODE = 0
    }

    $dataInitialized = Test-Path (Join-Path $mysqlDataRoot 'mysql') -PathType Container
    if (-not $dataInitialized) {
        Write-Host 'Initializing managed MySQL data directory...'
        & $bins.MySqlD "--defaults-file=$mysqlIni" --initialize-insecure --console
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) { throw "mysqld --initialize-insecure failed with exit code $code" }
    }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "Installing Windows service $serviceName..."
        & $bins.MySqlD "--defaults-file=$mysqlIni" --install $serviceName
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) { throw "MySQL service installation failed with exit code $code" }
        $service = Get-Service -Name $serviceName
    }
    Set-Service -Name $serviceName -StartupType Automatic
    if ($service.Status -ne 'Running') { Start-Service -Name $serviceName }

    for ($i=1; $i -le 30; $i++) {
        if (Test-TcpPort $ManagedMySqlPort) { break }
        Start-Sleep 1
    }
    if (-not (Test-TcpPort $ManagedMySqlPort)) { throw "Managed MySQL did not listen on 127.0.0.1:$ManagedMySqlPort" }

    if (-not (Test-MySqlLogin $bins.MySql 'root' ([string]$state.RootPassword))) {
        if (Test-MySqlLogin $bins.MySql 'root' '') {
            $rootEsc = ([string]$state.RootPassword).Replace("'","''")
            Invoke-MySql $bins.MySql 'root' '' "ALTER USER 'root'@'localhost' IDENTIFIED BY '$rootEsc'; FLUSH PRIVILEGES;" | Out-Null
        }
    }
    if (-not (Test-MySqlLogin $bins.MySql 'root' ([string]$state.RootPassword))) { throw 'Managed MySQL root login verification failed.' }

    return [pscustomobject]@{ Binaries=$bins; State=$state }
}

function Ensure-DatabaseUser([object]$Managed,[string]$Database,[string]$User,[string]$Password) {
    if ($Database -notmatch '^[A-Za-z0-9_]+$' -or $User -notmatch '^[A-Za-z0-9_]+$') { throw 'Unsupported MySQL database/user name.' }
    $p = $Password.Replace("'","''")
    $sql = @"
CREATE DATABASE IF NOT EXISTS $Database CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$User'@'localhost' IDENTIFIED BY '$p';
CREATE USER IF NOT EXISTS '$User'@'127.0.0.1' IDENTIFIED BY '$p';
ALTER USER '$User'@'localhost' IDENTIFIED BY '$p';
ALTER USER '$User'@'127.0.0.1' IDENTIFIED BY '$p';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'localhost';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
    Invoke-MySql $Managed.Binaries.MySql 'root' ([string]$Managed.State.RootPassword) $sql | Out-Null
    if (-not (Test-MySqlLogin $Managed.Binaries.MySql $User $Password $Database)) { throw "MySQL login verification failed for $User/$Database" }
    Write-Host "[OK] MySQL ready: $User -> $Database" -ForegroundColor Green
}

function Ensure-JsonObject([object]$Parent,[string]$Name) {
    $p = $Parent.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) {
        $v = [pscustomobject]@{}
        if ($p) { $p.Value=$v } else { $Parent | Add-Member NoteProperty $Name $v }
        return $v
    }
    return $p.Value
}
function Set-JsonValue([object]$Parent,[string]$Name,[object]$Value) {
    $p = $Parent.PSObject.Properties[$Name]
    if ($p) { $p.Value=$Value } else { $Parent | Add-Member NoteProperty $Name $Value }
}

function Get-BaseSettings([string]$Name,[string]$Destination) {
    $current = Join-Path (Join-Path $InstallRoot $Name.ToLowerInvariant()) 'current\appsettings.json'
    $legacy = Join-Path 'C:\ProgramData\iMonitorERP' ($Name.ToLowerInvariant() + '\current\appsettings.json')
    if (Test-Path $current -PathType Leaf) { Copy-Item $current $Destination -Force; return }
    if (Test-Path $legacy -PathType Leaf) { Copy-Item $legacy $Destination -Force; return }
    $branch = if ($Name -eq 'Production') { 'master' } else { 'test' }
    $uri = "https://raw.githubusercontent.com/alimirzae/Ecomm/$branch/Ecomm/appsettings.json?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Invoke-CurlDownload $uri $Destination "$Name base appsettings" 300
}

function Prepare-ChannelSettings([string]$Name,[string]$Database,[string]$User,[string]$Password) {
    $base = Join-Path $InstallRoot $Name.ToLowerInvariant()
    $current = Join-Path $base 'current'
    New-Item -ItemType Directory -Force -Path $current | Out-Null
    $settingsPath = Join-Path $current 'appsettings.json'
    $temp = Join-Path $env:TEMP ("imonitor-$($Name.ToLowerInvariant())-appsettings-"+[guid]::NewGuid().ToString('N')+'.json')
    try {
        Get-BaseSettings $Name $temp
        $settings = Get-Content $temp -Raw | ConvertFrom-Json
        $databaseSettings = Ensure-JsonObject $settings 'Database'
        Set-JsonValue $databaseSettings 'Type' 'MySql'
        Set-JsonValue $databaseSettings 'AutoMigrate' $true
        Set-JsonValue $databaseSettings 'MigrateOnStartup' $true
        Set-JsonValue $databaseSettings 'EnsureCreatedIfNotExists' $true
        Set-JsonValue $databaseSettings 'SeedDataOnMigrate' $true
        Set-JsonValue $databaseSettings 'DropDatabaseOnStartup' $false
        $mysql = Ensure-JsonObject $databaseSettings 'MySql'
        $cs = "Server=127.0.0.1;Port=$ManagedMySqlPort;Database=$Database;User=$User;Password=$Password;CharSet=utf8mb4;AllowUserVariables=True;"
        Set-JsonValue $mysql 'Server' '127.0.0.1'
        Set-JsonValue $mysql 'Port' $ManagedMySqlPort
        Set-JsonValue $mysql 'UserId' $User
        Set-JsonValue $mysql 'Password' $Password
        Set-JsonValue $mysql 'ConnectionString' $cs
        Set-JsonValue $mysql 'Version' '8.4.0'
        $connections = Ensure-JsonObject $settings 'ConnectionStrings'
        Set-JsonValue $connections 'MySql' $cs
        $environment = Ensure-JsonObject $settings 'Environment'
        Set-JsonValue $environment 'Name' $Name
        Set-JsonValue $environment 'IsDevelopment' $false
        Set-JsonValue $environment 'IsProduction' ($Name -eq 'Production')
        Set-JsonValue $settings 'AllowedHosts' '*'
        $settings | ConvertTo-Json -Depth 100 | Set-Content $settingsPath -Encoding UTF8
        Write-Host "[OK] Prepared $Name database configuration." -ForegroundColor Green
    } finally { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
}

$managed = Ensure-ManagedMySql
$state = $managed.State
if ($Channel -in @('Both','Test')) {
    Ensure-DatabaseUser $managed ([string]$state.TestDatabase) ([string]$state.TestUser) ([string]$state.TestPassword)
    Prepare-ChannelSettings 'Test' ([string]$state.TestDatabase) ([string]$state.TestUser) ([string]$state.TestPassword)
}
if ($Channel -in @('Both','Production')) {
    Ensure-DatabaseUser $managed ([string]$state.ProductionDatabase) ([string]$state.ProductionUser) ([string]$state.ProductionPassword)
    Prepare-ChannelSettings 'Production' ([string]$state.ProductionDatabase) ([string]$state.ProductionUser) ([string]$state.ProductionPassword)
}

$core13 = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.13-core.ps1'
$uri13 = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.13-core.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
try {
    Invoke-CurlDownload $uri13 $core13 'Installer activation core v2.0.13' 300
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$core13,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
    if ($Force) { $args += '-Force' }
    $p = Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "Activation core returned exit code $($p.ExitCode)" }
} finally { Remove-Item $core13 -Force -ErrorAction SilentlyContinue }

Write-Host '[OK] Application package activated and startup migrations completed.' -ForegroundColor Green
if (-not $UpdateOnly) {
    if ($Channel -in @('Both','Test')) { Write-Host "First-run wizard: http://127.0.0.1:${TestPort}/account/setup" -ForegroundColor Cyan }
    if ($Channel -in @('Both','Production')) { Write-Host "Production: http://127.0.0.1:${ProductionPort}/account/setup" -ForegroundColor Cyan }
}
