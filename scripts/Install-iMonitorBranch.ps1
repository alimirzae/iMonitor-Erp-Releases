[CmdletBinding()]
param(
    [switch]$InstallProduction,
    [switch]$InstallPreview,
    [string]$Root = 'C:\iMonitor-Local',
    [string]$ProductionConfig,
    [string]$PreviewConfig,
    [switch]$SkipAutoUpdate
)

$ErrorActionPreference='Stop'
$ReleaseRepo='alimirzae/iMonitor-Erp-Releases'
$RawBase="https://raw.githubusercontent.com/$ReleaseRepo/main"

if(-not $InstallProduction -and -not $InstallPreview){ $InstallProduction=$true; $InstallPreview=$true }
$id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id)
if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ throw 'PowerShell را با Run as Administrator اجرا کنید.' }

$appcmd=Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
if(!(Test-Path $appcmd)){ throw 'IIS نصب نیست. ابتدا IIS را همراه ASP.NET Core Hosting Bundle نصب کنید.' }
if(-not (& $appcmd list modules | Select-String 'AspNetCoreModuleV2')){ throw 'AspNetCoreModuleV2 پیدا نشد. ASP.NET Core Hosting Bundle 8 را نصب کنید.' }
Import-Module WebAdministration

$configRoot=Join-Path $Root 'Config'; New-Item -ItemType Directory -Force -Path $Root,$configRoot | Out-Null

function Install-Channel([string]$Channel,[string]$Environment,[int]$Port,[string]$ConfigSource){
    $manifestUrl="$RawBase/manifests/erp-$Channel.json"
    $m=Invoke-RestMethod $manifestUrl -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 20
    if(-not $m.published -or [string]::IsNullOrWhiteSpace([string]$m.url)){ throw "ERP $Channel هنوز منتشر نشده است." }

    $sitePath=Join-Path $Root $Environment
    $configPath=Join-Path $configRoot ("appsettings.{0}.json" -f $Environment.ToLowerInvariant())
    if($ConfigSource){
        if(!(Test-Path $ConfigSource)){ throw "Config not found: $ConfigSource" }
        Copy-Item $ConfigSource $configPath -Force
    }
    if(!(Test-Path $configPath)){ throw "برای اولین نصب $Environment فایل تنظیمات لازم است. پارامتر Config مربوطه را بدهید." }

    $tmp=Join-Path $env:TEMP ("imonitor-erp-"+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp -Force | Out-Null
    try {
        $zip=Join-Path $tmp 'erp.zip'; Invoke-WebRequest $m.url -OutFile $zip -UseBasicParsing
        $actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant(); $expected=([string]$m.sha256).ToLowerInvariant()
        if($actual -ne $expected){ throw "SHA256 mismatch for ERP $Channel" }
        $payload=Join-Path $tmp 'payload'; Expand-Archive $zip $payload -Force

        $siteName="iMonitor ERP Local $Environment"; $pool="iMonitorLocal$Environment"
        if(Test-Path "IIS:\Sites\$siteName"){ Stop-Website $siteName -ErrorAction SilentlyContinue }
        if(Test-Path $sitePath){
            $backup=Join-Path $Root ("Backup\$Environment\"+(Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item -ItemType Directory $backup -Force | Out-Null
            Copy-Item (Join-Path $sitePath '*') $backup -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $sitePath '*') -Recurse -Force -ErrorAction SilentlyContinue
        } else { New-Item -ItemType Directory $sitePath -Force | Out-Null }
        Copy-Item (Join-Path $payload '*') $sitePath -Recurse -Force
        Copy-Item $configPath (Join-Path $sitePath 'appsettings.json') -Force

        $json=Get-Content (Join-Path $sitePath 'appsettings.json') -Raw | ConvertFrom-Json
        if($null -eq $json.Deployment){ $json | Add-Member Deployment ([pscustomobject]@{}) }
        $json.Deployment | Add-Member Environment $Environment -Force
        $json.Deployment | Add-Member LocalPort $Port -Force
        $json.Deployment | Add-Member LocalUrl "http://localhost:$Port" -Force
        $json | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $sitePath 'appsettings.json') -Encoding UTF8
        Copy-Item (Join-Path $sitePath 'appsettings.json') $configPath -Force

        if(!(Test-Path "IIS:\AppPools\$pool")){ New-WebAppPool $pool | Out-Null }
        Set-ItemProperty "IIS:\AppPools\$pool" managedRuntimeVersion ''
        Set-ItemProperty "IIS:\AppPools\$pool" processModel.identityType ApplicationPoolIdentity
        if(Test-Path "IIS:\Sites\$siteName"){ Remove-Website $siteName }
        New-Website -Name $siteName -PhysicalPath $sitePath -ApplicationPool $pool -IPAddress '*' -Port $Port | Out-Null
        & icacls $sitePath /grant "IIS AppPool\$pool:(OI)(CI)RX" /T /Q | Out-Null
        Start-Website $siteName

        $ok=$false; for($i=0;$i -lt 30;$i++){ try{ $r=Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 3; if($r.StatusCode -lt 500){$ok=$true;break} }catch{ Start-Sleep 1 } }
        if(-not $ok){ throw "ERP $Environment روی localhost:$Port پاسخ سالم نداد." }
        @{channel=$Channel;environment=$Environment;version=$m.version;sha=$m.sourceSha;port=$Port;installedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $configRoot ("state-$Channel.json")) -Encoding UTF8
        Write-Host "$Environment installed: http://localhost:$Port" -ForegroundColor Green
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if($InstallProduction){ Install-Channel 'stable' 'Production' 8080 $ProductionConfig }
if($InstallPreview){ Install-Channel 'preview' 'Preview' 8081 $PreviewConfig }

if(-not $SkipAutoUpdate){
    $updater=Join-Path $configRoot 'Update-iMonitorBranch.ps1'; Invoke-WebRequest "$RawBase/scripts/Update-iMonitorBranch.ps1" -OutFile $updater -UseBasicParsing
    $args=''; if($InstallProduction){$args+=' -UpdateProduction'}; if($InstallPreview){$args+=' -UpdatePreview'}
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -Root `"$Root`"$args"
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'iMonitor ERP Local Auto Update' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

Write-Host 'Local iMonitor ERP host is ready.' -ForegroundColor Cyan
