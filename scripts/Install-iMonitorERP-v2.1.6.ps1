[CmdletBinding()]
param(
  [ValidateSet('Both','Test','Production')][string]$Channel='Both',
  [ValidateSet('InstallOrUpdate','UpdateOnly')][string]$Mode='InstallOrUpdate',
  [string]$InstallRoot='C:\ecomm',
  [string]$ConfigRoot='C:\ecomm\config',
  [string]$TestFolderName='test',
  [string]$ProductionFolderName='production',
  [int]$TestPort=8081,
  [int]$ProductionPort=8080,
  [string]$RuntimeHealthUrl='',
  [string]$TestHostHeader='',
  [string]$ProductionHostHeader='',
  [string]$TestPhysicalPath='',
  [string]$ProductionPhysicalPath='',
  [string]$MySqlServer='127.0.0.1',
  [int]$MySqlPort=3306,
  [string]$MySqlUser='root',
  [string]$MySqlPassword='',
  [string]$MySqlAdminUser='root',
  [string]$MySqlAdminPassword='',
  [switch]$RecreateTestDatabase,
  [switch]$SkipMySqlProvisioning,
  [switch]$Force,
  [switch]$SkipTaskRegistration
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run PowerShell as Administrator.'}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$repo='alimirzae/iMonitor-Erp-Releases'
$asset='iMonitor-EcomERP-win-x64.zip'
$stableDir=Join-Path $InstallRoot 'installer'
$stableInstaller=Join-Path $stableDir 'Install-iMonitorERP-v2.1.6.ps1'
$packageCache=Join-Path $InstallRoot 'packages'
$workRoot=Join-Path $InstallRoot '.installer-work'
New-Item -ItemType Directory -Force -Path $InstallRoot,$ConfigRoot,$stableDir,$packageCache,$workRoot | Out-Null
if($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($stableInstaller))){Copy-Item $PSCommandPath $stableInstaller -Force}

$createdNew=$false
$installMutex=New-Object Threading.Mutex($true,'Global\iMonitorERP-Installer-v2',[ref]$createdNew)
if(!$createdNew){
  Write-Host 'Another iMonitor ERP install/update is running; waiting for it to finish...' -ForegroundColor Yellow
  if(!$installMutex.WaitOne([TimeSpan]::FromMinutes(30))){throw 'Timed out waiting for the other iMonitor ERP installer.'}
}

function Assert-FolderName([string]$Name,[string]$Label){
  if([string]::IsNullOrWhiteSpace($Name)){throw "$Label folder name is required."}
  if($Name.Length -gt 80 -or $Name -match '[\\/:*?"<>|]' -or $Name.Contains('..')){throw "$Label folder name contains unsupported characters."}
}
Assert-FolderName $TestFolderName 'Test'
Assert-FolderName $ProductionFolderName 'Production'

function Ensure-IisPrerequisites{
  if(Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue){Install-WindowsFeature Web-Server,Web-Mgmt-Console -IncludeManagementTools|Out-Null}
  elseif(Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue){Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-ManagementConsole,IIS-StaticContent,IIS-DefaultDocument,IIS-HttpErrors,IIS-HttpLogging,IIS-RequestFiltering -All -NoRestart|Out-Null}
  Import-Module WebAdministration -ErrorAction Stop
  if(!(Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue)){throw 'ASP.NET Core Hosting Bundle 8 / AspNetCoreModuleV2 is missing. Install it, restart IIS, and rerun this installer.'}
  Set-Service W3SVC -StartupType Automatic;Start-Service W3SVC
}

function Get-ChannelInfo([string]$Name){
  $isTest=$Name -eq 'Test';$key=if($isTest){'test'}else{'production'};$cfg=if($isTest){'Test'}else{'Production'};$folder=if($isTest){$TestFolderName}else{$ProductionFolderName}
  $configuredPath=if($isTest){$TestPhysicalPath}else{$ProductionPhysicalPath}
  $channelRoot=Join-Path $InstallRoot $folder
  $root=if([string]::IsNullOrWhiteSpace($configuredPath)){Join-Path $channelRoot 'current'}else{$configuredPath}
  [pscustomobject]@{
    Name=$Name;Key=$key;Folder=$folder;Port=if($isTest){$TestPort}else{$ProductionPort};
    Database=if($isTest){'ecomm_dev'}else{'ecomm'};
    Site=if($isTest){'iMonitorERP-Test'}else{'iMonitorERP-Production'};Pool=if($isTest){'iMonitorERP-Test'}else{'iMonitorERP-Production'};
    Root=$root;State=Join-Path $channelRoot 'installed-release.txt';
    Config=Join-Path (Join-Path $ConfigRoot $cfg) 'appsettings.json';Prefix=if($isTest){'imonitor-ecomerp-test-v'}else{'imonitor-ecomerp-master-v'};
    HostHeader=if($isTest){$TestHostHeader}else{$ProductionHostHeader}
  }
}

function Invoke-HttpDownload([string]$Url,[string]$Out,[string]$Accept='application/octet-stream',[int]$TimeoutSeconds=600){
  $handler=New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect=$true
  $handler.AutomaticDecompression=[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $client=New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('iMonitorERP-Installer/2.1.4')
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
  Start-BitsTransfer -Source $Url -Destination $Out -TransferType Download -DisplayName 'iMonitor ERP download' -Description 'Downloading iMonitor ERP package' -ErrorAction Stop
}

function Invoke-AssetDownload([string]$ApiUrl,[string]$BrowserUrl,[string]$Out,[int]$TimeoutSeconds=600){
  $errors=New-Object System.Collections.Generic.List[string]
  try{
    Write-Host '[Download] Native HTTP stream...' -ForegroundColor Cyan
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
    Invoke-WebRequest -UseBasicParsing -Uri $BrowserUrl -OutFile $Out -TimeoutSec $TimeoutSeconds -Headers @{'User-Agent'='iMonitorERP-Installer/2.1.4';'Cache-Control'='no-cache'}
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
  $cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$mirrorChannel=if($info.Name -eq 'Test'){'test'}else{'master'}
  # Primary discovery is a tiny static manifest on raw.githubusercontent.com.
  # It is not rate-limited like api.github.com and does not depend on the ERP server being healthy.
  $manifestUrl="https://raw.githubusercontent.com/$repo/main/channels/imonitor/$mirrorChannel/latest.json?cb=$cb"
  try{
    $m=Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 15 -Headers @{'User-Agent'='iMonitorERP-Installer/2.1.6';'Cache-Control'='no-cache'}
    if([string]$m.tag -like ($info.Prefix+'*')){
      $releaseBase="https://github.com/$repo/releases/download/$([string]$m.tag)"
      Write-Host '[Release] Static channel manifest selected (GitHub API not required).' -ForegroundColor Green
      return [pscustomobject]@{Tag=[string]$m.tag;ZipApiUrl="$releaseBase/$asset";ZipBrowserUrl="$releaseBase/$asset";ShaApiUrl="$releaseBase/$asset.sha256";ShaBrowserUrl="$releaseBase/$asset.sha256"}
    }
  }catch{Write-Warning "Static channel manifest unavailable: $($_.Exception.Message)"}
  $mirrorChannel=if($info.Name -eq 'Test'){'test'}else{'master'}
  $mirrorRoot="https://testerp.imonitor.ir/downloads/erp/$mirrorChannel"
  try{
    $m=Invoke-RestMethod -Uri "$mirrorRoot/latest.json?cb=$cb" -TimeoutSec 8 -Headers @{'Cache-Control'='no-cache'}
    if([string]$m.tag -like ($info.Prefix+'*')){
      Write-Host '[Release] Domestic mirror selected (GitHub API not required).' -ForegroundColor Green
      return [pscustomobject]@{Tag=[string]$m.tag;ZipApiUrl="$mirrorRoot/$asset";ZipBrowserUrl="$mirrorRoot/$asset";ShaApiUrl="$mirrorRoot/$asset.sha256.txt";ShaBrowserUrl="$mirrorRoot/$asset.sha256.txt"}
    }
  }catch{Write-Warning "Domestic release mirror unavailable: $($_.Exception.Message)"}

  try{
    $atomFile=Join-Path $workRoot ('imonitor-releases-'+[guid]::NewGuid().ToString('N')+'.atom')
    try{Invoke-HttpDownload "https://github.com/$repo/releases.atom?cb=$cb" $atomFile 'application/atom+xml' 30;[xml]$feed=Get-Content $atomFile -Raw}
    finally{Remove-Item $atomFile -Force -ErrorAction SilentlyContinue}
    $tag=@($feed.feed.entry|ForEach-Object{([string]$_.id -split '/')[-1]}|Where-Object{$_ -like ($info.Prefix+'*')}|Select-Object -First 1)
    if($tag.Count -gt 0 -and ![string]::IsNullOrWhiteSpace($tag[0])){
      $releaseBase="https://github.com/$repo/releases/download/$($tag[0])"
      Write-Host '[Release] GitHub Atom feed selected (rate-limit free).' -ForegroundColor Green
      return [pscustomobject]@{Tag=$tag[0];ZipApiUrl="$releaseBase/$asset";ZipBrowserUrl="$releaseBase/$asset";ShaApiUrl="$releaseBase/$asset.sha256";ShaBrowserUrl="$releaseBase/$asset.sha256"}
    }
  }catch{Write-Warning "GitHub Atom release discovery unavailable: $($_.Exception.Message)"}

  $uri="https://api.github.com/repos/$repo/releases?per_page=100&cb=$cb";$headers=@{'User-Agent'='iMonitorERP-Installer/2.1.4';'Accept'='application/vnd.github+json';'Cache-Control'='no-cache'}
  try{$rels=Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30}catch{throw "All release metadata sources failed. GitHub API fallback: $($_.Exception.Message)"}
  $r=$rels|Where-Object{!$_.draft -and $_.tag_name -like ($info.Prefix+'*')}|Sort-Object {[datetime]$_.published_at} -Descending|Select-Object -First 1
  if(!$r){throw "No published iMonitor ERP $($info.Key) release found."}
  $zip=$r.assets|Where-Object{$_.name -eq $asset}|Select-Object -First 1;$sha=$r.assets|Where-Object{$_.name -eq ($asset+'.sha256')}|Select-Object -First 1
  if(!$zip -or !$sha){throw "Release $($r.tag_name) is missing package/checksum."}
  [pscustomobject]@{Tag=$r.tag_name;ZipApiUrl=$zip.url;ZipBrowserUrl=$zip.browser_download_url;ShaApiUrl=$sha.url;ShaBrowserUrl=$sha.browser_download_url}
}

function Ensure-Object($parent,[string]$name){
  $p=$parent.PSObject.Properties[$name]
  if(!$p -or $null -eq $p.Value){$v=[pscustomobject]@{};if($p){$p.Value=$v}else{$parent|Add-Member -NotePropertyName $name -NotePropertyValue $v};return $v}
  return $p.Value
}
function Set-Value($parent,[string]$name,$value){$p=$parent.PSObject.Properties[$name];if($p){$p.Value=$value}else{$parent|Add-Member -NotePropertyName $name -NotePropertyValue $value}}

function Initialize-ChannelConfig($info){
  if(Test-Path $info.Config){return}
  New-Item -ItemType Directory -Force -Path (Split-Path $info.Config -Parent)|Out-Null
  $legacy=if($info.Name -eq 'Test'){'C:\Ecom-Test\appsettings.json'}else{'C:\Ecom\appsettings.json'}
  $current=Join-Path $info.Root 'appsettings.json'
  $sibling=if($info.Name -eq 'Test'){Join-Path (Join-Path $ConfigRoot 'Production') 'appsettings.json'}else{Join-Path (Join-Path $ConfigRoot 'Test') 'appsettings.json'}
  $source=@($current,$legacy,$sibling)|Where-Object{Test-Path $_}|Select-Object -First 1
  if($source){Copy-Item $source $info.Config -Force;Write-Host "[OK] Initial config copied from $source" -ForegroundColor Green}
  if([string]::IsNullOrWhiteSpace($MySqlPassword)){throw "No existing configuration was found for $($info.Name). This is expected on a brand-new server: the README 'Standard Setup' quick command does not include MySQL credentials. Rerun with credentials, e.g.:`n  -Channel $($info.Name) -MySqlServer $MySqlServer -MySqlUser $MySqlUser -MySqlPassword '<password>' -MySqlAdminUser $MySqlAdminUser -MySqlAdminPassword '<password>'"}
  [pscustomobject]@{AllowedHosts='*';Database=[pscustomobject]@{Type='MySql';MySql=[pscustomobject]@{}};ConnectionStrings=[pscustomobject]@{}} |
    ConvertTo-Json -Depth 20 | Set-Content $info.Config -Encoding UTF8
}

function Get-ExistingConnectionString($info){
  $legacyPath = if($info.Name -eq 'Test'){'C:\Ecom-Test\appsettings.json'}else{'C:\Ecom\appsettings.json'}
  $candidates=@(
    $info.Config,
    (Join-Path $info.Root 'appsettings.json'),
    (Join-Path (Join-Path $info.Root 'current') 'appsettings.json'),
    $legacyPath
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
  foreach($path in $candidates){
    try{
      $j=Get-Content $path -Raw|ConvertFrom-Json
      if($j.Database -and $j.Database.MySql -and $j.Database.MySql.ConnectionString){
        $v=[string]$j.Database.MySql.ConnectionString
        if(![string]::IsNullOrWhiteSpace($v)){Write-Host "[OK] Recovered MySQL connection from $path" -ForegroundColor Green;return $v}
      }
      if($j.ConnectionStrings -and $j.ConnectionStrings.MySql){
        $v=[string]$j.ConnectionStrings.MySql
        if(![string]::IsNullOrWhiteSpace($v)){Write-Host "[OK] Recovered MySQL connection from $path" -ForegroundColor Green;return $v}
      }
    }catch{}
  }
  return ''
}

function Normalize-ChannelConfig($info){
  Initialize-ChannelConfig $info
  $j=Get-Content $info.Config -Raw|ConvertFrom-Json
  $db=Ensure-Object $j 'Database';$mysql=Ensure-Object $db 'MySql';$connections=Ensure-Object $j 'ConnectionStrings'
  # ERP is MySQL-only. Remove legacy SQL Server keys so a stale config can never switch the runtime back.
  if($connections.PSObject.Properties['SqlServer']){$connections.PSObject.Properties.Remove('SqlServer')}
  if($connections.PSObject.Properties['SqlServer_Alt']){$connections.PSObject.Properties.Remove('SqlServer_Alt')}
  if($db.PSObject.Properties['SqlServer']){$db.PSObject.Properties.Remove('SqlServer')}
  $existing=if($mysql.PSObject.Properties['ConnectionString']){[string]$mysql.ConnectionString}else{''}
  if([string]::IsNullOrWhiteSpace($existing) -and $connections.PSObject.Properties['MySql']){$existing=[string]$connections.MySql}
  if([string]::IsNullOrWhiteSpace($existing)){$existing=Get-ExistingConnectionString $info}
  if([string]::IsNullOrWhiteSpace($existing)){
    if([string]::IsNullOrWhiteSpace($MySqlPassword)){throw "MySQL connection string is missing in $($info.Config). Supply -MySqlPassword (e.g. -Channel $($info.Name) -MySqlServer $MySqlServer -MySqlUser $MySqlUser -MySqlPassword '<password>')."}
    $existing="Server=$MySqlServer;Port=$MySqlPort;Database=$($info.Database);User=$MySqlUser;Password=$MySqlPassword;CharSet=utf8mb4;"
  }
  if($existing -match '(?i)(Database|Initial Catalog)\s*='){$existing=[regex]::Replace($existing,'(?i)(Database|Initial Catalog)\s*=\s*[^;]*',"Database=$($info.Database)")}else{$existing=$existing.TrimEnd(';')+";Database=$($info.Database);"}
  Set-Value $db 'Type' 'MySql';Set-Value $db 'AutoMigrate' $true;Set-Value $db 'MigrateOnStartup' $true;Set-Value $db 'UseBackgroundMigration' $false;Set-Value $db 'DropDatabaseOnStartup' $false
  Set-Value $mysql 'ConnectionString' $existing;Set-Value $connections 'MySql' $existing;Set-Value $j 'AllowedHosts' '*'
  $update=[pscustomobject][ordered]@{Repository=$repo;Channel=$info.Key;TestTagPrefix='imonitor-ecomerp-test-v';ProductionTagPrefix='imonitor-ecomerp-master-v';TestTaskName='iMonitorERP-Update-Test';ProductionTaskName='iMonitorERP-Update-Production';ManualUpdateOnly=($info.Name -ne 'Test');AutoUpdate=($info.Name -eq 'Test');AutoUpdateIntervalMinutes=10}
  Set-Value $j 'Update' $update
  $j|ConvertTo-Json -Depth 100|Set-Content $info.Config -Encoding UTF8
  Write-Host "[OK] Config normalized: $($info.Name) -> MySql/$($info.Database); startup migrations enabled." -ForegroundColor Green
}

function Find-MySqlClient{
  $c=Get-Command mysql.exe -ErrorAction SilentlyContinue;if($c){return $c.Source}
  $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)})|Where-Object{$_}
  foreach($r in $roots){$c=Get-ChildItem (Join-Path $r 'MySQL') -Filter mysql.exe -File -Recurse -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){return $c.FullName}}
  return $null
}
function Ensure-MySqlDatabase($info){
  $client=Find-MySqlClient
  if(!$client){if($SkipMySqlProvisioning){Write-Warning 'mysql.exe not found; database provisioning skipped.';return};throw 'mysql.exe was not found. Install MySQL Server/Client or use -SkipMySqlProvisioning when the database already exists.'}
  if($info.Database -notmatch '^[A-Za-z0-9_]+$'){throw 'Unsafe MySQL database name.'}
  $adminPassword=if([string]::IsNullOrWhiteSpace($MySqlAdminPassword)){$MySqlPassword}else{$MySqlAdminPassword}
  if([string]::IsNullOrWhiteSpace($adminPassword)){if($SkipMySqlProvisioning){return};throw 'MySQL administrator password is required for first install.'}
  $old=$env:MYSQL_PWD
  try{$env:MYSQL_PWD=$adminPassword;$sql="CREATE DATABASE IF NOT EXISTS $($info.Database) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;";$output=$sql|& $client --protocol=TCP --host=$MySqlServer --port=$MySqlPort --user=$MySqlAdminUser --batch 2>&1;if($LASTEXITCODE -ne 0){throw ($output -join [Environment]::NewLine)};Write-Host "[OK] MySQL database ready: $($info.Database)" -ForegroundColor Green}
  finally{if($null -eq $old){Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue}else{$env:MYSQL_PWD=$old}}
}

function Reset-TestDatabase($info){
  if(!$RecreateTestDatabase -or $info.Name -ne 'Test'){return}
  $client=Find-MySqlClient
  if(!$client){throw 'mysql.exe is required to recreate the Test database.'}
  $dump=Join-Path (Split-Path $client -Parent) 'mysqldump.exe'
  if(!(Test-Path $dump)){$found=Get-Command mysqldump.exe -ErrorAction SilentlyContinue;if($found){$dump=$found.Source}}
  if(!(Test-Path $dump)){throw 'mysqldump.exe is required to back up ecomm_dev before recreation.'}
  $adminPassword=if([string]::IsNullOrWhiteSpace($MySqlAdminPassword)){$MySqlPassword}else{$MySqlAdminPassword}
  if([string]::IsNullOrWhiteSpace($adminPassword)){throw 'MySQL administrator password is required with -RecreateTestDatabase.'}
  $backupDir=Join-Path $InstallRoot 'db-backups';[void][IO.Directory]::CreateDirectory($backupDir)
  $backup=Join-Path $backupDir ("ecomm_dev-before-recreate-{0}.sql" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $old=$env:MYSQL_PWD
  try{
    $env:MYSQL_PWD=$adminPassword
    & $dump --protocol=TCP --host=$MySqlServer --port=$MySqlPort --user=$MySqlAdminUser --single-transaction --skip-lock-tables --default-character-set=utf8mb4 "--result-file=$backup" ecomm_dev
    if($LASTEXITCODE -ne 0 -or !(Test-Path $backup) -or (Get-Item $backup).Length -eq 0){throw 'Backup of ecomm_dev failed; the database was not changed.'}
    $sql="DROP DATABASE IF EXISTS ecomm_dev; CREATE DATABASE ecomm_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    $output=$sql|& $client --protocol=TCP --host=$MySqlServer --port=$MySqlPort --user=$MySqlAdminUser --batch 2>&1
    if($LASTEXITCODE -ne 0){throw ($output -join [Environment]::NewLine)}
    Write-Host "[OK] Test database recreated. Backup: $backup" -ForegroundColor Green
  }finally{if($null -eq $old){Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue}else{$env:MYSQL_PWD=$old}}
}

function Configure-UpdateTask($info){
  $taskName=if($info.Name -eq 'Test'){'iMonitorERP-Update-Test'}else{'iMonitorERP-Update-Production'}
  $updater=Join-Path $info.Root 'Update-iMonitorERP.ps1'
  try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
  try{Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}catch{}
  if($SkipTaskRegistration){return}
  if(!(Test-Path $updater)){throw "Updater script not found: $updater"}
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`""
  if($info.Name -eq 'Test'){
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
  }else{
    # Production is intentionally manual-only: the task has no recurring trigger and is started explicitly by /system/update.
    $trigger=$null
  }
  $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  if($trigger){
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force|Out-Null
    Write-Host "[OK] Test auto updater registered every 10 minutes: $taskName" -ForegroundColor Green
  }else{
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Principal $principal -Force|Out-Null
    Write-Host "[OK] Production updater registered as manual-only task: $taskName" -ForegroundColor Green
  }
}

function Write-LocalUpdater($info,[string]$Destination){
  function Q([string]$value){return "'"+$value.Replace("'","''")+"'"}
  $channelInstaller=Join-Path $Destination 'Install-iMonitorERP.ps1'
  if(!(Test-Path $channelInstaller)){Copy-Item $stableInstaller $channelInstaller -Force}
  $content=@"
[CmdletBinding()]
param([switch]`$Force)
`$ErrorActionPreference='Stop'
`$root=$(Q $info.Root)
`$rollback=`$root+'.rollback'
`$state=$(Q $info.State)
`$rollbackState=`$state+'.rollback'
`$port=$($info.Port)
`$hostHeader=$(Q $info.HostHeader)
function Test-Health {
  try{
    `$headers=@{};if(`$hostHeader){`$headers.Host=`$hostHeader}
    `$bindingPort=if(`$hostHeader){80}else{`$port}
    `$r=Invoke-WebRequest "http://127.0.0.1:`$bindingPort/health" -Headers `$headers -UseBasicParsing -TimeoutSec 8
    return `$r.StatusCode -eq 200
  }catch{return `$false}
}
# Automatic rollback is intentionally disabled. A failed version remains available for diagnostics.
# The previous files stay in the rollback directory and an administrator explicitly chooses a known-good release.
& $(Q $channelInstaller) -Channel $(Q $info.Name) -Mode UpdateOnly -InstallRoot $(Q $InstallRoot) -ConfigRoot $(Q $ConfigRoot) -TestFolderName $(Q $TestFolderName) -ProductionFolderName $(Q $ProductionFolderName) -TestPort $TestPort -ProductionPort $ProductionPort -TestHostHeader $(Q $TestHostHeader) -ProductionHostHeader $(Q $ProductionHostHeader) -TestPhysicalPath $(Q $TestPhysicalPath) -ProductionPhysicalPath $(Q $ProductionPhysicalPath) -SkipMySqlProvisioning -SkipTaskRegistration -Force:`$Force
"@
  Set-Content (Join-Path $Destination 'Update-iMonitorERP.ps1') $content -Encoding UTF8
}

function Invoke-RetryFileOp([scriptblock]$Action,[string]$Description,[int]$Attempts=12){
  for($i=1;$i -le $Attempts;$i++){try{& $Action;return}catch{if($i -eq $Attempts){throw "$Description failed after $Attempts attempts: $($_.Exception.Message)"};Start-Sleep -Milliseconds ([Math]::Min(5000,500*$i))}}
}
function Stop-ChannelHost($info){
  $offline=Join-Path $info.Root 'app_offline.htm'
  if(Test-Path $info.Root){Set-Content $offline 'iMonitor ERP is being updated.' -Encoding ASCII -ErrorAction SilentlyContinue}
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
  Get-Process w3wp,dotnet -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      $cmd=$_.Path
      # Only this channel's out-of-process host. This pool's w3wp workers were stopped above via appcmd;
      # killing every w3wp crashed the other ERP sites until IIS rapid-fail disabled their pools (503).
      if($cmd -and $cmd.StartsWith($info.Root,[StringComparison]::OrdinalIgnoreCase)){ Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    } catch {}
  }
  # A missing current directory is not a lock condition (common after an interrupted/legacy deployment).
  # Install-Channel will recreate it before activating the staged release.
  if(!(Test-Path $info.Root)){ return }
  for($i=0;$i -lt 20;$i++){Start-Sleep -Milliseconds 500;try{$probe=Join-Path $info.Root '.update-lock-probe';Set-Content $probe 'ok' -ErrorAction Stop;Remove-Item $probe -Force -ErrorAction Stop;break}catch{if($i -eq 19){throw "Application files are still locked after stopping IIS: $($_.Exception.Message)"}}}
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
  Write-Host "=== iMonitor iBOS $($info.Name) ===" -ForegroundColor Cyan
  Write-Host "[PROGRESS 2] Initialize installation and validate configuration"
  Write-Host "Folder=$($info.Folder) Port=$($info.Port) Database=$($info.Database) UpdateMode=$(if($info.Name -eq 'Test'){'AutoEvery10Minutes'}else{'ManualOnly'})"
  if(!(Test-Path $info.Config) -and $Mode -eq 'UpdateOnly'){Write-Warning "Config missing for $($info.Name); update skipped.";return}
  Normalize-ChannelConfig $info
  if(!$SkipMySqlProvisioning -and ![string]::IsNullOrWhiteSpace($MySqlPassword)){Ensure-MySqlDatabase $info}else{Write-Host '[DB] Existing MySQL is validated by application startup and /health.' -ForegroundColor DarkGray}
  Reset-TestDatabase $info
  $rel=Get-LatestRelease $info;$installed=if(Test-Path $info.State){(Get-Content $info.State -Raw).Trim()}else{''}
  if(!$Force -and $installed -eq $rel.Tag){Write-Host "Already current: $($rel.Tag)";return}
  $work=Join-Path $workRoot ('imonitor-'+$info.Key+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $work,(Split-Path $info.State -Parent)|Out-Null
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
    $packagedInstaller=Join-Path $stage 'Install-iMonitorERP.ps1'
    if(!(Test-Path $packagedInstaller)){Copy-Item $stableInstaller $packagedInstaller -Force}
    Write-LocalUpdater $info $stage
    Import-Module WebAdministration
    Write-Host "[PROGRESS 60] Stop IIS site and application pool"
    Stop-ChannelHost $info
    Write-Host "[PROGRESS 66] IIS stopped and application files unlocked"
    $backup=$info.Root+'.rollback';$rollbackState=$info.State+'.rollback'
    if(Test-Path $backup){Invoke-RetryFileOp {Remove-Item $backup -Recurse -Force -ErrorAction Stop} "Remove old rollback"}
    if(Test-Path $info.State){Copy-Item $info.State $rollbackState -Force}
    if(Test-Path $info.Root){
      [void][IO.Directory]::CreateDirectory($backup)
      Invoke-RetryFileOp {Copy-Item (Join-Path $info.Root '*') $backup -Recurse -Force -ErrorAction Stop} "Copy current version to rollback"
      Remove-Item (Join-Path $backup 'app_offline.htm') -Force -ErrorAction SilentlyContinue # taken after Stop-ChannelHost wrote it; a restore must not bring the 503 back
      Invoke-RetryFileOp {Get-ChildItem $info.Root -Force|Remove-Item -Recurse -Force -ErrorAction Stop} "Clear current version"
    }else{[void][IO.Directory]::CreateDirectory($info.Root)}
    $targetParent=Split-Path $info.Root -Parent
    if(![string]::IsNullOrWhiteSpace($targetParent)){[void][IO.Directory]::CreateDirectory($targetParent)}
    Write-Host "[PROGRESS 74] Copy and activate staged version"
    Invoke-RetryFileOp {Copy-Item (Join-Path $stage '*') $info.Root -Recurse -Force -ErrorAction Stop} "Activate staged version"
    Write-Host "[PROGRESS 82] New version files activated"
    # IIS config edits fail transiently (0x800710D8) while another install touches applicationHost.config.
    for($iisAttempt=1;$iisAttempt -le 4;$iisAttempt++){
    try{
      if(!(Test-Path "IIS:\AppPools\$($info.Pool)")){New-WebAppPool -Name $info.Pool|Out-Null}
      foreach($setting in @(@('managedRuntimeVersion',''),@('enable32BitAppOnWin64',$false),@('startMode','AlwaysRunning'),@('processModel.loadUserProfile',$true))){try{Set-ItemProperty "IIS:\AppPools\$($info.Pool)" -Name $setting[0] -Value $setting[1] -ErrorAction Stop}catch{Write-Warning "Optional AppPool setting $($setting[0]) skipped: $($_.Exception.Message)"}}
      $bindingPort=if([string]::IsNullOrWhiteSpace($info.HostHeader)){$info.Port}else{80}
      if(!(Test-Path "IIS:\Sites\$($info.Site)")){New-Website -Name $info.Site -PhysicalPath $info.Root -Port $bindingPort -HostHeader $info.HostHeader -ApplicationPool $info.Pool|Out-Null}else{Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name physicalPath -Value $info.Root;Set-ItemProperty "IIS:\Sites\$($info.Site)" -Name applicationPool -Value $info.Pool;Write-Host '[IIS] Existing bindings preserved; port/host header are configured on first site creation only.'}
      Write-Host "[PROGRESS 86] Start IIS site and application pool"
      Start-WebAppPool $info.Pool -ErrorAction SilentlyContinue;Start-Website $info.Site -ErrorAction SilentlyContinue
      break
    }catch{if($iisAttempt -eq 4){throw "IIS activation failed: $($_.Exception.Message)"};Write-Warning "IIS activation attempt $iisAttempt failed: $($_.Exception.Message)";Start-Sleep -Seconds (3*$iisAttempt)}
    }
    $headers=@{};if($info.HostHeader){$headers.Host=$info.HostHeader}
    $healthUrls=New-Object System.Collections.Generic.List[string]
    if($RuntimeHealthUrl){
      $explicit=$RuntimeHealthUrl.TrimEnd('/')
      if($explicit -notmatch '/health
    if($bindingPort -ne $info.Port){[void]$healthUrls.Add("http://127.0.0.1:$($info.Port)/health")}
    if($info.HostHeader){[void]$healthUrls.Add("http://$($info.HostHeader)/health")}
    }
    Write-Host "[PROGRESS 90] Verify runtime health"
    $lastHealthError=''
    $ok=$false
    for($i=1;$i -le 60 -and !$ok;$i++){
      Start-Sleep 2
      foreach($healthUrl in ($healthUrls|Select-Object -Unique)){
        try{
          $r=Invoke-WebRequest $healthUrl -Headers $headers -UseBasicParsing -TimeoutSec 8
          if($r.StatusCode -eq 200){$ok=$true;break}
          $lastHealthError="HTTP $($r.StatusCode) from $healthUrl"
        }catch{
          # Internal ERP bindings are HTTP. Never reinterpret a loopback HTTP failure
          # as HTTPS: doing so caused healthy IIS sites on ports 8080/8081 to be rolled
          # back with "underlying connection was closed" even though the app was up.
          $lastHealthError="$healthUrl -> $($_.Exception.Message)"
        }
      }
    }
    if(!$ok){
      $siteState='unknown';$poolState='unknown'
      try{$siteState=(Get-WebsiteState -Name $info.Site).Value}catch{}
      try{$poolState=(Get-WebAppPoolState -Name $info.Pool).Value}catch{}
      $eventHint=''
      try{
        $events=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddMinutes(-10)} -ErrorAction SilentlyContinue |
          Where-Object{$_.ProviderName -match 'IIS AspNetCore Module V2|IIS AspNetCore Module|Application Error|.NET Runtime'} |
          Where-Object{$_.Message -match [regex]::Escape($info.Root) -or $_.Message -match [regex]::Escape($info.Site)} |
          Select-Object -First 3
        if($events){$eventHint=($events|ForEach-Object{"[$($_.TimeCreated)] $($_.ProviderName): $($_.Message -replace '[\r\n]+',' ')"}) -join ' | '}
      }catch{}
      throw "Health check failed for $($info.Name) after deployment. Site=$siteState Pool=$poolState Port=$bindingPort Host='$($info.HostHeader)' LastError='$lastHealthError' EventLog='$eventHint'. Check $($info.Root)\logs and IIS logs."
    }
    # Keep one last-known-good rollback for Test. The scheduled updater checks health on every invocation
    # and can restore it if the newly activated application later becomes unhealthy.
    if($info.Name -ne 'Test' -and (Test-Path $backup)){Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue}
    Write-Host "[PROGRESS 100] Installation and health verification succeeded"
    Copy-Item (Join-Path $info.Root 'Install-iMonitorERP.ps1') $stableInstaller -Force
    Configure-UpdateTask $info
    Set-Content $info.State $rel.Tag -Encoding ASCII;Write-Host "[OK] $($rel.Tag) -> http://127.0.0.1:$($info.Port)/ ; DB=$($info.Database) ; Folder=$($info.Folder)" -ForegroundColor Green
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
try{
  Ensure-IisPrerequisites
  $selected=@();if($Channel -in @('Both','Test')){$selected+=Get-ChannelInfo 'Test'};if($Channel -in @('Both','Production')){$selected+=Get-ChannelInfo 'Production'}
  $channelErrors=@()
  foreach($i in $selected){
    try{Install-Channel $i}
    catch{
      $channelErrors += "$($i.Name): $($_.Exception.Message)"
      Write-Warning "$($i.Name) channel failed: $($_.Exception.Message)"
    }
  }
  if($channelErrors.Count -gt 0){throw ("One or more channels failed:" + [Environment]::NewLine + ($channelErrors -join [Environment]::NewLine))}
}
finally{if($installMutex){$installMutex.ReleaseMutex();$installMutex.Dispose()}}){$explicit+='/health'}
      if($explicit -notmatch '^https?://'){throw 'RuntimeHealthUrl must be HTTP(S)'}
      [void]$healthUrls.Add($explicit)
    }else{
    [void]$healthUrls.Add("http://127.0.0.1:$bindingPort/health")
    if($bindingPort -ne $info.Port){[void]$healthUrls.Add("http://127.0.0.1:$($info.Port)/health")}
    if($info.HostHeader){[void]$healthUrls.Add("http://$($info.HostHeader)/health")}
    Write-Host "[PROGRESS 90] Verify runtime health"
    $lastHealthError=''
    $ok=$false
    for($i=1;$i -le 60 -and !$ok;$i++){
      Start-Sleep 2
      foreach($healthUrl in ($healthUrls|Select-Object -Unique)){
        try{
          $r=Invoke-WebRequest $healthUrl -Headers $headers -UseBasicParsing -TimeoutSec 8
          if($r.StatusCode -eq 200){$ok=$true;break}
          $lastHealthError="HTTP $($r.StatusCode) from $healthUrl"
        }catch{
          # Internal ERP bindings are HTTP. Never reinterpret a loopback HTTP failure
          # as HTTPS: doing so caused healthy IIS sites on ports 8080/8081 to be rolled
          # back with "underlying connection was closed" even though the app was up.
          $lastHealthError="$healthUrl -> $($_.Exception.Message)"
        }
      }
    }
    if(!$ok){
      $siteState='unknown';$poolState='unknown'
      try{$siteState=(Get-WebsiteState -Name $info.Site).Value}catch{}
      try{$poolState=(Get-WebAppPoolState -Name $info.Pool).Value}catch{}
      $eventHint=''
      try{
        $events=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddMinutes(-10)} -ErrorAction SilentlyContinue |
          Where-Object{$_.ProviderName -match 'IIS AspNetCore Module V2|IIS AspNetCore Module|Application Error|.NET Runtime'} |
          Where-Object{$_.Message -match [regex]::Escape($info.Root) -or $_.Message -match [regex]::Escape($info.Site)} |
          Select-Object -First 3
        if($events){$eventHint=($events|ForEach-Object{"[$($_.TimeCreated)] $($_.ProviderName): $($_.Message -replace '[\r\n]+',' ')"}) -join ' | '}
      }catch{}
      throw "Health check failed for $($info.Name) after deployment. Site=$siteState Pool=$poolState Port=$bindingPort Host='$($info.HostHeader)' LastError='$lastHealthError' EventLog='$eventHint'. Check $($info.Root)\logs and IIS logs."
    }
    # Keep one last-known-good rollback for Test. The scheduled updater checks health on every invocation
    # and can restore it if the newly activated application later becomes unhealthy.
    if($info.Name -ne 'Test' -and (Test-Path $backup)){Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue}
    Write-Host "[PROGRESS 100] Installation and health verification succeeded"
    Copy-Item (Join-Path $info.Root 'Install-iMonitorERP.ps1') $stableInstaller -Force
    Configure-UpdateTask $info
    Set-Content $info.State $rel.Tag -Encoding ASCII;Write-Host "[OK] $($rel.Tag) -> http://127.0.0.1:$($info.Port)/ ; DB=$($info.Database) ; Folder=$($info.Folder)" -ForegroundColor Green
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
try{
  Ensure-IisPrerequisites
  $selected=@();if($Channel -in @('Both','Test')){$selected+=Get-ChannelInfo 'Test'};if($Channel -in @('Both','Production')){$selected+=Get-ChannelInfo 'Production'}
  $channelErrors=@()
  foreach($i in $selected){
    try{Install-Channel $i}
    catch{
      $channelErrors += "$($i.Name): $($_.Exception.Message)"
      Write-Warning "$($i.Name) channel failed: $($_.Exception.Message)"
    }
  }
  if($channelErrors.Count -gt 0){throw ("One or more channels failed:" + [Environment]::NewLine + ($channelErrors -join [Environment]::NewLine))}
}
finally{if($installMutex){$installMutex.ReleaseMutex();$installMutex.Dispose()}}