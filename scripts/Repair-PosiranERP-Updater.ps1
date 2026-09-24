[CmdletBinding()]
param(
  [ValidateSet('Both','Test','Production')][string]$Channel='Both',
  [string]$InstallRoot='C:\PosiranERP',
  [string]$ConfigRoot='C:\Deploy\PosiranERP',
  [string]$TestFolderName='test',
  [string]$ProductionFolderName='production',
  [int]$TestPort=8082,
  [int]$ProductionPort=8083
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'Run PowerShell as Administrator.'
}

[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$base='https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main'
$installerDir=Join-Path $InstallRoot 'installer'
$installer=Join-Path $installerDir 'Install-PosiranERP-v1.0.5.ps1'
New-Item -ItemType Directory -Force -Path $installerDir | Out-Null

Write-Host '[Repair] Downloading canonical Posiran ERP installer...' -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing -Uri "$base/scripts/Install-PosiranERP-v1.0.5.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -OutFile $installer -TimeoutSec 120

$targets=if($Channel -eq 'Both'){@('Test','Production')}else{@($Channel)}
foreach($target in $targets){
  $folder=if($target -eq 'Test'){$TestFolderName}else{$ProductionFolderName}
  $root=Join-Path (Join-Path $InstallRoot $folder) 'current'
  $task=if($target -eq 'Test'){'PosiranERP-Update-Test'}else{'PosiranERP-Update-Production'}
  Write-Host "[Repair] $target root=$root task=$task" -ForegroundColor Cyan
  if(!(Test-Path $root)){
    Write-Warning "$target is not installed at $root; skipping."
    continue
  }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel $target -Mode UpdateOnly -InstallRoot $InstallRoot -ConfigRoot $ConfigRoot -TestFolderName $TestFolderName -ProductionFolderName $ProductionFolderName -TestPort $TestPort -ProductionPort $ProductionPort
  if($LASTEXITCODE -ne 0){throw "$target updater repair failed with exit code $LASTEXITCODE"}

  $updater=Join-Path $root 'Update-PosiranERP.ps1'
  if(!(Test-Path $updater)){throw "$target local updater is still missing: $updater"}
  if(!(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)){throw "$target scheduled updater task is still missing: $task"}
  Write-Host "[OK] $target updater repaired: $updater / $task" -ForegroundColor Green
}

Write-Host '[OK] Posiran ERP updater repair completed.' -ForegroundColor Green
