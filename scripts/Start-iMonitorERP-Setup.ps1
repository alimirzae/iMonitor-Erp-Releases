[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'PowerShell را با Run as Administrator اجرا کنید.'
}

[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$root = Join-Path $env:ProgramData 'PosiranERP\Setup'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$zip = Join-Path $root 'ERP-Deployment-Manager-win-x64.zip'
$sha = "$zip.sha256"
$repo='alimirzae/iMonitor-Erp-Releases'
$tag='erp-deployment-manager'

function Invoke-HttpDownload([string]$Url,[string]$Out,[string]$Accept='application/octet-stream',[int]$TimeoutSeconds=300){
  $handler=New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect=$true
  $handler.AutomaticDecompression=[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
  $client=New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('PosiranERP-Setup-Bootstrap/1.0')
  $client.DefaultRequestHeaders.CacheControl=New-Object System.Net.Http.Headers.CacheControlHeaderValue
  $client.DefaultRequestHeaders.CacheControl.NoCache=$true
  if(-not [string]::IsNullOrWhiteSpace($Accept)){$client.DefaultRequestHeaders.Accept.ParseAdd($Accept)}
  $stream=$null;$file=$null;$response=$null
  try{
    $response=$client.GetAsync($Url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    [void]$response.EnsureSuccessStatusCode()
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
  Start-BitsTransfer -Source $Url -Destination $Out -TransferType Download -DisplayName 'Posiran ERP Setup' -Description 'Downloading Posiran ERP Setup' -ErrorAction Stop
}

function Get-DirectAssetUrl([string]$Name){
  return "https://github.com/$repo/releases/download/$tag/$Name"
}

function Get-DirectAsset([string]$Name,[string]$Out,[int]$TimeoutSeconds=300){
  $url=Get-DirectAssetUrl $Name
  $errors=New-Object System.Collections.Generic.List[string]
  try{
    Write-Host "Downloading $Name from direct GitHub release URL..." -ForegroundColor Cyan
    Invoke-HttpDownload $url $Out 'application/octet-stream' $TimeoutSeconds
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("HttpClient direct: $($_.Exception.Message)")}
  try{
    Write-Host 'Trying Windows BITS fallback...' -ForegroundColor Yellow
    Invoke-BitsDownload $url $Out
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("BITS direct: $($_.Exception.Message)")}
  try{
    Write-Host 'Trying Invoke-WebRequest fallback...' -ForegroundColor Yellow
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $Out -TimeoutSec $TimeoutSeconds -Headers @{'User-Agent'='PosiranERP-Setup-Bootstrap/1.1';'Cache-Control'='no-cache'}
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("Invoke-WebRequest direct: $($_.Exception.Message)")}
  throw ("All native download methods failed for {0}: {1}" -f $Name,($errors -join '; '))
}

Write-Host 'Downloading latest iBOS Deployment Manager...' -ForegroundColor Cyan
# Release assets are replaced separately. Never trust a ZIP/checksum pair obtained across a release update.
$verified=$false
for($attempt=1;$attempt -le 5;$attempt++){
  Write-Host "Checking coherent Setup release asset pair (attempt $attempt/5)..." -ForegroundColor Cyan
  Get-DirectAsset 'ERP-Deployment-Manager-win-x64.zip.sha256' $sha 60
  $expected=((Get-Content $sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
  if($expected -notmatch '^[a-f0-9]{64}$'){throw 'Downloaded checksum file is invalid.'}
  $useCached=$false
  if(Test-Path $zip){
    $cachedHash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if($cachedHash -eq $expected){$useCached=$true}
  }
  if(-not $useCached){
    $candidate="$zip.download"
    try{
      Get-DirectAsset 'ERP-Deployment-Manager-win-x64.zip' $candidate 600
      $actual=(Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
      if($expected -eq $actual){Move-Item -LiteralPath $candidate -Destination $zip -Force}
    }finally{Remove-Item $candidate -Force -ErrorAction SilentlyContinue}
  }else{$actual=$expected}
  if($expected -eq $actual){$verified=$true;break}
  Write-Warning "Setup release ZIP and SHA256 currently disagree: expected=$expected actual=$actual. Will fetch a fresh pair."
  if($attempt -lt 5){Start-Sleep -Seconds ([math]::Min(3*$attempt,12))}
}
if(-not $verified){
  throw 'Could not obtain a matching verified Setup ZIP/checksum after five attempts. Release may be publishing or CDN caches are inconsistent; installation was safely aborted.'
}
Write-Host "Verified Setup package SHA256: $expected" -ForegroundColor Green

$serviceName='ERPDeploymentManager'
$managerRoot=Join-Path $env:ProgramData 'iMonitor\ERPDeploymentManager'
$serviceDir=Join-Path $managerRoot 'current'
$stagingDir=Join-Path $managerRoot ('staging-'+[guid]::NewGuid().ToString('N'))
$previousDir=Join-Path $managerRoot 'previous'
New-Item -ItemType Directory -Force -Path $managerRoot | Out-Null

# Never extract over a running service. Prepare and validate the new manager in staging first.
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
try {
  Expand-Archive $zip -DestinationPath $stagingDir -Force
  $stagedExe=Join-Path $stagingDir 'PosiranERP.Setup.exe'
  if(!(Test-Path $stagedExe)){throw 'iBOS Deployment Manager executable was not found after extraction.'}

  $existing=Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if($existing){
    Write-Host 'Stopping iBOS Deployment Manager for self-update...' -ForegroundColor Cyan
    Stop-Service -Name $serviceName -Force -ErrorAction Stop
    $existing.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30))
  }

  # Give Windows a short moment to release executable/DLL handles.
  $unlocked=$false
  for($i=0;$i -lt 20;$i++){
    try{
      if(Test-Path $serviceDir){
        $probe=Join-Path $serviceDir '.upgrade-write-test'
        [IO.File]::WriteAllText($probe,'ok');Remove-Item $probe -Force
      }
      $unlocked=$true;break
    }catch{Start-Sleep -Milliseconds 500}
  }
  if(-not $unlocked){throw 'ERP Deployment Manager files are still locked after stopping the service.'}

  if(Test-Path $previousDir){Remove-Item $previousDir -Recurse -Force}
  if(Test-Path $serviceDir){Move-Item $serviceDir $previousDir -Force}
  Move-Item $stagingDir $serviceDir -Force
  $exe=Join-Path $serviceDir 'PosiranERP.Setup.exe'

  if(-not $existing){
    $bin='"'+$exe+'"'
    sc.exe create $serviceName binPath= $bin start= auto DisplayName= "iBOS Deployment Manager" | Out-Null
  } else {
    $bin='"'+$exe+'"'
    sc.exe config $serviceName binPath= $bin start= auto | Out-Null
  }
  sc.exe description $serviceName "Localhost-only iBOS install, update, version health and deployment manager on 127.0.0.1:8099" | Out-Null
  sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
  Start-Service -Name $serviceName

  $ready=$false
  for($i=0;$i -lt 40;$i++){
    Start-Sleep -Milliseconds 500
    try{$r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8099/health' -TimeoutSec 2;if($r.StatusCode -eq 200){$ready=$true;break}}catch{}
  }
  if(-not $ready){
    Write-Warning 'New Deployment Manager failed health check; rolling back the manager itself.'
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $failedDir=Join-Path $managerRoot ('failed-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    if(Test-Path $serviceDir){Move-Item $serviceDir $failedDir -Force}
    if(Test-Path $previousDir){
      Move-Item $previousDir $serviceDir -Force
      $exe=Join-Path $serviceDir 'PosiranERP.Setup.exe'
      $bin='"'+$exe+'"';sc.exe config $serviceName binPath= $bin start= auto | Out-Null
      Start-Service -Name $serviceName
      throw 'New iBOS Deployment Manager was unhealthy and the previous manager was restored.'
    }
    throw 'iBOS Deployment Manager did not become healthy and no previous manager was available.'
  }
  if(Test-Path $previousDir){Remove-Item $previousDir -Recurse -Force -ErrorAction SilentlyContinue}
}
finally {
  if(Test-Path $stagingDir){Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue}
}

Start-Process 'http://127.0.0.1:8099/'
Write-Host 'iBOS Deployment Manager Windows Service is running on http://127.0.0.1:8099/' -ForegroundColor Green