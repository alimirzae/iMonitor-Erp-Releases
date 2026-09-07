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
$mysqlState = Join-Path $configRoot 'mysql-external.json'
$script:LastMySqlError = ''
New-Item -ItemType Directory -Force -Path $InstallRoot,$PackageCacheDirectory,$configRoot | Out-Null

Write-Host 'iMonitor ERP installer core v2.0.15' -ForegroundColor Cyan
Write-Host "Install root : $InstallRoot"
Write-Host "Package cache: $PackageCacheDirectory"
Write-Host "Channel      : $Channel"
Write-Host 'MySQL mode   : Existing installation (no MySQL download)' -ForegroundColor Cyan

function New-Secret([int]$Length = 32) {
    $chars = (48..57) + (65..90) + (97..122)
    -join (1..$Length | ForEach-Object { [char]($chars | Get-Random) })
}

function Read-Secret([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Invoke-CurlDownload([string]$Uri,[string]$OutFile,[string]$Label,[int]$MaxTime = 1800) {
    $curl = Get-Command curl.exe -ErrorAction Stop
    $last = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Host "$Label (attempt $attempt/4)..."
            & $curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time $MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.15' $Uri -o $OutFile
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

function Resolve-MySqlClient([string]$Hint) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Hint) {
        if (Test-Path $Hint -PathType Leaf) { $candidates.Add((Resolve-Path $Hint).Path) }
        elseif (Test-Path $Hint -PathType Container) {
            $direct = Join-Path $Hint 'mysql.exe'
            if (Test-Path $direct -PathType Leaf) { $candidates.Add($direct) }
            Get-ChildItem $Hint -Filter mysql.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $candidates.Add($_.FullName) }
        }
    }
    $cmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }
    @(
        "$env:ProgramFiles\MySQL\MySQL Server 8.4\bin\mysql.exe",
        "$env:ProgramFiles\MySQL\MySQL Server 8.0\bin\mysql.exe",
        "${env:ProgramFiles(x86)}\MySQL\MySQL Server 8.0\bin\mysql.exe"
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | ForEach-Object { $candidates.Add($_) }
    $candidates | Select-Object -Unique | Select-Object -First 1
}

function Invoke-MySql([string]$Client,[string]$HostName,[int]$Port,[string]$User,[string]$Password,[string]$Sql) {
    $previous = $env:MYSQL_PWD
    try {
        if ([string]::IsNullOrEmpty($Password)) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } else { $env:MYSQL_PWD = $Password }

        $mysqlArgs = New-Object System.Collections.Generic.List[string]
        $mysqlArgs.Add("--user=$User")
        $mysqlArgs.Add('--batch')
        $mysqlArgs.Add('--skip-column-names')
        $mysqlArgs.Add('--default-character-set=utf8mb4')

        $isDefaultLocal = (($HostName -eq 'localhost') -and ($Port -eq 3306))
        if (-not $isDefaultLocal) {
            $mysqlArgs.Add('--protocol=TCP')
            $mysqlArgs.Add("--host=$HostName")
            $mysqlArgs.Add("--port=$Port")
        }

        $result = $Sql | & $Client $mysqlArgs.ToArray() 2>&1
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) { throw ($result -join [Environment]::NewLine) }
        return $result
    } finally {
        if ($null -eq $previous) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } else { $env:MYSQL_PWD = $previous }
    }
}

function Test-MySqlLogin([string]$Client,[string]$HostName,[int]$Port,[string]$User,[string]$Password,[string]$Database='') {
    try {
        $sql = if ($Database) { "USE $Database; SELECT 1;" } else { 'SELECT 1;' }
        Invoke-MySql $Client $HostName $Port $User $Password $sql | Out-Null
        $script:LastMySqlError = ''
        return $true
    } catch {
        $script:LastMySqlError = $_.Exception.Message
        return $false
    }
}

function Protect-ConfigDirectory {
    & icacls.exe $configRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' /Q | Out-Null
    $global:LASTEXITCODE = 0
}

function Get-MySqlConnectionInfo {
    $state = $null
    if (Test-Path $mysqlState -PathType Leaf) {
        try { $state = Get-Content $mysqlState -Raw | ConvertFrom-Json } catch {}
    }

    $clientHint = $MySqlBinPath
    if (-not $clientHint -and $state -and $state.ClientPath) { $clientHint = [string]$state.ClientPath }
    $client = Resolve-MySqlClient $clientHint
    if (-not $client -and -not $UpdateOnly) {
        $inputPath = Read-Host 'Path to mysql.exe or MySQL bin directory'
        $client = Resolve-MySqlClient $inputPath
    }
    if (-not $client) { throw 'mysql.exe was not found. Provide -MySqlBinPath or rerun interactively and enter the MySQL bin directory.' }
    Write-Host "MySQL client : $client"

    $hostName = $MySqlHost
    if (-not $hostName -and $state -and $state.Host) { $hostName = [string]$state.Host }
    if (-not $hostName -and -not $UpdateOnly) { $hostName = Read-Host 'MySQL host/address [localhost]' }
    if (-not $hostName) { $hostName = 'localhost' }

    $portValue = $MySqlPort
    if ($portValue -le 0 -and $state -and $state.Port) { $portValue = [int]$state.Port }
    if ($portValue -le 0 -and -not $UpdateOnly) {
        $portText = Read-Host 'MySQL port [3306]'
        if ($portText) { $portValue = [int]$portText }
    }
    if ($portValue -le 0) { $portValue = 3306 }

    $rootUser = $MySqlRootUser
    if (-not $rootUser -and $state -and $state.RootUser) { $rootUser = [string]$state.RootUser }
    if (-not $rootUser -and -not $UpdateOnly) { $rootUser = Read-Host 'MySQL administrative user [root]' }
    if (-not $rootUser) { $rootUser = 'root' }

    $rootPassword = $MySqlRootPassword
    if (-not $rootPassword -and $state -and $state.RootPassword) { $rootPassword = [string]$state.RootPassword }
    if (-not $rootPassword -and -not $UpdateOnly) { $rootPassword = Read-Secret "Password for MySQL user '$rootUser'" }
    if ($null -eq $rootPassword) { $rootPassword = '' }

    $connected = Test-MySqlLogin $client $hostName $portValue $rootUser $rootPassword
    if (-not $connected -and $hostName -eq '127.0.0.1' -and $portValue -eq 3306) {
        Write-Host '127.0.0.1 login failed; retrying with localhost to match the local MySQL client behavior...' -ForegroundColor Yellow
        if (Test-MySqlLogin $client 'localhost' 3306 $rootUser $rootPassword) {
            $hostName = 'localhost'
            $connected = $true
        }
    }
    if (-not $connected) {
        $detail = if ($script:LastMySqlError) { " MySQL says: $($script:LastMySqlError)" } else { '' }
        throw "Cannot connect to MySQL at $hostName`:$portValue as '$rootUser'.$detail"
    }

    $testPassword = if ($state -and $state.TestPassword) { [string]$state.TestPassword } else { New-Secret 36 }
    $productionPassword = if ($state -and $state.ProductionPassword) { [string]$state.ProductionPassword } else { New-Secret 36 }

    $newState = [ordered]@{
        ClientPath = $client
        Host = $hostName
        Port = $portValue
        RootUser = $rootUser
        RootPassword = $rootPassword
        TestDatabase = 'imonitor_erp_test'
        TestUser = 'imonitor_test'
        TestPassword = $testPassword
        ProductionDatabase = 'imonitor_erp_production'
        ProductionUser = 'imonitor_production'
        ProductionPassword = $productionPassword
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $newState | ConvertTo-Json | Set-Content $mysqlState -Encoding UTF8
    Protect-ConfigDirectory

    [pscustomobject]@{
        Client=$client; Host=$hostName; Port=$portValue; RootUser=$rootUser; RootPassword=$rootPassword;
        TestDatabase='imonitor_erp_test'; TestUser='imonitor_test'; TestPassword=$testPassword;
        ProductionDatabase='imonitor_erp_production'; ProductionUser='imonitor_production'; ProductionPassword=$productionPassword
    }
}

function Ensure-DatabaseUser([object]$Conn,[string]$Database,[string]$User,[string]$Password) {
    if ($Database -notmatch '^[A-Za-z0-9_]+$' -or $User -notmatch '^[A-Za-z0-9_]+$') { throw 'Unsupported MySQL database/user name.' }
    $p = $Password.Replace("'","''")
    $sql = @"
CREATE DATABASE IF NOT EXISTS $Database CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$User'@'localhost' IDENTIFIED BY '$p';
CREATE USER IF NOT EXISTS '$User'@'127.0.0.1' IDENTIFIED BY '$p';
CREATE USER IF NOT EXISTS '$User'@'%' IDENTIFIED BY '$p';
ALTER USER '$User'@'localhost' IDENTIFIED BY '$p';
ALTER USER '$User'@'127.0.0.1' IDENTIFIED BY '$p';
ALTER USER '$User'@'%' IDENTIFIED BY '$p';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'localhost';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'127.0.0.1';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'%';
FLUSH PRIVILEGES;
"@
    Invoke-MySql $Conn.Client $Conn.Host $Conn.Port $Conn.RootUser $Conn.RootPassword $sql | Out-Null
    if (-not (Test-MySqlLogin $Conn.Client $Conn.Host $Conn.Port $User $Password $Database)) {
        throw "MySQL login verification failed for $User/$Database. $($script:LastMySqlError)"
    }
    Write-Host "[OK] MySQL ready: $User -> $Database" -ForegroundColor Green
}

function Ensure-IisAndDotNet {
    if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        $features = 'IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-StaticContent','IIS-DefaultDocument','IIS-HttpErrors','IIS-ApplicationDevelopment','IIS-ISAPIExtensions','IIS-ISAPIFilter','IIS-NetFxExtensibility45','IIS-ASPNET45','IIS-ManagementConsole'
        foreach ($feature in $features) {
            try {
                $f = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
                if ($f.State -ne 'Enabled') { Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null }
            } catch {}
        }
    }
    $runtimeReady = $false
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($dotnet) { try { $runtimeReady = [bool]((& $dotnet.Source --list-runtimes 2>$null) -match '^Microsoft\.AspNetCore\.App 8\.') } catch {} }
    if (-not $runtimeReady) {
        $hosting = Join-Path $env:TEMP 'dotnet-hosting-8.exe'
        Invoke-CurlDownload 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe' $hosting '.NET 8 Hosting Bundle' 1800
        $p = Start-Process $hosting -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
        if ($p.ExitCode -notin @(0,1641,3010)) { throw ".NET hosting bundle failed with exit code $($p.ExitCode)" }
        Remove-Item $hosting -Force -ErrorAction SilentlyContinue
    }
    Import-Module WebAdministration -ErrorAction Stop
    Write-Host '[OK] IIS and .NET 8 ready.' -ForegroundColor Green
}

function Ensure-JsonObject([object]$Parent,[string]$Name) {
    $p = $Parent.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) {
        $v = [pscustomobject]@{}
        if ($p) { $p.Value = $v } else { $Parent | Add-Member NoteProperty $Name $v }
        return $v
    }
    return $p.Value
}
function Set-JsonValue([object]$Parent,[string]$Name,[object]$Value) {
    $p = $Parent.PSObject.Properties[$Name]
    if ($p) { $p.Value = $Value } else { $Parent | Add-Member NoteProperty $Name $Value }
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

function Write-ChannelSettings([string]$Name,[string]$Destination,[string]$Database,[string]$User,[string]$Password,[object]$Conn) {
    $temp = Join-Path $env:TEMP ("imonitor-$($Name.ToLowerInvariant())-appsettings-" + [guid]::NewGuid().ToString('N') + '.json')
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
        $cs = "Server=$($Conn.Host);Port=$($Conn.Port);Database=$Database;User=$User;Password=$Password;CharSet=utf8mb4;SslMode=None;AllowPublicKeyRetrieval=True;"
        Set-JsonValue $mysql 'ConnectionString' $cs
        $connections = Ensure-JsonObject $settings 'ConnectionStrings'
        Set-JsonValue $connections 'DefaultConnection' $cs
        $settings | ConvertTo-Json -Depth 30 | Set-Content $Destination -Encoding UTF8
    } finally { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
}

function Get-LatestRelease([string]$Prefix) {
    $tmp = Join-Path $env:TEMP ('imonitor-releases-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-CurlDownload "https://api.github.com/repos/$repo/releases?per_page=100" $tmp 'Release metadata download over GitHub IPv4' 300
        $r = Get-Content $tmp -Raw | ConvertFrom-Json | Where-Object { $_.tag_name -like "$Prefix*" } | Select-Object -First 1
        if (-not $r) { throw "No release found for $Prefix" }
        return $r
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-AssetUrl($Release,[string]$Name) {
    ($Release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1).browser_download_url
}

function Ensure-Package($Release) {
    $dir = Join-Path $PackageCacheDirectory $Release.tag_name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir 'iMonitor-EcomERP-win-x64.zip'
    if (Test-Path $zip -PathType Leaf -and (Get-Item $zip).Length -gt 5MB) {
        Write-Host "Using cached package: $zip" -ForegroundColor Green
        return $zip
    }
    $url = Get-AssetUrl $Release 'iMonitor-EcomERP-win-x64.zip'
    if (-not $url) { throw 'Windows release ZIP not found.' }
    Invoke-CurlDownload $url $zip 'Windows package' 3600
    return $zip
}

function Set-IisSite([string]$Name,[string]$Pool,[string]$Path,[int]$Port) {
    Import-Module WebAdministration
    if (-not (Test-Path "IIS:\AppPools\$Pool")) { New-WebAppPool -Name $Pool | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$Pool" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$Pool" -Name processModel.identityType -Value ApplicationPoolIdentity
    if (Test-Path "IIS:\Sites\$Name") { Set-ItemProperty "IIS:\Sites\$Name" -Name physicalPath -Value $Path }
    else { New-Website -Name $Name -Port $Port -PhysicalPath $Path -ApplicationPool $Pool | Out-Null }
    Set-ItemProperty "IIS:\Sites\$Name" -Name applicationPool -Value $Pool
    $acl = Get-Acl $Path
    $rule = New-Object Security.AccessControl.FileSystemAccessRule("IIS AppPool\$Pool",'Modify','ContainerInherit,ObjectInherit','None','Allow')
    $acl.SetAccessRule($rule); Set-Acl $Path $acl
    try { if ((Get-WebAppPoolState $Pool).Value -ne 'Started') { Start-WebAppPool $Pool } } catch {}
    try { if ((Get-WebsiteState $Name).Value -ne 'Started') { Start-Website $Name } } catch {}
}

function Test-Health([int]$Port) {
    try { $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 10; return $r.StatusCode -eq 200 } catch { return $false }
}

function Deploy-Channel([string]$Name,[string]$Prefix,[int]$Port,[string]$Database,[string]$User,[string]$Password,[object]$Conn) {
    Ensure-DatabaseUser $Conn $Database $User $Password
    $release = Get-LatestRelease $Prefix
    $zip = Ensure-Package $release
    $base = Join-Path $InstallRoot $Name.ToLowerInvariant()
    $current = Join-Path $base 'current'
    $staging = Join-Path $base ('staging-' + [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $base 'backup'
    New-Item -ItemType Directory -Force -Path $base,$staging | Out-Null
    Expand-Archive $zip $staging -Force

    $stagingSettings = Join-Path $staging 'appsettings.json'
    Write-ChannelSettings $Name $stagingSettings $Database $User $Password $Conn

    $newData = Join-Path $current 'App_Data'
    $legacyData = Join-Path 'C:\ProgramData\iMonitorERP' ($Name.ToLowerInvariant() + '\current\App_Data')
    if (Test-Path $newData -PathType Container) { Copy-Item $newData (Join-Path $staging 'App_Data') -Recurse -Force }
    elseif (Test-Path $legacyData -PathType Container) { Copy-Item $legacyData (Join-Path $staging 'App_Data') -Recurse -Force }

    $site = "iMonitorERP-$Name"
    $pool = $site
    try {
        try { if ((Test-Path "IIS:\Sites\$site") -and (Get-WebsiteState $site).Value -eq 'Started') { Stop-Website $site } } catch {}
        try { if ((Test-Path "IIS:\AppPools\$pool") -and (Get-WebAppPoolState $pool).Value -eq 'Started') { Stop-WebAppPool $pool } } catch {}
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $current) { Move-Item $current $backup -Force }
        Move-Item $staging $current -Force
        Set-IisSite $site $pool $current $Port
        for ($i=1; $i -le 60; $i++) {
            if (Test-Health $Port) {
                Write-Host "[OK] $Name online on port $Port ($($release.tag_name))." -ForegroundColor Green
                return
            }
            Start-Sleep 2
        }
        throw "$Name health check failed after activation."
    } catch {
        Write-Warning "$Name activation failed: $($_.Exception.Message)"
        try {
            if (Test-Path $current) { Remove-Item $current -Recurse -Force }
            if (Test-Path $backup) { Move-Item $backup $current -Force; Set-IisSite $site $pool $current $Port }
        } catch {}
        throw
    } finally { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}

Ensure-IisAndDotNet
$conn = Get-MySqlConnectionInfo
Write-Host "[OK] Connected to existing MySQL: $($conn.Host):$($conn.Port)" -ForegroundColor Green

if ($Channel -in @('Both','Test')) {
    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' $TestPort $conn.TestDatabase $conn.TestUser $conn.TestPassword $conn
}
if ($Channel -in @('Both','Production')) {
    Deploy-Channel 'Production' 'imonitor-ecomerp-production-v' $ProductionPort $conn.ProductionDatabase $conn.ProductionUser $conn.ProductionPassword $conn
}

Write-Host '[OK] Installation completed.' -ForegroundColor Green
