[CmdletBinding()]
param(
  [ValidateSet('Both','Test','Production')][string]$Channel='Both',
  [switch]$Force,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$InstallerArguments
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$version='2.1.5'
$file="Install-iMonitorERP-v$version.ps1"
$work=Join-Path $env:TEMP 'iMonitorERP-Setup'
New-Item -ItemType Directory -Force -Path $work|Out-Null
$target=Join-Path $work $file
$urls=@(
  "https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/imonitor-erp-installer-v$version/$file",
  "https://testerp.imonitor.ir/downloads/installers/$file"
)

function Test-ValidDownload([string]$Path){
  return (Test-Path $Path) -and (Get-Item $Path).Length -gt 10000
}

$errors=@()
$downloaded=$false
foreach($url in $urls){
  Remove-Item $target -Force -ErrorAction SilentlyContinue
  try{
    Write-Host "Downloading iMonitor ERP installer from $url (BITS)" -ForegroundColor Cyan
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $url -Destination $target -ErrorAction Stop
    if(Test-ValidDownload $target){$downloaded=$true;break}
    $errors += "$url (BITS) : downloaded file was smaller than expected (possibly an error page)."
  }catch{
    $errors += "$url (BITS) : $($_.Exception.Message)"
  }
  Remove-Item $target -Force -ErrorAction SilentlyContinue
  try{
    Write-Host "Downloading iMonitor ERP installer from $url (Invoke-WebRequest)" -ForegroundColor Yellow
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $target -Headers @{'Cache-Control'='no-cache'}
    if(Test-ValidDownload $target){$downloaded=$true;break}
    $errors += "$url (Invoke-WebRequest) : downloaded file was smaller than expected (possibly an error page)."
  }catch{
    $errors += "$url (Invoke-WebRequest) : $($_.Exception.Message)"
  }
  Remove-Item $target -Force -ErrorAction SilentlyContinue
}
if(!$downloaded){
  throw ("Installer download failed. DNS/Internet access to github.com is required; raw.githubusercontent.com is not used." + [Environment]::NewLine + ($errors -join [Environment]::NewLine))
}
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$target,'-Channel',$Channel)
if($Force){$args+='-Force'}
if($InstallerArguments){$args += $InstallerArguments}
& powershell.exe @args
if($LASTEXITCODE -ne 0){throw "iMonitor ERP installer returned exit code $LASTEXITCODE"}
