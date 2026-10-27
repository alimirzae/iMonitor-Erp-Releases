# Playwright Chromium prerequisite for AiBOS IIS releases (PowerShell 5.1 compatible).
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PublishPath,
      [string]$BrowserPath="$env:ProgramData\AiBOS\ms-playwright",
      [string]$PoolName="",
      [switch]$Strict)
$ErrorActionPreference='Stop'
function Fail([string]$Message) {
  if($Strict){throw $Message}
  Write-Warning "[AiBOS Playwright] $Message"
  return
}
if(!(Test-Path -LiteralPath $PublishPath -PathType Container)){Fail "Publish path missing: $PublishPath";return}
$installer=Get-ChildItem -LiteralPath $PublishPath -Recurse -Filter 'playwright.ps1' -File -ErrorAction SilentlyContinue|Select-Object -First 1
if(!$installer){Fail 'Published Playwright installer not found; package must include Microsoft.Playwright CLI assets (BrowserHost or ERP publish).';return}
$pwsh=Get-Command pwsh -ErrorAction SilentlyContinue
if(!$pwsh){Fail 'PowerShell 7 (pwsh.exe) is required to run playwright.ps1.';return}
New-Item -ItemType Directory -Force -Path $BrowserPath|Out-Null
$env:PLAYWRIGHT_BROWSERS_PATH=$BrowserPath
[Environment]::SetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH',$BrowserPath,'Machine')
& $pwsh.Source -NoProfile -File $installer.FullName install chromium
if($LASTEXITCODE -ne 0){Fail "Chromium install returned exit code $LASTEXITCODE";return}
if($PoolName){
  $account="IIS AppPool\$PoolName"
  & icacls.exe $BrowserPath /grant "${account}:(OI)(CI)(RX)" /T /C | Out-Null
  if($LASTEXITCODE -ne 0){Fail "Unable to grant Chromium read permissions to $account";return}
}
Write-Host "[AiBOS Playwright] Chromium ready in $BrowserPath"
