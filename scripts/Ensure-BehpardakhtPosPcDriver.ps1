[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$TargetRoot,
  [string]$CacheRoot=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$version='1.4.48'
$expectedSha='f691da423cae1052f3c867a327109d18117128ee24098ae4aefa13408e52d5b6'
$relative='DeviceDrivers\pos\behpardakht-pospc-1.4.48\POS_PC.dll'
$target=Join-Path $TargetRoot $relative
$targetDir=Split-Path $target -Parent
$repoRoot=Split-Path $PSScriptRoot -Parent
$payloadDir=Join-Path $repoRoot 'drivers\behpardakht-pospc-1.4.48'

function Assert-Driver([string]$Path){
  if(!(Test-Path $Path)){return $false}
  $sha=(Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if($sha -ne $expectedSha){return $false}
  $fv=[System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion
  return (-not [string]::IsNullOrWhiteSpace($fv)) -and $fv.StartsWith('1.4.48')
}

if(Assert-Driver $target){
  Unblock-File $target -ErrorAction SilentlyContinue
  Write-Host "[PCPOS] Verified POS_PC $version already present: $target" -ForegroundColor Green
  exit 0
}

if(-not [string]::IsNullOrWhiteSpace($CacheRoot)){
  $cache=Join-Path $CacheRoot 'behpardakht-pospc-1.4.48\POS_PC.dll'
  if(Assert-Driver $cache){
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    Copy-Item $cache $target -Force
    Unblock-File $target -ErrorAction SilentlyContinue
    Write-Host "[PCPOS] Restored POS_PC $version from verified cache." -ForegroundColor Green
    exit 0
  }
}

$parts=1..8 | ForEach-Object { Join-Path $payloadDir ('POS_PC.dll.gz.b64.part{0:d2}' -f $_) }
$missing=$parts | Where-Object { !(Test-Path $_) }
if($missing){throw "Missing Behpardakht driver payload part(s): $($missing -join ', ')"}

$b64=($parts | ForEach-Object { (Get-Content $_ -Raw).Trim() }) -join ''
if($b64.Length -ne 41632){throw "Payload length mismatch. expected=41632 actual=$($b64.Length)"}

$compressed=[Convert]::FromBase64String($b64)
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
$input=New-Object System.IO.MemoryStream(,$compressed)
$gzip=New-Object System.IO.Compression.GZipStream($input,[System.IO.Compression.CompressionMode]::Decompress)
$output=[System.IO.File]::Open($target,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
try{$gzip.CopyTo($output)}finally{$output.Dispose();$gzip.Dispose();$input.Dispose()}

if(-not (Assert-Driver $target)){
  $actual=if(Test-Path $target){(Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()}else{'missing'}
  Remove-Item $target -Force -ErrorAction SilentlyContinue
  throw "Reconstructed Behpardakht POS_PC validation failed. SHA256=$actual"
}

Unblock-File $target -ErrorAction SilentlyContinue
Remove-Item ($target+':Zone.Identifier') -Force -ErrorAction SilentlyContinue

if(-not [string]::IsNullOrWhiteSpace($CacheRoot)){
  $cache=Join-Path $CacheRoot 'behpardakht-pospc-1.4.48\POS_PC.dll'
  New-Item -ItemType Directory -Force -Path (Split-Path $cache -Parent) | Out-Null
  Copy-Item $target $cache -Force
  Unblock-File $cache -ErrorAction SilentlyContinue
}

Write-Host "[OK] Behpardakht POS_PC $version -> $target" -ForegroundColor Green
Write-Host "[OK] SHA256=$expectedSha" -ForegroundColor Green
