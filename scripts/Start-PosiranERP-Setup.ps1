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
$zip = Join-Path $root 'PosiranERP-Setup-win-x64.zip'
$sha = "$zip.sha256"
$repo='alimirzae/iMonitor-Erp-Releases'
$tag='posiran-installer-preview'

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

function Get-ReleaseAsset([string]$Name){
  $uri="https://api.github.com/repos/$repo/releases/tags/$tag"
  $headers=@{'User-Agent'='PosiranERP-Setup-Bootstrap/1.0';'Accept'='application/vnd.github+json';'Cache-Control'='no-cache'}
  $release=Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 60
  $asset=$release.assets|Where-Object{$_.name -eq $Name}|Select-Object -First 1
  if(!$asset){throw "Release asset not found: $Name"}
  return $asset
}

function Get-Asset([object]$Asset,[string]$Out,[int]$TimeoutSeconds=300){
  $errors=New-Object System.Collections.Generic.List[string]
  try{
    Write-Host "Downloading $($Asset.name) through GitHub API / HttpClient..." -ForegroundColor Cyan
    Invoke-HttpDownload ([string]$Asset.url) $Out 'application/octet-stream' $TimeoutSeconds
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("HttpClient API: $($_.Exception.Message)")}
  try{
    Write-Host 'Trying Windows BITS fallback...' -ForegroundColor Yellow
    Invoke-BitsDownload ([string]$Asset.browser_download_url) $Out
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("BITS: $($_.Exception.Message)")}
  try{
    Write-Host 'Trying Invoke-WebRequest fallback...' -ForegroundColor Yellow
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$Asset.browser_download_url) -OutFile $Out -TimeoutSec $TimeoutSeconds -Headers @{'User-Agent'='PosiranERP-Setup-Bootstrap/1.0';'Cache-Control'='no-cache'}
    if((Test-Path $Out) -and (Get-Item $Out).Length -gt 0){return}
  }catch{$errors.Add("Invoke-WebRequest: $($_.Exception.Message)")}
  throw "All native download methods failed for $($Asset.name)`n$($errors -join "`n")"
}

Write-Host 'Downloading latest Posiran ERP Setup...' -ForegroundColor Cyan
$zipAsset=Get-ReleaseAsset 'PosiranERP-Setup-win-x64.zip'
$shaAsset=Get-ReleaseAsset 'PosiranERP-Setup-win-x64.zip.sha256'
Get-Asset $shaAsset $sha 60
$expected=((Get-Content $sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
if($expected -notmatch '^[a-f0-9]{64}$'){throw 'Downloaded checksum file is invalid.'}

$useCached=$false
if(Test-Path $zip){
  try{
    $cachedHash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if($cachedHash -eq $expected){$useCached=$true;Write-Host 'Using verified cached Setup package.' -ForegroundColor Green}
  }catch{}
}
if(-not $useCached){Get-Asset $zipAsset $zip 600}
$actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if($expected -ne $actual){ throw "SHA256 mismatch. expected=$expected actual=$actual" }

$extract = Join-Path $root 'current'

Get-Process -Name 'PosiranERP.Setup' -ErrorAction SilentlyContinue | ForEach-Object {
  try {
    $processPath = $_.Path
    if([string]::IsNullOrWhiteSpace($processPath) -or $processPath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Host "Stopping previous Posiran ERP Setup process (PID $($_.Id))..." -ForegroundColor Yellow
      Stop-Process -Id $_.Id -Force -ErrorAction Stop
      $_.WaitForExit(5000) | Out-Null
    }
  } catch {
    Write-Warning "Could not stop previous Setup process PID $($_.Id): $($_.Exception.Message)"
  }
}
Start-Sleep -Milliseconds 500

if(Test-Path $extract){ Remove-Item $extract -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
Expand-Archive $zip -DestinationPath $extract -Force
$exe = Join-Path $extract 'PosiranERP.Setup.exe'
if(!(Test-Path $exe)){ throw 'PosiranERP.Setup.exe was not found after extraction.' }

Start-Process -FilePath $exe -WorkingDirectory $extract -Verb RunAs

$ready=$false
for($i=0;$i -lt 20;$i++){
  Start-Sleep -Milliseconds 500
  try {
    $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8099/health' -TimeoutSec 2
    if($r.StatusCode -eq 200){$ready=$true;break}
  } catch {}
}
if(-not $ready){ throw 'Posiran ERP Setup did not become healthy on http://127.0.0.1:8099/health' }

Start-Process 'http://127.0.0.1:8099/'
Write-Host 'Posiran ERP Setup started on http://127.0.0.1:8099/' -ForegroundColor Green
