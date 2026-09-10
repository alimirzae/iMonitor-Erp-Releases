[CmdletBinding()]
param(
  [ValidateSet('Both','Test','Production')][string]$Channel='Both',
  [ValidateSet('InstallOrUpdate','UpdateOnly')][string]$Mode='InstallOrUpdate',
  [string]$InstallRoot='C:\PosiranERP',
  [string]$ConfigRoot='C:\Deploy\PosiranERP',
  [string]$TestFolderName='test',
  [string]$ProductionFolderName='production',
  [int]$TestPort=8082,
  [int]$ProductionPort=8083,
  [switch]$DisableAutoUpdate,
  [switch]$Force,
  [switch]$SkipTaskRegistration
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run PowerShell as Administrator.'}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$repo='alimirzae/iMonitor-Erp-Releases'
$asset='PosiranERP-win-x64.zip'
$stableDir=Join-Path $InstallRoot 'installer'
$stableInstaller=Join-Path $stableDir 'Install-PosiranERP-v1.0.3.ps1'
$packageCache=Join-Path $InstallRoot 'packages'
New-Item -ItemType Directory -Force -Path $InstallRoot,$ConfigRoot,$stableDir,$packageCache | Out-Null
if($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($stableInstaller))){Copy-Item $PSCommandPath $stableInstaller -Force}

function Assert-FolderName([string]$Name,[string]$Label){
  if([string]::IsNullOrWhiteSpace($Name)){throw "$Label folder name is required."}
  if($Name.Length -gt 80 -or $Name -match '[\\/:*?"<>|]' -or $Name.Contains('..')){throw "$Label folder name contains unsupported characters."}
}
Assert-FolderName $TestFolderName 'Test'
Assert-FolderName $ProductionFolderName 'Production'

function Get-ChannelInfo([string]$Name){
  $isTest=$Name -eq 'Test';$key=if($isTest){'test'}else{'production'};$cfg=if($isTest){'Test'}else{'Production'};$folder=if($isTest){$TestFolderName}else{$ProductionFolderName}
  $channelRoot=Join-Path $InstallRoot $folder
  [pscustomobject]@{
    Name=$Name;Key=$key;Folder=$folder;Port=if($isTest){$TestPort}else{$ProductionPort};
    Database=if($isTest){'posiran_test'}else{'posiran'};
    Site=if($isTest){'PosiranERP-Test'}else{'PosiranERP-Production'};Pool=if($isTest){'PosiranERP-Test'}else{'PosiranERP-Production'};
    Root=Join-Path $channelRoot 'current';State=Join-Path $channelRoot 'installed-release.txt';
    Config=Join-Path (Join-Path $ConfigRoot $cfg) 'appsettings.json';Prefix=if($isTest){'posiran-erp-test-v'}else{'posiran-erp-production-v'};
    Task=if($isTest){'PosiranERP-Update-Test'}else{'PosiranERP-Update-Production'};Minutes=if($isTest){1}else{5}
  }
}

function Invoke-HttpDownload([string]$Url,[string]$Out,[string]$Accept='application/octet-stream',[int]$TimeoutSeconds=600){
  $handler=New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect=$true
  $handler.AutomaticDecompression=[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $client=New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('PosiranERP-Installer/1.0.3')
  $client.DefaultRequestHeaders.CacheControl=New-Object System.Net.Http.Headers.CacheControlHeaderValue
  $client.DefaultRequestHeaders.CacheControl.NoCache=$true
  if(-not [string]::IsNullOrWhiteSpace($Accept)){$client.DefaultRequestHeaders.Accept.ParseAdd($Accept)}
  $stream=$null;$file=$null;$response=$null
  try{
    $response=$client.GetAsync($Url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode()
    $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $file=[System.IO.File]::Open($Out,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    $stream.CopyTo($file)
  } finally {
    if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};$client.Dispose();$handler.Dispose()
  }
}

function Invoke-BitsDownload([string]$Url,[string]$Out){
  Import-Module BitsTransfer -ErrorAction Stop
  if(Test-Path $Out){Remove-Item $Out -Force -ErrorAction SilentlyContinue}
  Start-BitsTransfer -Source $Url -Destination $Out -TransferType Download -DisplayName 'Posiran ERP download' -Description 'Downloading Posiran ERP package' -ErrorAction Stop
}

function Invoke-AssetDownload([string]$ApiUrl,[string]$BrowserUrl,[string]$Out,[int]$TimeoutSeconds=600){
  $errors=New-Object System.Collections.Generic.List[string]
  try{
    Write-Host '[Download] GitHub API via .NET HttpClient...' -ForegroundColor Cyan
    Invoke-HttpDownload $ApiUrl $Out 'application/octet-stream' $TimeoutSeconds
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("HttpClient API: $($_.Exception.Message)")}
  try{
    Write-Host '[Download] Windows BITS fallback...' -ForegroundColor Yellow
    Invoke-BitsDownload $BrowserUrl $Out
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("BITS: $($_.Exception.Message)")}
  try{
    Write-Host '[Download] PowerShell Invoke-WebRequest fallback...' -ForegroundColor Yellow
    Invoke-WebRequest -UseBasicParsing -Uri $BrowserUrl -OutFile $Out -TimeoutSec $TimeoutSeconds -Headers @{'User-Agent'='PosiranERP-Installer/1.0.3';'Cache-Control'='no-cache'}
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("Invoke-WebRequest: $($_.Exception.Message)")}
  throw "All native download methods failed for $BrowserUrl`n$($errors -join "`n")"
}

function Get-LatestRelease($info){
  $cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$uri="https://api.github.com/repos/$repo/releases?per_page=100&cb=$cb"
  $headers=@{'User-Agent'='PosiranERP-Installer/1.0.3';'Accept'='application/vnd.github+json';'Cache-Control'='no-cache'}
  try{$rels=Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 60}
  catch{
    $tmp=Join-Path $env:TEMP ('posiran-releases-'+[guid]::NewGuid().ToString('N')+'.json')
    try{Invoke-HttpDownload $uri $tmp 'application/vnd.github+json' 60;$rels=Get-Content $tmp -Raw|ConvertFrom-Json}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
  }
  $r=$rels|Where-Object{$_.tag_name -like ($info.Prefix+'*')}|Sort-Object {[datetime]$_.published_at} -Descending|Select-Object -First 1
  if(!$r){throw "No published Posiran ERP $($info.Key) release found."}
  $zip=$r.assets|Where-Object{$_.name -eq $asset}|Select-Object -First 1;$sha=$r.assets|Where-Object{$_.name -eq ($asset+'.sha256')}|Select-Object -First 1
  if(!$zip -or !$sha){throw "Release $($r.tag_name) is missing package/checksum."}
  [pscustomobject]@{Tag=$r.tag_name;ZipApiUrl=$zip.url;ZipBrowserUrl=$zip.browser_download_url;ShaApiUrl=$sha.url;ShaBrowserUrl=$sha.browser_download_url}
}

function Normalize-ChannelConfig($info){
  if(!(Test-Path $info.Config)){return}
  $j=Get-Content $info.Config -Raw | ConvertFrom-Json
  if(!$j.PSObject.Properties['Database']){throw "Database section is missing in $($info.Config)"}
  if(!$j.Database.PSObject.Properties['MySql']){throw "Database.MySql section is missing in $($info.Config)"}
  $j.Database.Type='MySql'
  $cs=[string]$j.Database.MySql.ConnectionString
  if([string]::IsNullOrWhiteSpace($cs)){throw "Database.MySql.ConnectionString is empty in $($info.Config)"}
  if($cs -match '(?i)(Database|Initial Catalog)\s*='){$cs=[regex]::Replace($cs,'(?i)(Database|Initial Catalog)\s*=\s*[^;]*',"Database=$($info.Database)")}else{$cs=$cs.TrimEnd(';')+";Database=$($info.Database);"}
  $j.Database.MySql.ConnectionString=$cs
  if($j.PSObject.Properties['AllowedHosts']){$j.AllowedHosts='*'}else{$j|Add-Member -NotePropertyName AllowedHosts -NotePropertyValue '*'}
  $j | ConvertTo-Json -Depth 60 | Set-Content $info.Config -Encoding UTF8
  Write-Host "[OK] Config normalized: $($info.Name) -> MySql/$($info.Database)" -ForegroundColor Green
}

function Register-Updater($info){
  if($SkipTaskRegistration){return}
  if($DisableAutoUpdate){
    Unregister-ScheduledTask -TaskName $info.Task -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[OK] Auto updater disabled for $($info.Name)." -ForegroundColor Yellow
    return
  }
  if(!(Test-Path $stableInstaller)){throw "Stable installer missing: $stableInstaller"}
  $args="-NoProfile -ExecutionPolicy Bypass -File `"$stableInstaller`" -Channel $($info.Name) -Mode UpdateOnly -InstallRoot `"$InstallRoot`" -ConfigRoot `"$ConfigRoot`" -TestFolderName `"$TestFolderName`" -ProductionFolderName `"$ProductionFolderName`" -TestPort $TestPort -ProductionPort $ProductionPort -SkipTaskRegistration"
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
  $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $info.Minutes) -RepetitionDuration ([TimeSpan]::MaxValue)
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
  Register-ScheduledTask -TaskName $info.Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
  Write-Host "[OK] Auto updater $($info.Task) every $($info.Minutes) minute(s)." -ForegroundColor Green
}

function Find-CachedPackage([string]$Tag,[string]$ExpectedHash){
  $candidates=@(
    (Join-Path (Join-Path $packageCache $Tag) $asset),
    (Join-Path (Get-Location).Path $asset),
    (Join-Path $env:USERPROFILE "Downloads\$asset")
  ) | Select-Object -Unique
  foreach($candidate in $candidates){
    if(Test-Path $candidate){
      try{
        $hash=(Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -eq $ExpectedHash){Write-Host "[Cache] Using verified local package: $candidate" -ForegroundColor Green;return $candidate}
      }catch{}
    }
  }
  return $null
}

function Install-Channel($info){
  Write-Host "=== Posiran ERP $($info.Name) ===" -ForegroundColor Cyan
  Write-Host "Folder=$($info.Folder) Port=$($info.Port) Database=$($info.Database) AutoUpdate=$(-not $DisableAutoUpdate)"
  if(!(Test-Path $info.Config)){if($Mode -eq 'UpdateOnly'){Write-Warning "Config missing for $($info.Name); update skipped.";return};throw "Dedicated Posiran ERP configuration not found: $($info.Config)"}
  Normalize-ChannelConfig $info
  $rel=Get-LatestRelease $info;$installed=if(Test-Path $info.State){(Get-Content $info.State -Raw).Trim()}else{''}
  if(!$Force -and $installed -eq $rel.Tag){Write-Host "Already current: $($rel.Tag)";Register-Updater $info;return}
  $work=Join-Path $env:TEMP ('posiran-'+$info.Key+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $work,(Split-Path $info.State -Parent),$info.Root|Out-Null
  $zip=Join-Path $work $asset;$shaFile=$zip+'.sha256'
  try{
    Invoke-AssetDownload $rel.ShaApiUrl $rel.ShaBrowserUrl $shaFile 60
    $expected=((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    if($expected -notmatch '^[a-f0-9]{64}$'){throw 'Downloaded checksum file is invalid.'}
    $cached=Find-CachedPackage $rel.Tag $expected
    if($cached){Copy-Item $cached $zip -Force}else{Invoke-AssetDownload $rel.ZipApiUrl $rel.ZipBrowserUrl $zip 900}
    $actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();if($expected -ne $actual){throw "SHA256 mismatch. expected=$expected actual=$actual"}

    $cacheDir=Join-Path $packageCache $rel.Tag;New-Item -ItemType Directory -Force -Path $cacheDir|Out-Null
    Copy-Item $zip (Join-Path $cacheDir $asset) -Force;Copy-Item $shaFile (Join-Path $cacheDir ($asset+'.sha256')) -Force

    Import-Module WebAdministration
    if(Test-Path "IIS:\Sites\$($info.Site)"){Stop-Website $info.Site -ErrorAction SilentlyContinue};if(Test-Path "IIS:\AppPools\$($info.Pool)"){Stop-WebAppPool $info.Pool -ErrorAction SilentlyContinue};Start-Sleep 2
    Get-ChildItem $info.Root -Force -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force;Expand-Archive $zip -DestinationPath $info.Root -Force;Copy-Item $info.Config (Join-Path $info.Root 'appsettings.json') -Force
    if(!(Test-Path "IIS:\AppPools\$($info.Pool)")){New-WebAppPool -Name $info.Pool|Out-Null};Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name managedRuntimeVersion -Value '';Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name startMode -Value 'AlwaysRunning'
    if(!(Test-Path "IIS:\Sites\$($info.Site)")){New-Website -Name $info.Site -PhysicalPath $info.Root -Port $info.Port -ApplicationPool $info.Pool|Out-Null}else{Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name physicalPath -Value $info.Root;Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name applicationPool -Value $info.Pool;Get-WebBinding -Name $info.Site -Protocol http|Remove-WebBinding -ErrorAction SilentlyContinue;New-WebBinding -Name $info.Site -Protocol http -IPAddress '*' -Port $info.Port|Out-Null}
    Start-WebAppPool $info.Pool;Start-Website $info.Site
    $ok=$false;for($i=1;$i -le 18;$i++){Start-Sleep 2;try{$r=Invoke-WebRequest "http://127.0.0.1:$($info.Port)/health" -UseBasicParsing -TimeoutSec 8;if($r.StatusCode -eq 200){$ok=$true;break}}catch{}}
    if(!$ok){throw "Health check failed on port $($info.Port)."}
    Set-Content $info.State $rel.Tag -Encoding ASCII;Write-Host "[OK] $($rel.Tag) -> http://127.0.0.1:$($info.Port)/ ; DB=$($info.Database) ; Folder=$($info.Folder)" -ForegroundColor Green;Register-Updater $info
  }finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
}
$selected=@();if($Channel -in @('Both','Test')){$selected+=Get-ChannelInfo 'Test'};if($Channel -in @('Both','Production')){$selected+=Get-ChannelInfo 'Production'};foreach($i in $selected){Install-Channel $i}
