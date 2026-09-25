[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$repo='alimirzae/iMonitor-Erp-Releases'
$tag='imonitor-installer-preview'
$name='iMonitorERP-Setup-win-x64.zip'
$shaName="$name.sha256"
$work=Join-Path $env:TEMP 'iMonitorERP-WebSetup'
New-Item -ItemType Directory -Force -Path $work|Out-Null
$zip=Join-Path $work $name
$shaFile=Join-Path $work $shaName

function Download([string]$url,[string]$dest){
  Remove-Item $dest -Force -ErrorAction SilentlyContinue
  try{
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $url -Destination $dest -ErrorAction Stop
    return
  }catch{}
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest -Headers @{'Cache-Control'='no-cache'}
}

$base="https://github.com/$repo/releases/download/$tag"
Write-Host 'Downloading latest iMonitor ERP Setup...' -ForegroundColor Cyan
Download "$base/$shaName" $shaFile
$expected=((Get-Content $shaFile -Raw).Trim().Split(' ')[0]).ToLowerInvariant()
$valid=(Test-Path $zip) -and ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected)
if(!$valid){Download "$base/$name" $zip}
$actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if($actual -ne $expected){throw "Setup checksum mismatch. expected=$expected actual=$actual"}

$extract=Join-Path $work 'current'
if(Test-Path $extract){Remove-Item $extract -Recurse -Force}
Expand-Archive $zip -DestinationPath $extract -Force
$exe=Join-Path $extract 'iMonitorERP.Setup.exe'
if(!(Test-Path $exe)){throw 'iMonitorERP.Setup.exe missing from setup package.'}
Start-Process -FilePath $exe -Verb RunAs
Write-Host 'iMonitor ERP Setup started on http://127.0.0.1:8099/' -ForegroundColor Green
