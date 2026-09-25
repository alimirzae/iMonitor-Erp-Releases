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

Write-Host 'Downloading latest ERP Deployment Manager...' -ForegroundColor Cyan
Get-DirectAsset 'ERP-Deployment-Manager-win-x64.zip.sha256' $sha 60
$expected=((Get-Content $sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
if($expected -notmatch '^[a-f0-9]{64}$'){throw 'Downloaded checksum file is invalid.'}

$useCached=$false
if(Test-Path $zip){
  try{
    $cachedHash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if($cachedHash -eq $expected){
      $useCached=$true
      Write-Host 'Using verified cached Setup shell. ERP Test/Production packages are checked separately inside Setup.' -ForegroundColor Green
    }
  }catch{}
}
if(-not $useCached){
  Write-Host 'Cached Setup is missing or outdated; downloading the current Setup package.' -ForegroundColor Cyan
  Get-DirectAsset 'ERP-Deployment-Manager-win-x64.zip' $zip 600
}
$actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if($expected -ne $actual){ throw "SHA256 mismatch. expected=$expected actual=$actual" }


$serviceName='ERPDeploymentManager'
$serviceDir=Join-Path $env:ProgramData 'iMonitor\ERPDeploymentManager\current'
if(Test-Path $serviceDir){Remove-Item $serviceDir -Recurse -Force}
New-Item -ItemType Directory -Force -Path $serviceDir | Out-Null
Expand-Archive $zip -DestinationPath $serviceDir -Force
$exe=Join-Path $serviceDir 'PosiranERP.Setup.exe'
if(!(Test-Path $exe)){throw 'ERP Deployment Manager executable was not found after extraction.'}

$existing=Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if($existing){
  try{Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue}catch{}
  sc.exe delete $serviceName | Out-Null
  Start-Sleep -Seconds 1
}
$bin='"'+$exe+'"'
sc.exe create $serviceName binPath= $bin start= auto DisplayName= "ERP Deployment Manager" | Out-Null
sc.exe description $serviceName "Localhost-only ERP install, update, health and rollback manager on 127.0.0.1:8099" | Out-Null
sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
Start-Service -Name $serviceName

$ready=$false
for($i=0;$i -lt 20;$i++){
  Start-Sleep -Milliseconds 500
  try {
    $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8099/health' -TimeoutSec 2
    if($r.StatusCode -eq 200){$ready=$true;break}
  } catch {}
}
if(-not $ready){ throw 'ERP Deployment Manager did not become healthy on http://127.0.0.1:8099/health' }

Start-Process 'http://127.0.0.1:8099/'
Write-Host 'ERP Deployment Manager Windows Service is running on http://127.0.0.1:8099/' -ForegroundColor Green
