#Requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$Status,
  [string]$TestImage,
  [string]$Root = "$env:ProgramData\AiBOS\OCR"
)
$ErrorActionPreference='Stop'
$models=Join-Path $Root 'tessdata'
$exeCandidates=@((Join-Path $Root 'tesseract.exe'),"$env:ProgramFiles\Tesseract-OCR\tesseract.exe","${env:ProgramFiles(x86)}\Tesseract-OCR\tesseract.exe")
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
Write-Output 'OCR_STAGE:20|آماده‌سازی|بررسی پوشه‌ها و موتور نصب‌شده'
New-Item -ItemType Directory -Force -Path $models | Out-Null
$exe=Get-OcrExe
if(!$exe){
  # Pinned UB Mannheim release from Microsoft winget-pkgs; no winget executable required.
  $version='5.4.0.20240606'
  $expectedHash='C885FFF6998E0608BA4BB8AB51436E1C6775C2BAFC2559A19B423E18678B60C9'
  $url="https://github.com/UB-Mannheim/tesseract/releases/download/v$version/tesseract-ocr-w64-setup-$version.exe"
  $cache=Join-Path $Root 'packages'
  New-Item -ItemType Directory -Force -Path $cache | Out-Null
  $package=Join-Path $cache "tesseract-ocr-w64-setup-$version.exe"
  $valid=(Test-Path $package) -and ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -eq $expectedHash)
  if(!$valid){
    Write-Output 'OCR_STAGE:30|دانلود Tesseract|دریافت فایل نصب؛ این مرحله ممکن است طولانی باشد'
    $temp="$package.download"
    try{
      Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec 300
      $actual=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
      if($actual -ne $expectedHash){throw "Tesseract installer SHA256 mismatch. Actual: $actual"}
      Move-Item -LiteralPath $temp -Destination $package -Force
    }finally{Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}
  }
  Write-Output 'OCR_STAGE:55|نصب Tesseract|اجرای نصاب بی‌صدا'
  Write-Host "Installing verified Tesseract package $version without winget..."
  $process=Start-Process -FilePath $package -ArgumentList '/S' -PassThru -Wait
  if($process.ExitCode -ne 0){throw "Tesseract installer exit code: $($process.ExitCode)"}
  $exe=Get-OcrExe
  if(!$exe){throw 'Installer finished but tesseract.exe was not found in Program Files'}
}

foreach($lang in @('fas','eng')){
  Write-Output "OCR_STAGE:75|دریافت مدل‌ها|بررسی مدل زبان $lang"
  $dest=Join-Path $models "$lang.traineddata"
  if((Test-Path $dest) -and (Get-Item $dest).Length -gt 100000){continue}
  $url="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/$lang.traineddata"
  $tmp="$dest.download"
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
  if((Get-Item $tmp).Length -lt 100000){throw "Downloaded $lang model is unexpectedly small"}
  Move-Item -Force $tmp $dest
}
Write-Output 'OCR_STAGE:92|سلامت‌سنجی|بررسی اجرا و مدل‌های OCR'
$env:TESSDATA_PREFIX=$Root
& $exe --list-langs | Out-Null
if($LASTEXITCODE -ne 0){throw 'Tesseract health check failed'}
[pscustomobject]@{installed=$true;executable=$exe;tessdata=$models;languages=@('fas','eng')}|ConvertTo-Json -Compress
