[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'PowerShell را با Run as Administrator اجرا کنید.'
}

$root = Join-Path $env:ProgramData 'PosiranERP\Setup'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$zip = Join-Path $root 'PosiranERP-Setup-win-x64.zip'
$sha = "$zip.sha256"
$releaseBase = 'https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/posiran-installer-preview'

function Get-File([string]$Url,[string]$Out){
  $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $downloadUrl = "${Url}?cb=$cacheBust"
  & curl.exe -4 --http1.1 --fail --location --silent --show-error --connect-timeout 10 --retry 4 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $downloadUrl -o $Out
  if($LASTEXITCODE -ne 0){ throw "Download failed: $Url" }
}

Write-Host 'Downloading latest Posiran ERP Setup...' -ForegroundColor Cyan
Get-File "$releaseBase/PosiranERP-Setup-win-x64.zip" $zip
Get-File "$releaseBase/PosiranERP-Setup-win-x64.zip.sha256" $sha
$expected=((Get-Content $sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if($expected -ne $actual){ throw "SHA256 mismatch. expected=$expected actual=$actual" }

$extract = Join-Path $root 'current'
if(Test-Path $extract){ Remove-Item $extract -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
Expand-Archive $zip -DestinationPath $extract -Force
$exe = Join-Path $extract 'PosiranERP.Setup.exe'
if(!(Test-Path $exe)){ throw 'PosiranERP.Setup.exe was not found after extraction.' }
Start-Process -FilePath $exe -Verb RunAs
Start-Sleep -Seconds 2
Start-Process 'http://127.0.0.1:8099/'
Write-Host 'Posiran ERP Setup started on http://127.0.0.1:8099/' -ForegroundColor Green
