[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP',
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
    $iisFeature = Get-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -ErrorAction SilentlyContinue
    if ($iisFeature -and $iisFeature.State -ne 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-ManagementConsole,IIS-StaticContent,IIS-DefaultDocument,IIS-HttpErrors,IIS-HttpLogging,IIS-RequestFiltering -All -NoRestart | Out-Null
    } elseif (-not $iisFeature -and (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        Install-WindowsFeature Web-Server,Web-Mgmt-Console -IncludeManagementTools | Out-Null
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
        Stop-WebAppPool -Name $poolName -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $base,$versions | Out-Null
    $installed = if (Test-Path $versionFile) {(Get-Content $versionFile -Raw).Trim()} else {''}

    if ($Force -or $installed -ne $release.tag_name) {
        $asset = $release.assets | Where-Object name -eq $assetName | Select-Object -First 1
        $sumAsset = $release.assets | Where-Object name -eq "$assetName.sha256" | Select-Object -First 1
        if (-not $asset -or -not $sumAsset) { throw "Assets are incomplete in $($release.tag_name)." }
        $work = Join-Path $env:TEMP ("imonitor-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            $zip = Join-Path $work $assetName; $sum = "$zip.sha256"
            Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $zip
            Invoke-WebRequest -UseBasicParsing $sumAsset.browser_download_url -OutFile $sum
            $expected = ((Get-Content $sum -Raw) -split '\s+')[0].ToLowerInvariant()
            $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $expected) { throw 'SHA-256 verification failed.' }
            $target = Join-Path $versions $release.tag_name
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            Expand-Archive $zip $target -Force
            if (-not (Test-Path (Join-Path $target 'Ecomm.dll'))) { throw 'Ecomm.dll is missing.' }
            if (Test-Path $current) { Remove-Item $current -Recurse -Force }
            Copy-Item $target $current -Recurse
            Set-Content $versionFile $release.tag_name -Encoding ASCII
        } finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $config = @{
      Database=@{Type='MySql';MigrateOnStartup=$true;MySql=@{
        Server=$MySqlServer;Port=$MySqlPort;UserId=$User;Password=$Password;
        ConnectionString="Server=$MySqlServer;Port=$MySqlPort;Database=$Database;User=$User;Password=$Password;CharSet=utf8mb4;"
      }}
      ConnectionStrings=@{MySql="Server=$MySqlServer;Port=$MySqlPort;Database=$Database;User=$User;Password=$Password;CharSet=utf8mb4;"}
      Environment=@{Name=$Name;IsDevelopment=$false;IsProduction=($Name -eq 'Production')}
      AllowedHosts='*'
    } | ConvertTo-Json -Depth 8
    Set-Content (Join-Path $current 'appsettings.json') $config -Encoding UTF8

    # Remove the legacy Windows service. IIS is now the only process manager.
    $legacyService = "iMonitorERP-$Name"
    & sc.exe stop $legacyService 2>$null | Out-Null
    & sc.exe delete $legacyService 2>$null | Out-Null

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
    $poolAclRead = "IIS AppPool\" + $poolName + ":(OI)(CI)RX"
    $poolAclModify = "IIS AppPool\" + $poolName + ":(OI)(CI)M"
    & icacls $current /grant:r $poolAclRead /T /C | Out-Null
    & icacls (Join-Path $current 'logs') /grant:r $poolAclModify /T /C | Out-Null

    if (Test-Path "IIS:\Sites\$siteName") { Remove-Website -Name $siteName }
    if (-not (Test-Path "IIS:\AppPools\$poolName")) { New-WebAppPool -Name $poolName | Out-Null }
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
    Start-WebAppPool -Name $poolName
    Start-Website -Name $siteName

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

if ($Channel -in @('Both','Test')) { Install-Channel Test $TestPort $TestDatabase $TestUser $TestPassword }
if ($Channel -in @('Both','Production')) { Install-Channel Production $ProductionPort $ProductionDatabase $ProductionUser $ProductionPassword }

$self = Join-Path $installerHome 'Install-iMonitorERP.ps1'
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.0.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $self
$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC DAILY /ST 02:30 /RU SYSTEM /TR $prodAction | Out-Null

Write-Host ''
Write-Host "MySQL settings: $credentialFile (Administrators and SYSTEM only)"
Write-Host "Test: http://localhost:$TestPort"
Write-Host "Production: http://localhost:$ProductionPort"
