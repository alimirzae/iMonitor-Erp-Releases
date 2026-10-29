#Requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$Status,
  [string]$TestImage,
  [string]$Root = "$env:ProgramData\AiBOS\OCR"
)
$ErrorActionPreference='Stop'
$models=Join-Path $Root 'tessdata'
$exeCandidates=@((Join-Path $Root 'tesseract.exe'),"$env:ProgramFiles\Tesseract-OCR\tesseract.exe","$env:ProgramFiles(x86)\Tesseract-OCR\tesseract.exe")
function Get-OcrExe {
  foreach($p in $exeCandidates) { if($p -and (Test-Path $p)){return $p} }
  $cmd=Get-Command tesseract.exe -ErrorAction SilentlyContinue
  if($cmd){return $cmd.Source}
  return $null
}
function Assert-Ready {
  $exe=Get-OcrExe
  if(!$exe){throw 'Tesseract executable not found'}
  foreach($lang in @('fas','eng')) {
    if(!(Test-Path (Join-Path $models "$lang.traineddata"))){throw "Missing $lang model"}
  }
  return $exe
}
if($Status) {
  $exe=Get-OcrExe
  [pscustomobject]@{ installed=[bool]($exe -and (Test-Path (Join-Path $models 'fas.traineddata')) -and (Test-Path (Join-Path $models 'eng.traineddata'))); executable=$exe; tessdata=$models }|ConvertTo-Json -Compress
  exit 0
}
if($TestImage) {
  $exe=Assert-Ready
  if(!(Test-Path -LiteralPath $TestImage -PathType Leaf)){throw 'Test image not found'}
  $env:TESSDATA_PREFIX=$Root
  & $exe $TestImage stdout -l fas+eng --psm 6 tsv
  if($LASTEXITCODE -ne 0){throw "OCR test failed: $LASTEXITCODE"}
  exit 0
}
New-Item -ItemType Directory -Force -Path $models | Out-Null
$exe=Get-OcrExe
if(!$exe){
  $winget=Get-Command winget.exe -ErrorAction SilentlyContinue
  if(!$winget){throw 'winget is unavailable. Install Tesseract OCR for Windows once and retry.'}
  & $winget.Source install --id UB-Mannheim.TesseractOCR --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
  if($LASTEXITCODE -ne 0){throw "winget Tesseract installation failed: $LASTEXITCODE"}
  $exe=Get-OcrExe
  if(!$exe){throw 'Tesseract was installed but executable could not be located'}
}
foreach($lang in @('fas','eng')){
  $dest=Join-Path $models "$lang.traineddata"
  if((Test-Path $dest) -and (Get-Item $dest).Length -gt 100000){continue}
  $url="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/$lang.traineddata"
  $tmp="$dest.download"
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
  if((Get-Item $tmp).Length -lt 100000){throw "Downloaded $lang model is unexpectedly small"}
  Move-Item -Force $tmp $dest
}
$env:TESSDATA_PREFIX=$Root
& $exe --list-langs | Out-Null
if($LASTEXITCODE -ne 0){throw 'Tesseract health check failed'}
[pscustomobject]@{installed=$true;executable=$exe;tessdata=$models;languages=@('fas','eng')}|ConvertTo-Json -Compress
