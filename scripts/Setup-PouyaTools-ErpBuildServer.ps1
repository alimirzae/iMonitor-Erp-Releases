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
$ProgressPreference = 'SilentlyContinue'
function Step([string]$m){ Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Green }
function Ensure-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ throw 'Run this script from PowerShell as Administrator.' }
}
function Refresh-Path { $env:PATH=[Environment]::GetEnvironmentVariable('PATH','Machine')+';'+[Environment]::GetEnvironmentVariable('PATH','User') }
function Download-File([string]$Url,[string]$OutFile){
    Step "Downloading $Url"
    $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
    if($curl){
        & $curl.Source -L --fail --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 900 --progress-bar -o $OutFile $Url
        if($LASTEXITCODE -ne 0){ throw "Download failed with curl exit code $LASTEXITCODE : $Url" }
    }else{
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile -TimeoutSec 900
    }
    if(-not(Test-Path $OutFile)){ throw "Download did not create $OutFile" }
}
function Ensure-Git {
    if(Get-Command git.exe -ErrorAction SilentlyContinue){ Ok "Git already installed: $(& git --version)"; return }
    Step 'Git is missing. Installing Git for Windows directly from the official GitHub release...'
    $release=Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{'User-Agent'='iMonitor-ERP-Setup'}
    $asset=$release.assets | Where-Object {$_.name -match '^Git-[0-9].*-64-bit\.exe$' -and $_.name -notmatch 'Portable'} | Select-Object -First 1
    if(-not $asset){ throw 'Could not locate the latest 64-bit Git for Windows installer.' }
    $installer=Join-Path $env:TEMP $asset.name
    Download-File $asset.browser_download_url $installer
    Step "Installing $($asset.name)..."
    $p=Start-Process -FilePath $installer -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-','/CLOSEAPPLICATIONS' -Wait -PassThru
    if($p.ExitCode -ne 0){ throw "Git installer failed with exit code $($p.ExitCode)" }
    Refresh-Path
    if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){
        $gitPath='C:\Program Files\Git\cmd'
        if(Test-Path (Join-Path $gitPath 'git.exe')){$env:PATH="$gitPath;$env:PATH"}
    }
    if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){ throw 'Git installation completed but git.exe is still unavailable.' }
    Ok "Git installed: $(& git --version)"
}
function Ensure-Gh {
    if(Get-Command gh.exe -ErrorAction SilentlyContinue){ Ok "GitHub CLI already installed: $(& gh --version | Select-Object -First 1)"; return }
    Step 'GitHub CLI is missing. Installing it directly from the official GitHub release...'
    $release=Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers @{'User-Agent'='iMonitor-ERP-Setup'}
    $asset=$release.assets | Where-Object {$_.name -match '^gh_.*_windows_amd64\.msi$'} | Select-Object -First 1
    if(-not $asset){ throw 'Could not locate the latest GitHub CLI Windows amd64 MSI.' }
    $installer=Join-Path $env:TEMP $asset.name
    Download-File $asset.browser_download_url $installer
    Step "Installing $($asset.name)..."
    $p=Start-Process msiexec.exe -ArgumentList '/i',"`"$installer`"",'/qn','/norestart' -Wait -PassThru
    if($p.ExitCode -notin 0,3010){ throw "GitHub CLI installer failed with exit code $($p.ExitCode)" }
    Refresh-Path
    if(-not(Get-Command gh.exe -ErrorAction SilentlyContinue)){
        $ghPath='C:\Program Files\GitHub CLI'
        if(Test-Path (Join-Path $ghPath 'gh.exe')){$env:PATH="$ghPath;$env:PATH"}
    }
    if(-not(Get-Command gh.exe -ErrorAction SilentlyContinue)){ throw 'GitHub CLI installation completed but gh.exe is still unavailable.' }
    Ok "GitHub CLI installed: $(& gh --version | Select-Object -First 1)"
}
function Ensure-DotNet8 {
    $hasSdk=$false
    if(Get-Command dotnet.exe -ErrorAction SilentlyContinue){
        $sdks=& dotnet --list-sdks
        $hasSdk=[bool]($sdks -match '^8\.')
    }
    if(-not $hasSdk){
        Step '.NET SDK 8 is missing. Installing it with the official dotnet-install script...'
        $installScript=Join-Path $env:TEMP 'dotnet-install.ps1'
        Download-File 'https://dot.net/v1/dotnet-install.ps1' $installScript
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -Channel 8.0 -InstallDir 'C:\Program Files\dotnet'
        if($LASTEXITCODE -ne 0){ throw "dotnet-install failed with exit code $LASTEXITCODE" }
        [Environment]::SetEnvironmentVariable('DOTNET_ROOT','C:\Program Files\dotnet','Machine')
        $machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
        if($machinePath -notlike '*C:\Program Files\dotnet*'){
            [Environment]::SetEnvironmentVariable('PATH',"C:\Program Files\dotnet;$machinePath",'Machine')
        }
        Refresh-Path
    }
    if(-not(Get-Command dotnet.exe -ErrorAction SilentlyContinue)){ throw 'dotnet.exe is unavailable after SDK installation.' }
    Ok ".NET SDKs installed:`n$(& dotnet --list-sdks | Out-String)"

    Step 'Ensuring ASP.NET Core Hosting Bundle 8 / IIS ANCM...'
    $ancm = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
    if(-not(Test-Path $ancm)){
        $hosting=Join-Path $env:TEMP 'dotnet-hosting-8.exe'
        Download-File 'https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe' $hosting
        $p=Start-Process -FilePath $hosting -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
        if($p.ExitCode -notin 0,3010,1641){ throw "ASP.NET Core Hosting Bundle installer failed with exit code $($p.ExitCode)" }
    }
    if(Test-Path $ancm){ Ok 'ASP.NET Core Module V2 is installed.' } else { Write-Warning 'Hosting Bundle installation completed, but ANCM file was not detected yet. A reboot may be required.' }
}

Ensure-Admin
if(-not(Test-Path $DriveRoot)){ throw "Drive/root does not exist: $DriveRoot" }

Step 'Enabling IIS and management features...'
$features=@('IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures','IIS-StaticContent','IIS-DefaultDocument','IIS-HttpErrors','IIS-ApplicationDevelopment','IIS-ISAPIExtensions','IIS-ISAPIFilter','IIS-ManagementConsole','IIS-RequestFiltering','IIS-WebSockets','IIS-HttpLogging')
foreach($f in $features){
    $state=(& dism.exe /Online /Get-FeatureInfo /FeatureName:$f 2>$null | Select-String 'State :').ToString()
    if($state -match 'Enabled') { Ok "IIS feature already enabled: $f"; continue }
    Step "Enabling IIS feature: $f"
    & dism.exe /Online /Enable-Feature /FeatureName:$f /All /NoRestart
    if($LASTEXITCODE -notin 0,3010){ throw "Failed to enable Windows feature $f (exit $LASTEXITCODE)" }
    Ok "Enabled: $f"
}

Ensure-Git
Ensure-Gh
Ensure-DotNet8

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
function Ensure-Site([string]$Name,[string]$Pool,[string]$Path,[int]$Port,[string]$HostName){
    Ensure-AppPool $Pool
    if(Get-Website -Name $Name -ErrorAction SilentlyContinue){ Remove-Website -Name $Name }
    New-Website -Name $Name -PhysicalPath $Path -Port $Port -HostHeader $HostName -ApplicationPool $Pool | Out-Null
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
    Download-File $asset.browser_download_url $zip
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
