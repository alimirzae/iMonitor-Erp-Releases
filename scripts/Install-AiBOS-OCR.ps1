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
  $env:TESSDATA_PREFIX=$models
  & $exe $TestImage stdout -l fas+eng --psm 6 tsv
  if($LASTEXITCODE -ne 0){throw "OCR test failed: $LASTEXITCODE"}
  exit 0
}

function Download-WithProgress([string]$Url,[string]$Destination,[string]$Label,[int]$Stage) {
  Add-Type -AssemblyName System.Net.Http
  $handler=[System.Net.Http.HttpClientHandler]::new()
  $client=[System.Net.Http.HttpClient]::new($handler)
  $client.Timeout=[TimeSpan]::FromMinutes(8)
  $response=$null; $stream=$null; $file=$null
  try {
    Write-Output "OCR_STAGE:$Stage|$Label|Connecting to download host"
    $response=$client.GetAsync($Url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode()
    $total=$response.Content.Headers.ContentLength
    $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $file=[System.IO.File]::Create($Destination)
    $buffer=New-Object byte[] 65536
    [long]$received=0
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    $last=[System.Diagnostics.Stopwatch]::StartNew()
    while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
      $file.Write($buffer,0,$n); $received+=$n
      if($last.ElapsedMilliseconds -ge 750) {
        $pct=if($total -gt 0){[int][math]::Min(100,[math]::Floor($received*100.0/$total))}else{-1}
        $speed=[math]::Round($received/[math]::Max($sw.Elapsed.TotalSeconds,0.01)/1048576,2)
        Write-Output "OCR_DOWNLOAD:$Stage|$Label|$pct|$received|$(if($total){$total}else{0})|$speed"
        $last.Restart()
      }
    }
    $file.Flush()
    Write-Output "OCR_DOWNLOAD:$Stage|$Label|100|$received|$(if($total){$total}else{0})|0"
    if($total -gt 0 -and $received -ne $total){throw "Incomplete download for $Label"}
  }finally {
    if($file){$file.Dispose()};if($stream){$stream.Dispose()}
    if($response){$response.Dispose()};$client.Dispose();$handler.Dispose()
  }
}

Write-Output 'OCR_STAGE:20|Preparation|Checking folders and engine'
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
    Write-Output 'OCR_STAGE:30|Download Tesseract|Downloading verified installer'
    $temp="$package.download"
    try{
      Download-WithProgress -Url $url -Destination $temp -Label 'Tesseract' -Stage 30
      $actual=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
      if($actual -ne $expectedHash){throw "Tesseract installer SHA256 mismatch. Actual: $actual"}
      Move-Item -LiteralPath $temp -Destination $package -Force
    }finally{Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}
  }
  Write-Output 'OCR_STAGE:55|Install Tesseract|Running silent installer'
  Write-Host "Installing verified Tesseract package $version without winget..."
  $process=Start-Process -FilePath $package -ArgumentList '/S' -PassThru -Wait
  if($process.ExitCode -ne 0){throw "Tesseract installer exit code: $($process.ExitCode)"}
  $exe=Get-OcrExe
  if(!$exe){throw 'Installer finished but tesseract.exe was not found in Program Files'}
}

foreach($lang in @('fas','eng')){
  Write-Output "OCR_STAGE:75|Download language models|Checking language model $lang"
  $dest=Join-Path $models "$lang.traineddata"
  if((Test-Path $dest) -and (Get-Item $dest).Length -gt 100000){continue}
  $url="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/$lang.traineddata"
  $tmp="$dest.download"
  Download-WithProgress -Url $url -Destination $tmp -Label "Model-$lang" -Stage 75
  if((Get-Item $tmp).Length -lt 100000){throw "Downloaded $lang model is unexpectedly small"}
  Move-Item -Force $tmp $dest
}
Write-Output 'OCR_STAGE:92|Health check|Verifying engine and language models'
$env:TESSDATA_PREFIX=$models
& $exe --list-langs | Out-Null
if($LASTEXITCODE -ne 0){throw 'Tesseract health check failed'}
[pscustomobject]@{installed=$true;executable=$exe;tessdata=$models;languages=@('fas','eng')}|ConvertTo-Json -Compress
