[CmdletBinding()]
param(
  [ValidateSet('Both','Test','Production')][string]$Channel='Both',
  [switch]$Force,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$InstallerArguments
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$version='2.1.4'
$file="Install-iMonitorERP-v$version.ps1"
$work=Join-Path $env:TEMP 'iMonitorERP-Setup'
New-Item -ItemType Directory -Force -Path $work|Out-Null
$target=Join-Path $work $file
$urls=@(
  "https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/imonitor-erp-installer-v$version/$file",
  "https://testerp.imonitor.ir/downloads/installers/$file"
)
$errors=@()
foreach($url in $urls){
  try{
    Write-Host "Downloading iMonitor ERP installer from $url" -ForegroundColor Cyan
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $url -Destination $target -ErrorAction Stop
    if((Test-Path $target) -and (Get-Item $target).Length -gt 10000){break}
  }catch{
    $errors += "$url : $($_.Exception.Message)"
    Remove-Item $target -Force -ErrorAction SilentlyContinue
  }
}
if(!(Test-Path $target)){
  throw ("Installer download failed. DNS/Internet access to github.com is required; raw.githubusercontent.com is not used." + [Environment]::NewLine + ($errors -join [Environment]::NewLine))
}
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$target,'-Channel',$Channel)
if($Force){$args+='-Force'}
if($InstallerArguments){$args += $InstallerArguments}
& powershell.exe @args
if($LASTEXITCODE -ne 0){throw "iMonitor ERP installer returned exit code $LASTEXITCODE"}
