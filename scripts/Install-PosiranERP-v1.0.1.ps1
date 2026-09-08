[CmdletBinding()]
param(
  [ValidateSet('Both','Test','Production')][string]$Channel='Both',
  [ValidateSet('InstallOrUpdate','UpdateOnly')][string]$Mode='InstallOrUpdate',
  [string]$InstallRoot='C:\PosiranERP',
  [string]$ConfigRoot='C:\Deploy\PosiranERP',
  [int]$TestPort=8082,
  [int]$ProductionPort=8083,
  [switch]$Force,
  [switch]$SkipTaskRegistration
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run PowerShell as Administrator.'}
$repo='alimirzae/iMonitor-Erp-Releases'
$asset='PosiranERP-win-x64.zip'
$stableDir=Join-Path $InstallRoot 'installer'
$stableInstaller=Join-Path $stableDir 'Install-PosiranERP-v1.0.1.ps1'
New-Item -ItemType Directory -Force -Path $InstallRoot,$ConfigRoot,$stableDir | Out-Null
if($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($stableInstaller))){Copy-Item $PSCommandPath $stableInstaller -Force}

function Get-ChannelInfo([string]$Name){
  $isTest=$Name -eq 'Test';$key=if($isTest){'test'}else{'production'};$cfg=if($isTest){'Test'}else{'Production'}
  [pscustomobject]@{
    Name=$Name;Key=$key;Port=if($isTest){$TestPort}else{$ProductionPort};
    Site=if($isTest){'PosiranERP-Test'}else{'PosiranERP-Production'};Pool=if($isTest){'PosiranERP-Test'}else{'PosiranERP-Production'};
    Root=Join-Path (Join-Path $InstallRoot $key) 'current';State=Join-Path (Join-Path $InstallRoot $key) 'installed-release.txt';
    Config=Join-Path (Join-Path $ConfigRoot $cfg) 'appsettings.json';Prefix=if($isTest){'posiran-erp-test-v'}else{'posiran-erp-production-v'};
    Task=if($isTest){'PosiranERP-Update-Test'}else{'PosiranERP-Update-Production'};Minutes=if($isTest){1}else{5}
  }
}
function Invoke-Curl([string]$Url,[string]$Out,[int]$MaxTime=600){
  & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time $MaxTime --retry 4 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -H 'User-Agent: PosiranERP-Installer/1.0.1' $Url -o $Out
  if($LASTEXITCODE -ne 0){throw "Download failed: $Url"}
}
function Get-LatestRelease($info){
  $cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri="https://api.github.com/repos/$repo/releases?per_page=100&cb=$cb";$tmp=Join-Path $env:TEMP ('posiran-releases-'+[guid]::NewGuid().ToString('N')+'.json')
  Invoke-Curl $uri $tmp 60
  try{$rels=Get-Content $tmp -Raw|ConvertFrom-Json}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
  $r=$rels|Where-Object{$_.tag_name -like ($info.Prefix+'*')}|Sort-Object {[datetime]$_.published_at} -Descending|Select-Object -First 1
  if(!$r){throw "No published Posiran ERP $($info.Key) release found."}
  $zip=$r.assets|Where-Object{$_.name -eq $asset}|Select-Object -First 1;$sha=$r.assets|Where-Object{$_.name -eq ($asset+'.sha256')}|Select-Object -First 1
  if(!$zip -or !$sha){throw "Release $($r.tag_name) is missing package/checksum."}
  [pscustomobject]@{Tag=$r.tag_name;ZipUrl=$zip.browser_download_url;ShaUrl=$sha.browser_download_url}
}
function Register-Updater($info){
  if($SkipTaskRegistration){return}
  if(!(Test-Path $stableInstaller)){throw "Stable installer missing: $stableInstaller"}
  $args="-NoProfile -ExecutionPolicy Bypass -File `"$stableInstaller`" -Channel $($info.Name) -Mode UpdateOnly -InstallRoot `"$InstallRoot`" -ConfigRoot `"$ConfigRoot`" -TestPort $TestPort -ProductionPort $ProductionPort -SkipTaskRegistration"
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
  $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $info.Minutes) -RepetitionDuration ([TimeSpan]::MaxValue)
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
  Register-ScheduledTask -TaskName $info.Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
  Write-Host "[OK] Auto updater $($info.Task) every $($info.Minutes) minute(s)." -ForegroundColor Green
}
function Install-Channel($info){
  Write-Host "=== Posiran ERP $($info.Name) ===" -ForegroundColor Cyan
  if(!(Test-Path $info.Config)){if($Mode -eq 'UpdateOnly'){Write-Warning "Config missing for $($info.Name); update skipped.";return};throw "Dedicated Posiran ERP configuration not found: $($info.Config)"}
  $rel=Get-LatestRelease $info;$installed=if(Test-Path $info.State){(Get-Content $info.State -Raw).Trim()}else{''}
  if(!$Force -and $installed -eq $rel.Tag){Write-Host "Already current: $($rel.Tag)";Register-Updater $info;return}
  $work=Join-Path $env:TEMP ('posiran-'+$info.Key+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $work,(Split-Path $info.State -Parent),$info.Root|Out-Null
  $zip=Join-Path $work $asset;$shaFile=$zip+'.sha256'
  try{
    Invoke-Curl $rel.ZipUrl $zip;Invoke-Curl $rel.ShaUrl $shaFile 60
    $expected=((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant();$actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();if($expected -ne $actual){throw "SHA256 mismatch. expected=$expected actual=$actual"}
    Import-Module WebAdministration
    if(Test-Path "IIS:\Sites\$($info.Site)"){Stop-Website $info.Site -ErrorAction SilentlyContinue};if(Test-Path "IIS:\AppPools\$($info.Pool)"){Stop-WebAppPool $info.Pool -ErrorAction SilentlyContinue};Start-Sleep 2
    Get-ChildItem $info.Root -Force -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force;Expand-Archive $zip -DestinationPath $info.Root -Force;Copy-Item $info.Config (Join-Path $info.Root 'appsettings.json') -Force
    if(!(Test-Path "IIS:\AppPools\$($info.Pool)")){New-WebAppPool -Name $info.Pool|Out-Null};Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name managedRuntimeVersion -Value '';Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name startMode -Value 'AlwaysRunning'
    if(!(Test-Path "IIS:\Sites\$($info.Site)")){New-Website -Name $info.Site -PhysicalPath $info.Root -Port $info.Port -ApplicationPool $info.Pool|Out-Null}else{Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name physicalPath -Value $info.Root;Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name applicationPool -Value $info.Pool;Get-WebBinding -Name $info.Site -Protocol http|Remove-WebBinding -ErrorAction SilentlyContinue;New-WebBinding -Name $info.Site -Protocol http -IPAddress '*' -Port $info.Port|Out-Null}
    Start-WebAppPool $info.Pool;Start-Website $info.Site
    $ok=$false;for($i=1;$i -le 18;$i++){Start-Sleep 2;try{$r=Invoke-WebRequest "http://127.0.0.1:$($info.Port)/health" -UseBasicParsing -TimeoutSec 8;if($r.StatusCode -eq 200){$ok=$true;break}}catch{}}
    if(!$ok){throw "Health check failed on port $($info.Port)."}
    Set-Content $info.State $rel.Tag -Encoding ASCII;Write-Host "[OK] $($rel.Tag) -> http://127.0.0.1:$($info.Port)/" -ForegroundColor Green;Register-Updater $info
  }finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
}
$selected=@();if($Channel -in @('Both','Test')){$selected+=Get-ChannelInfo 'Test'};if($Channel -in @('Both','Production')){$selected+=Get-ChannelInfo 'Production'};foreach($i in $selected){Install-Channel $i}
