# Installer v2.0.1. Verified package cache defaults to the caller's current directory.
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
$assetName = 'iMonitor-EcomERP-win-x64.zip'
$runtime = Join-Path $InstallRoot 'dotnet'
$state = Join-Path $InstallRoot 'state'
$configRoot = Join-Path $InstallRoot 'config'
$installerHome = Join-Path $InstallRoot 'installer'
$credentialFile = Join-Path $configRoot 'mysql-credentials.json'
New-Item -ItemType Directory -Force -Path $InstallRoot,$runtime,$state,$configRoot,$installerHome | Out-Null

function New-Secret { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_}) }
if (Test-Path $credentialFile) {
    $credentials = Get-Content $credentialFile -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($TestPassword)) { $TestPassword = $credentials.TestPassword }
    if ([string]::IsNullOrWhiteSpace($ProductionPassword)) { $ProductionPassword = $credentials.ProductionPassword }
} else {
    if ([string]::IsNullOrWhiteSpace($TestPassword)) { $TestPassword = New-Secret }
    if ([string]::IsNullOrWhiteSpace($ProductionPassword)) { $ProductionPassword = New-Secret }
}
@{
    Server=$MySqlServer; Port=$MySqlPort
    TestDatabase=$TestDatabase; TestUser=$TestUser; TestPassword=$TestPassword
    ProductionDatabase=$ProductionDatabase; ProductionUser=$ProductionUser; ProductionPassword=$ProductionPassword
} | ConvertTo-Json | Set-Content $credentialFile -Encoding UTF8
& icacls $configRoot /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$hasRuntime = $dotnet -and (@(& $dotnet.Source --list-runtimes) -match '^Microsoft.AspNetCore.App 8\.')
if (-not $hasRuntime) {
    $runtimeInstaller = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing https://dot.net/v1/dotnet-install.ps1 -OutFile $runtimeInstaller
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeInstaller -Channel 8.0 -Runtime aspnetcore -InstallDir $runtime -NoPath
    if ($LASTEXITCODE -ne 0) { throw 'ASP.NET Core Runtime 8 installation failed.' }
    $dotnetExe = Join-Path $runtime 'dotnet.exe'
} else { $dotnetExe = $dotnet.Source }

function Ensure-IIS {
    if (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-ManagementConsole,IIS-StaticContent,IIS-DefaultDocument,IIS-HttpErrors,IIS-HttpLogging,IIS-RequestFiltering -All -NoRestart | Out-Null
    } elseif (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        Install-WindowsFeature Web-Server,Web-Mgmt-Console -IncludeManagementTools | Out-Null
    } else {
        throw 'This Windows edition does not expose IIS installation cmdlets.'
    }
    Import-Module WebAdministration -ErrorAction Stop

    $ancm = Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue
    if (-not $ancm) {
        $hostingInstaller = Join-Path $env:TEMP 'dotnet-hosting-8.exe'
        Invoke-WebRequest -UseBasicParsing 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe' -OutFile $hostingInstaller
        $process = Start-Process -FilePath $hostingInstaller -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010,1641)) { throw "ASP.NET Core Hosting Bundle installation failed (exit $($process.ExitCode))." }
        Import-Module WebAdministration -Force
        if (-not (Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue)) {
            throw 'ASP.NET Core Module V2 was not registered in IIS. Restart Windows, then rerun the installer.'
        }
    }
    Set-Service W3SVC -StartupType Automatic
    Start-Service W3SVC
}
Ensure-IIS

function Find-MySqlClient {
    $command = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($root in @($env:ProgramFiles)) {
        $candidate = Get-ChildItem (Join-Path $root 'MySQL') -Filter mysql.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}
function Invoke-MySql([string]$Client,[string]$Login,[string]$Password,[string]$Sql) {
    $previous = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $Password
        $result = $Sql | & $Client --protocol=TCP --host=$MySqlServer --port=$MySqlPort --user=$Login --batch --skip-column-names 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($result -join [Environment]::NewLine) }
        return $result
    } finally {
        if ($null -eq $previous) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } else { $env:MYSQL_PWD = $previous }
    }
}
function Test-MySqlLogin([string]$Client,[string]$Database,[string]$User,[string]$Password) {
    try { Invoke-MySql $Client $User $Password "USE $Database; SELECT 1;" | Out-Null; return $true } catch { return $false }
}
function Assert-MySqlName([string]$Value,[string]$Label) {
    if ($Value -notmatch '^[A-Za-z0-9_]+$') { throw "$Label contains unsupported characters: $Value" }
}
function Ensure-MySqlChannel([string]$Client,[string]$Database,[string]$User,[string]$Password) {
    Assert-MySqlName $Database 'Database name'
    Assert-MySqlName $User 'MySQL user'
    if (Test-MySqlLogin $Client $Database $User $Password) { Write-Host "MySQL login verified: $User -> $Database"; return }
    if ($SkipMySqlProvisioning -or $UpdateOnly) { throw "MySQL login failed for $User/$Database. Run once without -UpdateOnly and provide administrator credentials." }
    if ([string]::IsNullOrWhiteSpace($script:MySqlAdminPassword)) {
        $secure = Read-Host "MySQL administrator password for $MySqlAdminUser" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:MySqlAdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    $escapedPassword = $Password.Replace("'", "''")
    $sql = @"
CREATE DATABASE IF NOT EXISTS $Database CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$User'@'localhost' IDENTIFIED BY '$escapedPassword';
CREATE USER IF NOT EXISTS '$User'@'127.0.0.1' IDENTIFIED BY '$escapedPassword';
ALTER USER '$User'@'localhost' IDENTIFIED BY '$escapedPassword';
ALTER USER '$User'@'127.0.0.1' IDENTIFIED BY '$escapedPassword';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'localhost';
GRANT ALL PRIVILEGES ON $Database.* TO '$User'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
    Invoke-MySql $Client $MySqlAdminUser $script:MySqlAdminPassword $sql | Out-Null
    if (-not (Test-MySqlLogin $Client $Database $User $Password)) { throw "MySQL provisioning completed but login verification failed for $User/$Database." }
    Write-Host "MySQL database/user/grants provisioned and verified: $User -> $Database"
}
$mysqlClient = Find-MySqlClient
if (-not $mysqlClient) { throw 'mysql.exe was not found. Install MySQL Server/Client 8 and rerun the installer.' }
if ($Channel -in @('Both','Test')) { Ensure-MySqlChannel $mysqlClient $TestDatabase $TestUser $TestPassword }
if ($Channel -in @('Both','Production')) { Ensure-MySqlChannel $mysqlClient $ProductionDatabase $ProductionUser $ProductionPassword }

function Ensure-JsonObject([object]$Parent,[string]$Name) {
    $property = $Parent.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) {
        $value = [pscustomobject]@{}
        if ($property) { $property.Value = $value } else { $Parent | Add-Member -MemberType NoteProperty -Name $Name -Value $value }
        return $value
    }
    return $property.Value
}
function Set-JsonValue([object]$Parent,[string]$Name,[object]$Value) {
    $property = $Parent.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value } else { $Parent | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}
function Merge-AppSettings([string]$Path,[string]$Name,[string]$Database,[string]$User,[string]$Password) {
    if (Test-Path $Path) { $settings = Get-Content $Path -Raw | ConvertFrom-Json } else { $settings = [pscustomobject]@{} }
    $databaseSettings = Ensure-JsonObject $settings 'Database'
    Set-JsonValue $databaseSettings 'Type' 'MySql'
    Set-JsonValue $databaseSettings 'MigrateOnStartup' $true
    Set-JsonValue $databaseSettings 'AutoMigrate' $true
    $mysql = Ensure-JsonObject $databaseSettings 'MySql'
    $connectionString = "Server=$MySqlServer;Port=$MySqlPort;Database=$Database;User=$User;Password=$Password;CharSet=utf8mb4;"
    Set-JsonValue $mysql 'Server' $MySqlServer
    Set-JsonValue $mysql 'Port' $MySqlPort
    Set-JsonValue $mysql 'UserId' $User
    Set-JsonValue $mysql 'Password' $Password
    Set-JsonValue $mysql 'ConnectionString' $connectionString
    $connections = Ensure-JsonObject $settings 'ConnectionStrings'
    Set-JsonValue $connections 'MySql' $connectionString
    $environment = Ensure-JsonObject $settings 'Environment'
    Set-JsonValue $environment 'Name' $Name
    Set-JsonValue $environment 'IsDevelopment' $false
    Set-JsonValue $environment 'IsProduction' ($Name -eq 'Production')
    Set-JsonValue $settings 'AllowedHosts' '*'
    $settings | ConvertTo-Json -Depth 100 | Set-Content $Path -Encoding UTF8
}

function Invoke-Download([string]$Uri,[string]$OutFile,[string]$Label) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $client = $null
        $response = $null
        $inputStream = $null
        $outputStream = $null
        try {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Host "$Label (attempt $attempt/5)..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

            $handler = New-Object System.Net.Http.HttpClientHandler
            $handler.AllowAutoRedirect = $true
            $handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromMinutes(15)
            $client.DefaultRequestHeaders.UserAgent.ParseAdd('iMonitorERP-Installer/2.0')

            $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode()
            $expectedBytes = $response.Content.Headers.ContentLength
            if ($expectedBytes) { Write-Host ("Downloading {0:N1} MB via HTTP stream..." -f ($expectedBytes / 1MB)) }

            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = New-Object System.IO.FileStream($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
            $inputStream.CopyTo($outputStream, 1048576)
            $outputStream.Flush()
            $downloadedBytes = (Get-Item $OutFile).Length

            if ($downloadedBytes -eq 0) { throw 'Downloaded file is empty.' }
            if ($expectedBytes -and $downloadedBytes -ne $expectedBytes) {
                throw "Incomplete download: received $downloadedBytes of $expectedBytes bytes."
            }
            Write-Host ("$Label completed: {0:N1} MB" -f ($downloadedBytes / 1MB))
            return
        } catch {
            $lastError = $_.Exception.GetBaseException().Message
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 5) {
                Write-Warning "$Label failed: $lastError. Retrying..."
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 8))
            }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }
    throw "$Label failed after 5 attempts. URL: $Uri. Last error: $lastError"
}

$releases = Invoke-RestMethod -Headers @{Accept='application/vnd.github+json'} -Uri "https://api.github.com/repos/$repo/releases?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

function Install-Channel([string]$Name,[int]$Port,[string]$Database,[string]$User,[string]$Password) {
    $gitChannel = if ($Name -eq 'Production') { 'master' } else { 'test' }
    $prefix = "imonitor-ecomerp-$gitChannel-v"
    $matches = $releases | Where-Object {
        -not $_.draft -and $_.tag_name.StartsWith($prefix) -and ($gitChannel -eq 'test' -or -not $_.prerelease)
    } | Sort-Object @{Expression={ if ($_.published_at) { [datetime]$_.published_at } else { [datetime]$_.created_at } }; Descending=$true}
    $release = $matches | Select-Object -First 1
    if (-not $release) { throw "No release found for $Name ($prefix)." }

    $base = Join-Path $InstallRoot $Name.ToLowerInvariant()
    $current = Join-Path $base 'current'
    $versions = Join-Path $base 'releases'
    $versionFile = Join-Path $state "$gitChannel-version"
    $siteName = "iMonitorERP-$Name"
    $poolName = "iMonitorERP-$Name"
    if (Test-Path "IIS:\AppPools\$poolName") {
        $poolState = (Get-WebAppPoolState -Name $poolName).Value
        if ($poolState -ne 'Stopped') { Stop-WebAppPool -Name $poolName }
    }
    New-Item -ItemType Directory -Force -Path $base,$versions | Out-Null
    $installed = if (Test-Path $versionFile) {(Get-Content $versionFile -Raw).Trim()} else {''}
    if ($UpdateOnly -and -not (Test-Path (Join-Path $current 'Ecomm.dll'))) { throw "$Name is not installed. Run once without -UpdateOnly." }

    if ($Force -or $installed -ne $release.tag_name) {
        $asset = $release.assets | Where-Object name -eq $assetName | Select-Object -First 1
        $sumAsset = $release.assets | Where-Object name -eq "$assetName.sha256" | Select-Object -First 1
        if (-not $asset -or -not $sumAsset) { throw "Assets are incomplete in $($release.tag_name)." }
        $work = Join-Path $env:TEMP ("imonitor-" + [guid]::NewGuid().ToString('N'))
        $releaseCache = Join-Path $PackageCacheDirectory $release.tag_name
        New-Item -ItemType Directory -Force -Path $work,$releaseCache | Out-Null
        try {
            $sum = Join-Path $releaseCache "$assetName.sha256"
            Invoke-Download $sumAsset.browser_download_url $sum "$Name checksum download"
            $expected = ((Get-Content $sum -Raw) -split '\s+')[0].ToLowerInvariant()

            $versionedPackage = Join-Path $releaseCache $assetName
            $manualPackage = Join-Path $PackageCacheDirectory $assetName
            $zip = $null
            foreach ($candidate in @($versionedPackage,$manualPackage)) {
                if (-not (Test-Path $candidate -PathType Leaf)) { continue }
                Write-Host "Checking cached package: $candidate"
                $candidateHash = (Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($candidateHash -eq $expected) {
                    $zip = $candidate
                    Write-Host "Using verified cached package; download skipped: $candidate"
                    break
                }
                Write-Warning "Cached package does not match $($release.tag_name) and will not be used: $candidate"
            }

            if (-not $zip) {
                $partialPackage = "$versionedPackage.partial"
                Invoke-Download $asset.browser_download_url $partialPackage "$Name package download"
                $actual = (Get-FileHash $partialPackage -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $expected) {
                    Remove-Item $partialPackage -Force -ErrorAction SilentlyContinue
                    throw 'SHA-256 verification failed for the downloaded package.'
                }
                Move-Item $partialPackage $versionedPackage -Force
                $zip = $versionedPackage
                Write-Host "Verified package cached at: $versionedPackage"
            }

            $target = Join-Path $versions $release.tag_name
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            Expand-Archive $zip $target -Force
            if (-not (Test-Path (Join-Path $target 'Ecomm.dll'))) { throw 'Ecomm.dll is missing.' }
            if (Test-Path $current) { Remove-Item $current -Recurse -Force }
            Copy-Item $target $current -Recurse
            Set-Content $versionFile $release.tag_name -Encoding ASCII
        } finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Merge-AppSettings (Join-Path $current 'appsettings.json') $Name $Database $User $Password

    # Remove the legacy Windows service. IIS is now the only process manager.
    $legacyService = Get-Service -Name "iMonitorERP-$Name" -ErrorAction SilentlyContinue
    if ($legacyService) {
        if ($legacyService.Status -ne 'Stopped') { Stop-Service -Name $legacyService.Name -Force -ErrorAction SilentlyContinue }
        & sc.exe delete $legacyService.Name | Out-Null
    }

    if (-not (Test-Path (Join-Path $current 'web.config'))) {
        $webConfig = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
      </handlers>
      <aspNetCore processPath="dotnet" arguments=".\Ecomm.dll" stdoutLogEnabled="true" stdoutLogFile=".\logs\stdout" hostingModel="inprocess" />
    </system.webServer>
  </location>
</configuration>
'@
        Set-Content (Join-Path $current 'web.config') $webConfig -Encoding UTF8
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $current 'logs') | Out-Null

    if (Test-Path "IIS:\Sites\$siteName") { Remove-Website -Name $siteName }
    if (-not (Test-Path "IIS:\AppPools\$poolName")) { New-WebAppPool -Name $poolName | Out-Null }

    $poolAclRead = "IIS AppPool\" + $poolName + ":(OI)(CI)RX"
    $poolAclModify = "IIS AppPool\" + $poolName + ":(OI)(CI)M"
    & icacls $current /grant:r $poolAclRead /T /C | Out-Null
    & icacls (Join-Path $current 'logs') /grant:r $poolAclModify /T /C | Out-Null
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedPipelineMode -Value Integrated
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name processModel.identityType -Value ApplicationPoolIdentity
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name startMode -Value AlwaysRunning
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)

    $binding = "*:" + $Port + ":"
    $conflict = Get-WebBinding -Protocol http | Where-Object {
        $_.bindingInformation -eq $binding -and $_.ItemXPath -notlike "*site[@name='$siteName']*"
    }
    if ($conflict) {
        $owners = ($conflict | ForEach-Object { $_.ItemXPath }) -join ', '
        throw "Port $Port already has an IIS binding: $owners"
    }

    New-Website -Name $siteName -PhysicalPath $current -Port $Port -IPAddress '*' -ApplicationPool $poolName | Out-Null
    Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationDefaults.preloadEnabled -Value $true
    if ((Get-WebAppPoolState -Name $poolName).Value -ne 'Started') { Start-WebAppPool -Name $poolName }
    if ((Get-WebsiteState -Name $siteName).Value -ne 'Started') { Start-Website -Name $siteName }

    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        $firewallName = "iMonitor ERP $Name TCP $Port"
        if (-not (Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
        }
    }

    $url = "http://127.0.0.1:$Port/"
    $healthy = $false
    $lastError = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 5
            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 500) {
                $healthy = $true
                break
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) {
        $poolState = (Get-WebAppPoolState -Name $poolName).Value
        $siteState = (Get-WebsiteState -Name $siteName).Value
        throw "$Name IIS health check failed at $url (site=$siteState, pool=$poolState). Last error: $lastError. Check $current\logs."
    }

    Write-Host "$Name installed and verified in IIS Manager: $($release.tag_name), $url"
}

$channelErrors = [System.Collections.Generic.List[string]]::new()
if ($Channel -in @('Both','Test')) {
    try { Install-Channel Test $TestPort $TestDatabase $TestUser $TestPassword }
    catch { $channelErrors.Add("Test: $($_.Exception.Message)"); Write-Error "Test installation failed: $($_.Exception.Message)" -ErrorAction Continue }
}
if ($Channel -in @('Both','Production')) {
    try { Install-Channel Production $ProductionPort $ProductionDatabase $ProductionUser $ProductionPassword }
    catch { $channelErrors.Add("Production: $($_.Exception.Message)"); Write-Error "Production installation failed: $($_.Exception.Message)" -ErrorAction Continue }
}
if ($channelErrors.Count -gt 0) { throw ("One or more channels failed:" + [Environment]::NewLine + " - " + ($channelErrors -join ([Environment]::NewLine + " - "))) }

$self = Join-Path $installerHome 'Install-iMonitorERP.ps1'
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.1.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $self
$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC DAILY /ST 02:30 /RU SYSTEM /TR $prodAction | Out-Null

Write-Host ''
Write-Host "MySQL settings: $credentialFile (Administrators and SYSTEM only)"
Write-Host "Test: http://localhost:$TestPort"
Write-Host "Production: http://localhost:$ProductionPort"
