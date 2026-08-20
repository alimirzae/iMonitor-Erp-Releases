param(
    [string]$Repo = 'alimirzae/Ecomm',
    [string]$RunnerName = 'PouyaTools_Server',
    [string]$DriveRoot = 'D:\',
    [string]$ProdHost = 'erp.pouyatools.ir',
    [string]$TestHost = 'testerp.pouyatools.ir',
    [int]$ProdPort = 80,
    [int]$TestPort = 8080
)

$ErrorActionPreference = 'Stop'
function Step([string]$m){ Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Ensure-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ throw 'Run this script from PowerShell as Administrator.' }
}
function Refresh-Path { $env:PATH=[Environment]::GetEnvironmentVariable('PATH','Machine')+';'+[Environment]::GetEnvironmentVariable('PATH','User') }
function Ensure-Command([string]$Name,[string]$WingetId){
    if(Get-Command $Name -ErrorAction SilentlyContinue){ return }
    if(-not(Get-Command winget.exe -ErrorAction SilentlyContinue)){ throw "$Name is missing and winget is unavailable. Install $WingetId first." }
    Step "Installing $WingetId ..."
    winget install --id $WingetId --exact --silent --accept-package-agreements --accept-source-agreements
    if($LASTEXITCODE -ne 0){ throw "winget install failed for $WingetId" }
    Refresh-Path
}

Ensure-Admin
if(-not(Test-Path $DriveRoot)){ throw "Drive/root does not exist: $DriveRoot" }

Step 'Enabling IIS and management features...'
$features=@('IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-StaticContent','IIS-DefaultDocument','IIS-HttpErrors','IIS-ApplicationDevelopment','IIS-ISAPIExtensions','IIS-ISAPIFilter','IIS-ManagementConsole','IIS-RequestFiltering','IIS-WebSockets','IIS-HttpLogging')
foreach($f in $features){
    & dism.exe /Online /Enable-Feature /FeatureName:$f /All /NoRestart | Out-Null
    if($LASTEXITCODE -notin 0,3010){ throw "Failed to enable Windows feature $f" }
}

Ensure-Command 'git.exe' 'Git.Git'
Ensure-Command 'gh.exe' 'GitHub.cli'
Ensure-Command 'dotnet.exe' 'Microsoft.DotNet.SDK.8'

$sdks=& dotnet --list-sdks
if(-not($sdks -match '^8\.')){
    Step 'Installing .NET SDK 8...'
    winget install --id Microsoft.DotNet.SDK.8 --exact --silent --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

Step 'Ensuring ASP.NET Core Hosting Bundle 8...'
$ancm = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
if(-not(Test-Path $ancm)){
    winget install --id Microsoft.DotNet.HostingBundle.8 --exact --silent --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

$runnerRoot=Join-Path $DriveRoot 'EcommRunner'
$prodRoot=Join-Path $DriveRoot 'Sites\Ecomm-Production'
$testRoot=Join-Path $DriveRoot 'Sites\Ecomm-Test'
$backupRoot=Join-Path $DriveRoot 'Sites\Backups'
$configProd=Join-Path $DriveRoot 'Sites\Config\Production'
$configTest=Join-Path $DriveRoot 'Sites\Config\Test'
foreach($p in @($runnerRoot,$prodRoot,$testRoot,$backupRoot,$configProd,$configTest)){ New-Item -ItemType Directory -Force $p | Out-Null }

Import-Module WebAdministration
function Ensure-AppPool([string]$Name){
    if(-not(Test-Path "IIS:\AppPools\$Name")){ New-WebAppPool -Name $Name | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$Name" -Name enable32BitAppOnWin64 -Value $false
    Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.loadUserProfile -Value $true
    Set-ItemProperty "IIS:\AppPools\$Name" -Name startMode -Value 'AlwaysRunning'
}
function Ensure-Site([string]$Name,[string]$Pool,[string]$Path,[int]$Port,[string]$Host){
    Ensure-AppPool $Pool
    if(Get-Website -Name $Name -ErrorAction SilentlyContinue){ Remove-Website -Name $Name }
    New-Website -Name $Name -PhysicalPath $Path -Port $Port -HostHeader $Host -ApplicationPool $Pool | Out-Null
    Set-ItemProperty "IIS:\Sites\$Name" -Name applicationDefaults.preloadEnabled -Value $true -ErrorAction SilentlyContinue
    $identity="IIS AppPool\$Pool"
    & icacls $Path /grant "${identity}:(OI)(CI)(RX)" /T /C | Out-Null
    foreach($rel in @('logs','data','App_Data','temp','uploads','wwwroot\uploads')){
        $wp=Join-Path $Path $rel; New-Item -ItemType Directory -Force $wp | Out-Null
        & icacls $wp /grant "${identity}:(OI)(CI)(M)" /T /C | Out-Null
    }
}

Step 'Configuring IIS sites...'
Ensure-Site 'Ecomm-Production' 'Ecomm-Production-Pool' $prodRoot $ProdPort $ProdHost
Ensure-Site 'Ecomm-Test' 'Ecomm-Test-Pool' $testRoot $TestPort $TestHost

Step 'Creating firewall rules...'
foreach($rule in @(@{Name='iMonitor ERP Production HTTP';Port=$ProdPort},@{Name='iMonitor ERP Test HTTP 8080';Port=$TestPort})){
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Port -Profile Domain,Private | Out-Null
}

Step 'Authenticating GitHub CLI...'
& gh auth status -h github.com
if($LASTEXITCODE -ne 0){
    & gh auth login -h github.com -p https -w
    if($LASTEXITCODE -ne 0){ throw 'GitHub CLI authentication failed.' }
}

Step 'Installing GitHub Actions runner...'
$runnerDir=Join-Path $runnerRoot 'actions-runner'
New-Item -ItemType Directory -Force $runnerDir | Out-Null
if(-not(Test-Path (Join-Path $runnerDir 'config.cmd'))){
    $release=& gh api repos/actions/runner/releases/latest | ConvertFrom-Json
    $asset=$release.assets | Where-Object { $_.name -match '^actions-runner-win-x64-.*\.zip$' } | Select-Object -First 1
    if(-not $asset){ throw 'Could not locate latest Windows x64 GitHub Actions runner package.' }
    $zip=Join-Path $runnerRoot $asset.name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive $zip -DestinationPath $runnerDir -Force
}

Push-Location $runnerDir
try{
    if(Test-Path '.runner'){
        try { & .\svc.cmd stop | Out-Null } catch {}
        try { & .\svc.cmd uninstall | Out-Null } catch {}
        try {
            $removeToken=& gh api -X POST "repos/$Repo/actions/runners/remove-token" --jq .token
            & .\config.cmd remove --unattended --token $removeToken | Out-Null
        } catch {}
    }
    $token=& gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq .token
    if(-not $token){ throw 'Could not obtain GitHub runner registration token.' }
    & .\config.cmd --unattended --url "https://github.com/$Repo" --token $token --name $RunnerName --work '_work' --labels 'pouyatools-server,erp-build,dotnet-build,iis-deploy' --replace
    if($LASTEXITCODE -ne 0){ throw 'GitHub runner configuration failed.' }
    & .\svc.cmd install
    if($LASTEXITCODE -ne 0){ throw 'Runner service install failed.' }
    & .\svc.cmd start
    if($LASTEXITCODE -ne 0){ throw 'Runner service start failed.' }
} finally { Pop-Location }

powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null

iisreset | Out-Null

Write-Host ''
Write-Host '=== PouyaTools ERP Build Server ready ===' -ForegroundColor Green
Write-Host "Runner          : $RunnerName"
Write-Host "Production      : http://$ProdHost`:$ProdPort/"
Write-Host "Test            : http://$TestHost`:$TestPort/"
Write-Host "Production path : $prodRoot"
Write-Host "Test path       : $testRoot"
Write-Host "Prod config     : $configProd\appsettings.Production.json"
Write-Host "Test config     : $configTest\appsettings.Test.json"
Write-Host 'Runner labels   : self-hosted, Windows, X64, pouyatools-server, erp-build, dotnet-build, iis-deploy'
Write-Host ''
Write-Host 'LAN DNS must point erp.pouyatools.ir and testerp.pouyatools.ir to this server IP.' -ForegroundColor Yellow
