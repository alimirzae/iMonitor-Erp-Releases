[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP-Docker',
    [int]$TestPort = 8080,
    [int]$ProductionPort = 8081,
    [int]$PhpMyAdminPort = 8082,
    [switch]$UpdateOnly,
    [switch]$Force,
    [switch]$SkipDockerInstall
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-Administrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Administrator)) { throw 'PowerShell must be run as Administrator.' }

$repo = 'alimirzae/iMonitor-Erp-Releases'
$api = "https://api.github.com/repos/$repo/releases"
$assetName = 'iMonitor-EcomERP-linux-x64.tar.gz'
$credentialsFile = Join-Path $InstallRoot 'credentials.env'
$composeFile = Join-Path $InstallRoot 'docker-compose.yml'
$stateRoot = Join-Path $InstallRoot 'state'
$configRoot = Join-Path $InstallRoot 'config'
$releaseRoot = Join-Path $InstallRoot 'releases'
$installerRoot = Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $InstallRoot,$stateRoot,$configRoot,$releaseRoot,$installerRoot | Out-Null

function New-Secret {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]','').Substring(0,32)
}

function Enable-DockerPrerequisites {
    $restartNeeded = $false
    $features = @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
    foreach ($feature in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($state -ne 'Enabled') {
            Write-Host "Enabling Windows feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
            $restartNeeded = $true
        }
    }
    try { & wsl.exe --set-default-version 2 | Out-Null } catch {}
    return $restartNeeded
}

function Install-DockerDesktop {
    if (Get-Command docker.exe -ErrorAction SilentlyContinue) { return $false }
    if ($SkipDockerInstall) { throw 'Docker is not installed and -SkipDockerInstall was specified.' }

    $restartNeeded = Enable-DockerPrerequisites
    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    Write-Host 'Downloading Docker Desktop...'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile $installer
    Write-Host 'Installing Docker Desktop with WSL2 backend...'
    $process = Start-Process -FilePath $installer -ArgumentList @(
        'install','--quiet','--accept-license','--backend=wsl-2','--always-run-service'
    ) -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) { throw "Docker Desktop installation failed: $($process.ExitCode)" }
    if ($process.ExitCode -eq 3010) { $restartNeeded = $true }
    return $restartNeeded
}

function Wait-Docker {
    $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    try { Start-Service com.docker.service -ErrorAction SilentlyContinue } catch {}
    if (Test-Path $dockerDesktop) {
        $running = Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue
        if (-not $running) { Start-Process $dockerDesktop | Out-Null }
    }
    for ($i=0; $i -lt 90; $i++) {
        try {
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) {
                & docker compose version *> $null
                if ($LASTEXITCODE -eq 0) { return }
            }
        } catch {}
        Start-Sleep -Seconds 5
    }
    throw 'Docker Desktop did not become ready. Start Docker Desktop once, accept its initial setup, then rerun this installer.'
}

$restartNeeded = Install-DockerDesktop
if ($restartNeeded) {
    Write-Warning 'Windows features or Docker require a restart.'
    Write-Host 'Restart Windows, start Docker Desktop once, then run this same command again.'
    exit 3010
}
Wait-Docker

if (-not (Test-Path $credentialsFile)) {
    @(
        "MYSQL_ROOT_PASSWORD=$(New-Secret)"
        'MYSQL_TEST_DATABASE=imonitor_erp_test'
        'MYSQL_TEST_USER=imonitor_test'
        "MYSQL_TEST_PASSWORD=$(New-Secret)"
        'MYSQL_PROD_DATABASE=imonitor_erp_production'
        'MYSQL_PROD_USER=imonitor_production'
        "MYSQL_PROD_PASSWORD=$(New-Secret)"
        "TEST_PORT=$TestPort"
        "PROD_PORT=$ProductionPort"
        "PHPMYADMIN_PORT=$PhpMyAdminPort"
        'PHPMYADMIN_BIND=127.0.0.1'
    ) | Set-Content $credentialsFile -Encoding ASCII
}
& icacls $InstallRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null

$envValues = @{}
Get-Content $credentialsFile | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $envValues[$matches[1]] = $matches[2] }
}
$TestPort = [int]$envValues.TEST_PORT
$ProductionPort = [int]$envValues.PROD_PORT
$PhpMyAdminPort = [int]$envValues.PHPMYADMIN_PORT

$releases = Invoke-RestMethod -Headers @{Accept='application/vnd.github+json'} -Uri "$api?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

function Install-Release([string]$GitChannel) {
    $prefix = "imonitor-ecomerp-$GitChannel-v"
    $matches = $releases | Where-Object {
        -not $_.draft -and $_.tag_name.StartsWith($prefix) -and
        ($GitChannel -eq 'test' -or -not $_.prerelease)
    } | Sort-Object @{Expression={if ($_.published_at){[datetime]$_.published_at}else{[datetime]$_.created_at}};Descending=$true}
    $release = $matches | Select-Object -First 1
    if (-not $release) { throw "No release found for $GitChannel." }

    $versionFile = Join-Path $stateRoot "$GitChannel-version"
    $installed = if (Test-Path $versionFile) {(Get-Content $versionFile -Raw).Trim()}else{''}
    if (-not $Force -and $installed -eq $release.tag_name) {
        Write-Host "$GitChannel is current: $installed"
        return
    }

    $asset = $release.assets | Where-Object name -eq $assetName | Select-Object -First 1
    $sumAsset = $release.assets | Where-Object name -eq "$assetName.sha256" | Select-Object -First 1
    if (-not $asset -or -not $sumAsset) { throw "Linux Docker asset/checksum missing in $($release.tag_name)." }

    $work = Join-Path $env:TEMP ("imonitor-docker-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $archive = Join-Path $work $assetName
        $sum = "$archive.sha256"
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $archive
        Invoke-WebRequest -UseBasicParsing $sumAsset.browser_download_url -OutFile $sum
        $expected = ((Get-Content $sum -Raw) -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw 'SHA-256 verification failed.' }

        $channelRoot = Join-Path $releaseRoot $GitChannel
        $target = Join-Path $channelRoot $release.tag_name
        $current = Join-Path $InstallRoot "$GitChannel-current"
        $previous = Join-Path $InstallRoot "$GitChannel-previous"
        New-Item -ItemType Directory -Force -Path $channelRoot | Out-Null
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        & tar.exe -xzf $archive -C $target
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $target 'Ecomm.dll'))) { throw 'Release extraction failed.' }
        if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
        if (Test-Path $current) { Move-Item $current $previous }
        Copy-Item $target $current -Recurse
        Set-Content $versionFile $release.tag_name -Encoding ASCII
    } finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($Channel -in @('Both','Test')) { Install-Release 'test' }
if ($Channel -in @('Both','Production')) { Install-Release 'master' }

$testPassword = $envValues.MYSQL_TEST_PASSWORD
$prodPassword = $envValues.MYSQL_PROD_PASSWORD
$testUser = $envValues.MYSQL_TEST_USER
$prodUser = $envValues.MYSQL_PROD_USER
$testDb = $envValues.MYSQL_TEST_DATABASE
$prodDb = $envValues.MYSQL_PROD_DATABASE
$mysqlInit = Join-Path $InstallRoot 'mysql-init'
New-Item -ItemType Directory -Force -Path $mysqlInit | Out-Null
@"
CREATE DATABASE IF NOT EXISTS $testDb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS $prodDb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$testUser'@'%' IDENTIFIED BY '$testPassword';
CREATE USER IF NOT EXISTS '$prodUser'@'%' IDENTIFIED BY '$prodPassword';
ALTER USER '$testUser'@'%' IDENTIFIED BY '$testPassword';
ALTER USER '$prodUser'@'%' IDENTIFIED BY '$prodPassword';
GRANT ALL PRIVILEGES ON $testDb.* TO '$testUser'@'%';
GRANT ALL PRIVILEGES ON $prodDb.* TO '$prodUser'@'%';
FLUSH PRIVILEGES;
"@ | Set-Content (Join-Path $mysqlInit '01-databases.sql') -Encoding UTF8
@{
    Database=@{Type='MySql';MigrateOnStartup=$true;MySql=@{Server='mysql';Port=3306;UserId=$testUser;Password=$testPassword;ConnectionString="Server=mysql;Port=3306;Database=$testDb;User=$testUser;Password=$testPassword;CharSet=utf8mb4;"}}
    ConnectionStrings=@{MySql="Server=mysql;Port=3306;Database=$testDb;User=$testUser;Password=$testPassword;CharSet=utf8mb4;"}
    Environment=@{Name='Test';IsDevelopment=$false;IsProduction=$false};AllowedHosts='*'
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $configRoot 'test.json') -Encoding UTF8
@{
    Database=@{Type='MySql';MigrateOnStartup=$true;MySql=@{Server='mysql';Port=3306;UserId=$prodUser;Password=$prodPassword;ConnectionString="Server=mysql;Port=3306;Database=$prodDb;User=$prodUser;Password=$prodPassword;CharSet=utf8mb4;"}}
    ConnectionStrings=@{MySql="Server=mysql;Port=3306;Database=$prodDb;User=$prodUser;Password=$prodPassword;CharSet=utf8mb4;"}
    Environment=@{Name='Production';IsDevelopment=$false;IsProduction=$true};AllowedHosts='*'
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $configRoot 'production.json') -Encoding UTF8

$compose = @'
services:
  mysql:
    image: mysql:8.4
    container_name: imonitor-erp-mysql
    restart: unless-stopped
    env_file: [./credentials.env]
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    command: ["--character-set-server=utf8mb4","--collation-server=utf8mb4_unicode_ci"]
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d:ro
    networks: [imonitor]
    healthcheck:
      test: ["CMD-SHELL","mysqladmin ping -h localhost -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
  phpmyadmin:
    image: phpmyadmin:5
    container_name: imonitor-erp-phpmyadmin
    restart: unless-stopped
    depends_on:
      mysql: {condition: service_healthy}
    environment: {PMA_HOST: mysql, PMA_PORT: 3306, UPLOAD_LIMIT: 256M}
    ports: ["${PHPMYADMIN_BIND:-127.0.0.1}:${PHPMYADMIN_PORT}:80"]
    networks: [imonitor]
  erp-test:
    image: mcr.microsoft.com/dotnet/aspnet:8.0
    container_name: imonitor-erp-test
    restart: unless-stopped
    depends_on:
      mysql: {condition: service_healthy}
    working_dir: /app
    command: ["dotnet","Ecomm.dll","--urls","http://0.0.0.0:8080"]
    environment: {ASPNETCORE_ENVIRONMENT: Test}
    volumes:
      - ./test-current:/app:ro
      - ./config/test.json:/app/appsettings.json:ro
      - dataprotection-test:/root/.aspnet/DataProtection-Keys
      - diagnostics-test:/app/App_Data/Diagnostics
    ports: ["${TEST_PORT}:8080"]
    networks: [imonitor]
  erp-production:
    image: mcr.microsoft.com/dotnet/aspnet:8.0
    container_name: imonitor-erp-production
    restart: unless-stopped
    depends_on:
      mysql: {condition: service_healthy}
    working_dir: /app
    command: ["dotnet","Ecomm.dll","--urls","http://0.0.0.0:8080"]
    environment: {ASPNETCORE_ENVIRONMENT: Production}
    volumes:
      - ./master-current:/app:ro
      - ./config/production.json:/app/appsettings.json:ro
      - dataprotection-production:/root/.aspnet/DataProtection-Keys
      - diagnostics-production:/app/App_Data/Diagnostics
    ports: ["${PROD_PORT}:8080"]
    networks: [imonitor]
networks: {imonitor: {}}
volumes:
  mysql-data: {}
  dataprotection-test: {}
  dataprotection-production: {}
  diagnostics-test: {}
  diagnostics-production: {}
'@
Set-Content $composeFile $compose -Encoding UTF8

Push-Location $InstallRoot
try {
    & docker compose --env-file $credentialsFile up -d --force-recreate
    if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed.' }
} catch {
    foreach ($gitChannel in @('test','master')) {
        $current = Join-Path $InstallRoot "$gitChannel-current"
        $previous = Join-Path $InstallRoot "$gitChannel-previous"
        if (Test-Path $previous) {
            if (Test-Path $current) { Remove-Item $current -Recurse -Force }
            Move-Item $previous $current
        }
    }
    & docker compose --env-file $credentialsFile up -d --force-recreate
    throw
} finally { Pop-Location }

$self = Join-Path $installerRoot 'Install-iMonitorERP-Docker.ps1'
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-Docker-v2.0.0.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $self
$testTask = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly -SkipDockerInstall"
$prodTask = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly -SkipDockerInstall"
& schtasks.exe /Create /F /TN 'iMonitorERP-Docker-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR $testTask | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Docker-Update-Production' /SC DAILY /ST 02:30 /RU SYSTEM /RL HIGHEST /TR $prodTask | Out-Null

Write-Host ''
Write-Host 'iMonitor ERP Docker installation completed.'
Write-Host "Test:       http://localhost:$TestPort"
Write-Host "Production: http://localhost:$ProductionPort"
Write-Host "phpMyAdmin: http://127.0.0.1:$PhpMyAdminPort"
Write-Host "MySQL credentials: $credentialsFile"
Write-Host "Show root password: (Get-Content '$credentialsFile' | Select-String '^MYSQL_ROOT_PASSWORD=')"
