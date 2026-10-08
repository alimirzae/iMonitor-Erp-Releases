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
  [string]$RuntimeHealthUrl='',
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
$stableInstaller=Join-Path $stableDir 'Install-PosiranERP-v1.0.5.ps1'
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
    Task=if($isTest){'PosiranERP-Update-Test'}else{'PosiranERP-Update-Production'};Minutes=if($isTest){10}else{0}
  }
}

function Invoke-HttpDownload([string]$Url,[string]$Out,[string]$Accept='application/octet-stream',[int]$TimeoutSeconds=600){
  $handler=New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect=$true
  $handler.AutomaticDecompression=[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $client=New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('PosiranERP-Installer/1.0.5')
  $client.DefaultRequestHeaders.CacheControl=New-Object System.Net.Http.Headers.CacheControlHeaderValue
  $client.DefaultRequestHeaders.CacheControl.NoCache=$true
  if(-not [string]::IsNullOrWhiteSpace($Accept)){$client.DefaultRequestHeaders.Accept.ParseAdd($Accept)}
  $stream=$null;$file=$null;$response=$null
  try{
    $response=$client.GetAsync($Url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    [void]$response.EnsureSuccessStatusCode()
    $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $file=[System.IO.File]::Open($Out,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    $total=$response.Content.Headers.ContentLength
    $buffer=New-Object byte[] 131072
    [long]$done=0
    $lastPct=-1
    while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
      $file.Write($buffer,0,$read)
      $done+=$read
      if($total -and $total -gt 1048576){
        $pct=[int][Math]::Min(100,[Math]::Floor(($done*100.0)/$total))
        if($pct -ge ($lastPct+5) -or $pct -eq 100){
          $lastPct=$pct
          Write-Host ("[Download] {0}% ({1:N1}/{2:N1} MB)" -f $pct,($done/1MB),($total/1MB))
        }
      }
    }
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
    Invoke-WebRequest -UseBasicParsing -Uri $BrowserUrl -OutFile $Out -TimeoutSec $TimeoutSeconds -Headers @{'User-Agent'='PosiranERP-Installer/1.0.5';'Cache-Control'='no-cache'}
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("Invoke-WebRequest: $($_.Exception.Message)")}
  throw "All native download methods failed for $BrowserUrl`n$($errors -join "`n")"
}


function Ensure-BehpardakhtPosPcDriver([string]$StageRoot){
  $driverVersion='1.4.48'
  $expectedSha='f691da423cae1052f3c867a327109d18117128ee24098ae4aefa13408e52d5b6'
  $relative='DeviceDrivers\pos\behpardakht-pospc-1.4.48\POS_PC.dll'
  $target=Join-Path $StageRoot $relative
  $targetDir=Split-Path $target -Parent
  $cacheDir=Join-Path $packageCache 'drivers\behpardakht-pospc-1.4.48'
  $cache=Join-Path $cacheDir 'POS_PC.dll'

  function Test-VerifiedPosPc([string]$Path){
    if(!(Test-Path $Path)){return $false}
    try{return (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedSha}catch{return $false}
  }

  if(Test-VerifiedPosPc $target){
    Unblock-File -Path $target -ErrorAction SilentlyContinue
    Write-Host "[PCPOS] Behpardakht POS_PC $driverVersion already present and verified." -ForegroundColor Green
    return
  }

  New-Item -ItemType Directory -Force -Path $targetDir,$cacheDir | Out-Null
  if(Test-VerifiedPosPc $cache){
    Copy-Item $cache $target -Force
    Unblock-File -Path $target -ErrorAction SilentlyContinue
    Write-Host "[PCPOS] Behpardakht POS_PC $driverVersion restored from verified local cache." -ForegroundColor Green
    return
  }

  $tmp=Join-Path $env:TEMP ('pospc-1.4.48-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try{
    $bases=@(
      'https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/drivers/behpardakht-pospc-1.4.48',
      'https://github.com/alimirzae/iMonitor-Erp-Releases/raw/refs/heads/main/drivers/behpardakht-pospc-1.4.48'
    )
    $chunks=New-Object System.Collections.Generic.List[string]
    for($i=1;$i -le 8;$i++){
      $name=('POS_PC.dll.gz.b64.part{0:d2}' -f $i)
      $part=Join-Path $tmp $name
      $downloaded=$false
      $errors=New-Object System.Collections.Generic.List[string]
      foreach($base in $bases){
        try{
          Invoke-HttpDownload "$base/$name?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" $part 'text/plain' 60
          if((Test-Path $part) -and (Get-Item $part).Length -gt 0){$downloaded=$true;break}
        }catch{$errors.Add($_.Exception.Message)}
      }
      if(!$downloaded){throw "Could not download Behpardakht POS-PC payload $name. $($errors -join ' | ')"}
      $chunks.Add((Get-Content $part -Raw).Trim())
    }

    $b64=($chunks -join '')
    if($b64.Length -ne 41632){throw "Behpardakht POS-PC payload length mismatch. expected=41632 actual=$($b64.Length)"}
    $compressed=[Convert]::FromBase64String($b64)
    $input=New-Object System.IO.MemoryStream(,$compressed)
    $gzip=New-Object System.IO.Compression.GZipStream($input,[System.IO.Compression.CompressionMode]::Decompress)
    $output=[System.IO.File]::Open($target,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try{$gzip.CopyTo($output)}finally{$output.Dispose();$gzip.Dispose();$input.Dispose()}

    $actual=(Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actual -ne $expectedSha){Remove-Item $target -Force -ErrorAction SilentlyContinue;throw "Behpardakht POS-PC SHA256 mismatch. expected=$expectedSha actual=$actual"}
    $version=[System.Diagnostics.FileVersionInfo]::GetVersionInfo($target).FileVersion
    if([string]::IsNullOrWhiteSpace($version) -or -not $version.StartsWith('1.4.48')){Remove-Item $target -Force -ErrorAction SilentlyContinue;throw "Behpardakht POS-PC file version mismatch: $version"}

    Unblock-File -Path $target -ErrorAction SilentlyContinue
    Remove-Item ($target+':Zone.Identifier') -Force -ErrorAction SilentlyContinue
    Copy-Item $target $cache -Force
    Unblock-File -Path $cache -ErrorAction SilentlyContinue
    Write-Host "[OK] Behpardakht POS-PC $driverVersion provisioned and SHA256 verified." -ForegroundColor Green
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}


function Get-LatestRelease($info){
  $cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $manifestChannel=if($info.Name -eq 'Test'){'test'}else{'production'}
  $manifestUrl="https://raw.githubusercontent.com/$repo/main/channels/posiran/$manifestChannel/latest.json?cb=$cb"
  try{
    $m=Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 15 -Headers @{'User-Agent'='PosiranERP-Installer/1.0.5';'Cache-Control'='no-cache'}
    if([string]$m.tag -like ($info.Prefix+'*')){
      $releaseBase="https://github.com/$repo/releases/download/$([string]$m.tag)"
      Write-Host '[Release] Static channel manifest selected (GitHub API not required).' -ForegroundColor Green
      return [pscustomobject]@{Tag=[string]$m.tag;ZipApiUrl="$releaseBase/$asset";ZipBrowserUrl="$releaseBase/$asset";ShaApiUrl="$releaseBase/$asset.sha256";ShaBrowserUrl="$releaseBase/$asset.sha256"}
    }
  }catch{Write-Warning "Static channel manifest unavailable: $($_.Exception.Message)"}
  $uri="https://api.github.com/repos/$repo/releases?per_page=100&cb=$cb"
  $headers=@{'User-Agent'='PosiranERP-Installer/1.0.5';'Accept'='application/vnd.github+json';'Cache-Control'='no-cache'}
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
  $utf8=[System.Text.Encoding]::UTF8
  $brandName=$utf8.GetString([Convert]::FromBase64String('UG9zaXJhbiBFUlAgfCDZvtmI2LIg2KfbjNix2KfZhg=='))
  $brandTagline=$utf8.GetString([Convert]::FromBase64String('2LHYp9mH2qnYp9ixINuM2qnZvtin2LHahtmHINmB2LHZiNi02Iwg2K3Ys9in2KjYr9in2LHbjCDZiCDZhdiv24zYsduM2Ko='))
  $brand=[pscustomobject][ordered]@{Key='posiran';Name=$brandName;Tagline=$brandTagline;LogoPath='/brands/posiran/logo-mark.png?v=20260926';WordmarkPath='/brands/posiran/wordmark.png?v=20260926';FaviconPath='/brands/posiran/icon.png?v=20260927';ThemePath='/brands/posiran/theme.css?v=posiran-20260926';PrimaryColor='#123FA3';SecondaryColor='#F5B335'}
  $update=[pscustomobject][ordered]@{Repository='alimirzae/iMonitor-Erp-Releases';Channel=$info.Key;TestTagPrefix='posiran-erp-test-v';ProductionTagPrefix='posiran-erp-production-v';TestTaskName='PosiranERP-Update-Test';ProductionTaskName='PosiranERP-Update-Production';ManualUpdateOnly=($info.Name -ne 'Test');AutoUpdate=($info.Name -eq 'Test');TestIntervalMinutes=10}
  if($j.PSObject.Properties['Branding']){$j.Branding=$brand}else{$j|Add-Member -NotePropertyName Branding -NotePropertyValue $brand}
  if($j.PSObject.Properties['Update']){$j.Update=$update}else{$j|Add-Member -NotePropertyName Update -NotePropertyValue $update}
  $j.Database.AutoMigrate=$true;$j.Database.MigrateOnStartup=$true;$j.Database.UseBackgroundMigration=$false;$j.Database.DropDatabaseOnStartup=$false
  if($j.PSObject.Properties['AllowedHosts']){$j.AllowedHosts='*'}else{$j|Add-Member -NotePropertyName AllowedHosts -NotePropertyValue '*'}
  $j | ConvertTo-Json -Depth 60 | Set-Content $info.Config -Encoding UTF8
  Write-Host "[OK] Config normalized: $($info.Name) -> MySql/$($info.Database)" -ForegroundColor Green
}

function Register-Updater($info){
  if($SkipTaskRegistration){return}
  $localUpdater=Join-Path $info.Root 'Update-PosiranERP.ps1'
  if(!(Test-Path $localUpdater)){
    Write-Warning "Local updater missing; repairing it before task registration: $localUpdater"
    if(!(Test-Path $info.Root)){throw "ERP current folder is missing: $($info.Root)"}
    Write-LocalUpdater $info $info.Root
  }
  if(!(Test-Path $localUpdater)){throw "Could not repair local updater: $localUpdater"}
  $args="-NoProfile -ExecutionPolicy Bypass -File `"$localUpdater`""
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
  Unregister-ScheduledTask -TaskName $info.Task -Confirm:$false -ErrorAction SilentlyContinue
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
  if($info.Name -eq 'Test' -and -not $DisableAutoUpdate){
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $info.Task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
    Write-Host "[OK] Test auto updater $($info.Task) every 10 minutes." -ForegroundColor Green
  }else{
    Register-ScheduledTask -TaskName $info.Task -Action $action -Principal $principal -Settings $settings -Force|Out-Null
    Write-Host "[OK] Production updater $($info.Task) is manual-only and can be triggered from /system/update." -ForegroundColor Green
  }
}

function Write-LocalUpdater($info,[string]$Destination){
  function Q([string]$value){return "'"+$value.Replace("'","''")+"'"}
  $channelInstaller=Join-Path $Destination 'Install-PosiranERP.ps1'
  if(!(Test-Path $channelInstaller)){Copy-Item $stableInstaller $channelInstaller -Force}
  $content=@"
[CmdletBinding()]
param([switch]`$Force)
`$ErrorActionPreference='Stop'
`$root=$(Q $info.Root)
`$rollback=`$root+'.rollback'
`$port=$($info.Port)
function Test-Health { try{`$r=Invoke-WebRequest "http://127.0.0.1:`$port/health" -UseBasicParsing -TimeoutSec 8;return `$r.StatusCode -eq 200}catch{return `$false} }
# Automatic rollback is intentionally disabled. A failed version is kept for diagnostics.
# Administrators explicitly choose a previously healthy release from the Deployment Manager.
& $(Q $channelInstaller) -Channel $(Q $info.Name) -Mode UpdateOnly -InstallRoot $(Q $InstallRoot) -ConfigRoot $(Q $ConfigRoot) -TestFolderName $(Q $TestFolderName) -ProductionFolderName $(Q $ProductionFolderName) -TestPort $TestPort -ProductionPort $ProductionPort -SkipTaskRegistration -Force:`$Force
"@
  Set-Content (Join-Path $Destination 'Update-PosiranERP.ps1') $content -Encoding UTF8
}

function Stop-ChannelHost($info){
  $offline=Join-Path $info.Root 'app_offline.htm'
  if(Test-Path $info.Root){Set-Content $offline 'Posiran ERP is being updated.' -Encoding ASCII -ErrorAction SilentlyContinue}
  if(Test-Path "IIS:\Sites\$($info.Site)"){
    try{if((Get-WebsiteState -Name $info.Site).Value -ne 'Stopped'){Stop-Website $info.Site -ErrorAction Stop}}catch{Write-Verbose "Website stop skipped: $($_.Exception.Message)"}
  }
  if(Test-Path "IIS:\AppPools\$($info.Pool)"){
    try{if((Get-WebAppPoolState -Name $info.Pool).Value -ne 'Stopped'){Stop-WebAppPool $info.Pool -ErrorAction Stop}}catch{Write-Verbose "Application pool stop skipped: $($_.Exception.Message)"}
  }
  $appcmd=Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
  if(Test-Path $appcmd){
    $workerIds=& $appcmd list wp "/apppool.name:$($info.Pool)" /text:WP.NAME 2>$null
    foreach($workerId in $workerIds){if($workerId -match '^\d+$'){Stop-Process -Id ([int]$workerId) -Force -ErrorAction SilentlyContinue}}
  }
  # Never delete current here: it is the rollback source. Probe until IIS releases file handles.
  for($i=1;$i -le 20;$i++){
    try{
      $probe=Join-Path $info.Root '.update-lock-probe'
      Set-Content $probe 'ok' -ErrorAction Stop
      Remove-Item $probe -Force -ErrorAction Stop
      return
    }catch{
      if($i -eq 20){throw "Application files are still locked after stopping IIS: $($_.Exception.Message)"}
      Start-Sleep -Milliseconds 750
    }
  }
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
  $backup=$null
  Write-Host "=== Posiran iBOS $($info.Name) ===" -ForegroundColor Cyan
  Write-Host "[PROGRESS 2] Initialize installation and validate configuration"
  Write-Host "Folder=$($info.Folder) Port=$($info.Port) Database=$($info.Database) UpdateMode=$(if($info.Name -eq 'Test' -and -not $DisableAutoUpdate){'AutoEvery10Minutes'}else{'ManualOnly'})"
  if(!(Test-Path $info.Config)){if($Mode -eq 'UpdateOnly'){Write-Warning "Config missing for $($info.Name); update skipped.";return};throw "Dedicated Posiran ERP configuration not found: $($info.Config)"}
  Normalize-ChannelConfig $info
  $rel=Get-LatestRelease $info;$installed=if(Test-Path $info.State){(Get-Content $info.State -Raw).Trim()}else{''}
  # Never auto-downgrade a channel if its manifest accidentally points to an older semantic version.
  function Get-TagVersion([string]$tag){
    $m=[regex]::Match($tag,'v(?<v>\d+(?:\.\d+)+)$')
    if($m.Success){try{return [version]$m.Groups['v'].Value}catch{}}
    return $null
  }
  $installedVersion=Get-TagVersion $installed
  $latestVersion=Get-TagVersion $rel.Tag
  if(!$Force -and $installedVersion -and $latestVersion -and $latestVersion -lt $installedVersion){
    Write-Warning "Manifest release $($rel.Tag) is older than installed $installed; automatic downgrade blocked."
    Write-LocalUpdater $info $info.Root
    Register-Updater $info
    return
  }
  if(!$Force -and $installed -eq $rel.Tag){
    Write-Host "Already current: $($rel.Tag)"
    # Repair support/update files even when application binaries are already current.
    Write-LocalUpdater $info $info.Root
    Register-Updater $info
    return
  }
  $work=Join-Path $env:TEMP ('posiran-'+$info.Key+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $work,(Split-Path $info.State -Parent),$info.Root|Out-Null
  $zip=Join-Path $work $asset;$shaFile=$zip+'.sha256'
  try{
    Write-Host "[PROGRESS 10] Download release checksum"
    Invoke-AssetDownload $rel.ShaApiUrl $rel.ShaBrowserUrl $shaFile 60
    $expected=((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    if($expected -notmatch '^[a-f0-9]{64}$'){throw 'Downloaded checksum file is invalid.'}
    $cached=Find-CachedPackage $rel.Tag $expected
    if($cached){Write-Host "[PROGRESS 35] Use verified package cache";Copy-Item $cached $zip -Force}else{Write-Host "[PROGRESS 15] Download release package";Invoke-AssetDownload $rel.ZipApiUrl $rel.ZipBrowserUrl $zip 900;Write-Host "[PROGRESS 38] Package download completed"}
    $actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();if($expected -ne $actual){throw "SHA256 mismatch. expected=$expected actual=$actual"}

    $cacheDir=Join-Path $packageCache $rel.Tag;New-Item -ItemType Directory -Force -Path $cacheDir|Out-Null
    Copy-Item $zip (Join-Path $cacheDir $asset) -Force;Copy-Item $shaFile (Join-Path $cacheDir ($asset+'.sha256')) -Force

    Write-Host "[PROGRESS 45] Extract package"
    $stage=Join-Path $work 'stage';Expand-Archive $zip -DestinationPath $stage -Force
    Ensure-BehpardakhtPosPcDriver $stage
    Write-Host "[PROGRESS 55] Package extraction completed"
    if(!(Test-Path (Join-Path $stage 'Ecomm.dll')) -or !(Test-Path (Join-Path $stage 'web.config'))){throw 'Release package is incomplete (Ecomm.dll/web.config missing).'}
    Copy-Item $info.Config (Join-Path $stage 'appsettings.json') -Force
    Set-Content (Join-Path $stage 'release-tag.txt') $rel.Tag -Encoding ASCII
    $packagedInstaller=Join-Path $stage 'Install-PosiranERP.ps1'
    if(!(Test-Path $packagedInstaller)){Copy-Item $stableInstaller $packagedInstaller -Force}
    Write-LocalUpdater $info $stage
    Import-Module WebAdministration
    Write-Host "[PROGRESS 60] Stop IIS site and application pool"
    Stop-ChannelHost $info
    Write-Host "[PROGRESS 66] IIS stopped and application files unlocked"
    $backup=$info.Root+'.rollback'
    if(Test-Path $backup){for($i=1;$i -le 10;$i++){try{Remove-Item $backup -Recurse -Force -ErrorAction Stop;break}catch{if($i -eq 10){throw};Start-Sleep 1}}}
    if(Test-Path $info.Root){
      [void][IO.Directory]::CreateDirectory($backup)
      for($i=1;$i -le 10;$i++){try{Copy-Item (Join-Path $info.Root '*') $backup -Recurse -Force -ErrorAction Stop;break}catch{if($i -eq 10){throw};Start-Sleep 1}}
      Remove-Item (Join-Path $backup 'app_offline.htm') -Force -ErrorAction SilentlyContinue # taken after Stop-ChannelHost wrote it; a restore must not bring the 503 back
      for($i=1;$i -le 10;$i++){try{Get-ChildItem $info.Root -Force|Remove-Item -Recurse -Force -ErrorAction Stop;break}catch{if($i -eq 10){throw};Start-Sleep 1}}
    }else{[void][IO.Directory]::CreateDirectory($info.Root)}
    Write-Host "[PROGRESS 74] Copy and activate staged version"
    for($i=1;$i -le 10;$i++){try{Copy-Item (Join-Path $stage '*') $info.Root -Recurse -Force -ErrorAction Stop;break}catch{if($i -eq 10){throw};Start-Sleep 1}}
    Write-Host "[PROGRESS 82] New version files activated"
    # Ensure IIS worker can read/execute the deployed application after Move-Item/rollback operations.
    & icacls.exe $info.Root /grant:r "IIS_IUSRS:(OI)(CI)RX" /T /C | Out-Null
    if($LASTEXITCODE -ne 0){throw "Failed to grant IIS_IUSRS read/execute permission on $($info.Root)."}
    & icacls.exe $info.Root /grant:r "IIS AppPool\$($info.Pool):(OI)(CI)RX" /T /C | Out-Null
    if($LASTEXITCODE -ne 0){Write-Warning "Could not grant explicit AppPool ACL; IIS_IUSRS permission is present."}
    if(!(Test-Path "IIS:\AppPools\$($info.Pool)")){New-WebAppPool -Name $info.Pool|Out-Null};Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name managedRuntimeVersion -Value '';Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name enable32BitAppOnWin64 -Value $false;Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name startMode -Value 'AlwaysRunning'
    if(!(Test-Path "IIS:\Sites\$($info.Site)")){New-Website -Name $info.Site -PhysicalPath $info.Root -Port $info.Port -ApplicationPool $info.Pool|Out-Null}else{Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name physicalPath -Value $info.Root;Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name applicationPool -Value $info.Pool;Write-Host '[IIS] Existing bindings preserved; port configured on first site creation only.'}
    Write-Host "[PROGRESS 86] Start IIS site and application pool"
    Start-WebAppPool $info.Pool;Start-Website $info.Site
    Write-Host "[PROGRESS 90] Verify runtime health"
    $healthUrl="http://127.0.0.1:$($info.Port)/health"
    if(-not [string]::IsNullOrWhiteSpace($RuntimeHealthUrl)){
      $healthUrl=$RuntimeHealthUrl.TrimEnd('/')
      if(!$healthUrl.EndsWith('/health')){$healthUrl+='/health'}
    }
    if($healthUrl -notmatch '^https?://'){throw 'RuntimeHealthUrl must be HTTP(S)'}
    $ok=$false
    for($i=1;$i -le 45;$i++){Start-Sleep 2;try{$r=Invoke-WebRequest $healthUrl -UseBasicParsing -TimeoutSec 8;if($r.StatusCode -eq 200){$ok=$true;break}}catch{}}
    if(!$ok){throw "Health check failed on port $($info.Port)."}
    if(Test-Path $backup){Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue}
    Write-Host "[PROGRESS 100] Installation and health verification succeeded"
    Copy-Item (Join-Path $info.Root 'Install-PosiranERP.ps1') $stableInstaller -Force
    Set-Content $info.State $rel.Tag -Encoding ASCII;Write-Host "[OK] $($rel.Tag) -> http://127.0.0.1:$($info.Port)/ ; DB=$($info.Database) ; Folder=$($info.Folder)" -ForegroundColor Green;Register-Updater $info
  }catch{
    $failure=$_
    if($backup -and (Test-Path $backup)){
      Write-Warning "Deployment failed for $($info.Name). Automatic rollback is disabled. Previous files are preserved at $backup for an explicit administrator rollback."
    }else{
      Write-Warning "Deployment failed for $($info.Name). Automatic rollback is disabled."
    }
    throw $failure
  }finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
}
$selected=@();if($Channel -in @('Both','Test')){$selected+=Get-ChannelInfo 'Test'};if($Channel -in @('Both','Production')){$selected+=Get-ChannelInfo 'Production'};foreach($i in $selected){Install-Channel $i}
