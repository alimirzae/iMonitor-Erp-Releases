#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install PowerShell 7 and the Playwright-matched Chromium for AiBOS Windows.
.DESCRIPTION
  Modes: official signed MSI (download or offline), browser direct/CDN mirror/proxy,
  or offline ZIP copied from a matching Playwright installation.
  No ERP application packages, IIS sites or databases are modified.
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AiBOSBrowserPrerequisites.ps1
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AiBOSBrowserPrerequisites.ps1 -ProxyUrl http://proxy.example:8080
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AiBOSBrowserPrerequisites.ps1 -PowerShellMsi C:\temp\PowerShell-7.x-win-x64.msi -OfflineBrowserZip C:\temp\aibos-ms-playwright.zip
#>
[CmdletBinding()]
param(
  [string]$PublishPath = 'C:\ecomm\test\current',
  [string]$BrowserPath = 'C:\ProgramData\AiBOS\ms-playwright',
  [string]$PowerShellMsi = '',
  [string]$OfflineBrowserZip = '',
  [string]$ProxyUrl = '',
  [string]$DownloadHost = '',
  [string]$ExpectedBrowserZipSha256 = '',
  [switch]$SkipPowerShellInstall
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path $env:TEMP 'AiBOS-BrowserPrerequisites'
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Say([string]$s) { Write-Host "[AiBOS] $s" }
function Find-Pwsh {
  $known = @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe")
  foreach ($p in $known) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p } }
  # Microsoft Store aliases are user-scoped and unsuitable for SYSTEM service.
  return $null
}
function Download([string]$url, [string]$dest) {
  Say "Downloading $url"
  $args = @('-fL','--retry','3','--connect-timeout','20','--max-time','900','-o',$dest)
  if($ProxyUrl) { $args += @('--proxy',$ProxyUrl) }
  $args += $url
  & curl.exe @args
  if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $dest)) { throw "Download failed: $url (curl exit $LASTEXITCODE)" }
}
function Install-Pwsh7 {
  $pwsh = Find-Pwsh
  if($pwsh) { Say "System PowerShell 7: $pwsh"; return $pwsh }
  if($SkipPowerShellInstall) { throw 'System-wide PowerShell 7 not found; -SkipPowerShellInstall was set.' }
  $msi = $PowerShellMsi
  if(!$msi) {
    # Resolve latest stable MSI from the vendor's GitHub release API.
    $api = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
    $jsonFile = Join-Path $work 'powershell-release.json'
    Download $api $jsonFile
    $release = Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json
    $arch = if([Environment]::Is64BitOperatingSystem){'x64'}else{'x86'}
    $asset = $release.assets | Where-Object { $_.name -match "^PowerShell-7\.[0-9.]+-win-$arch\.msi$" } | Select-Object -First 1
    if(!$asset) { throw "Official PowerShell 7 MSI ($arch) not found in latest release; supply -PowerShellMsi." }
    $msi = Join-Path $work $asset.name
    Download $asset.browser_download_url $msi
  }
  if(!(Test-Path -LiteralPath $msi -PathType Leaf)) { throw "MSI missing: $msi" }
  $sig = Get-AuthenticodeSignature -LiteralPath $msi
  if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
    throw 'MSI signature is not valid Microsoft Authenticode. Installation refused.'
  }
  Say 'Installing signed Microsoft PowerShell 7 MSI for all users...'
  $p = Start-Process msiexec.exe -ArgumentList @('/i',"`"$msi`"",'/qn','/norestart','ADD_PATH=1') -Wait -PassThru
  if($p.ExitCode -notin @(0,3010)) { throw "MSI installation failed: $($p.ExitCode)" }
  $pwsh = Find-Pwsh
  if(!$pwsh) { throw 'PowerShell 7 installed but system path was not found.' }
  Say "PowerShell 7 ready: $pwsh"
  return $pwsh
}
function Find-Cli {
  if(!(Test-Path -LiteralPath $PublishPath -PathType Container)) { throw "AiBOS publish path missing: $PublishPath" }
  $cli = Get-ChildItem -LiteralPath $PublishPath -Recurse -Filter playwright.ps1 -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if(!$cli) { throw "No playwright.ps1 found under $PublishPath. Use a published AiBOS version with Playwright assets." }
  return $cli.FullName
}
function Test-Browser {
  $folders = @(Get-ChildItem -LiteralPath $BrowserPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^chromium-\d+$' })
  foreach($folder in $folders) {
    $exe = Join-Path $folder.FullName 'chrome-win64\chrome.exe'
    if(!(Test-Path -LiteralPath $exe)) { $exe = Join-Path $folder.FullName 'chrome-win\chrome.exe' }
    if(Test-Path -LiteralPath $exe) {
      & $exe --version
      if($LASTEXITCODE -eq 0) { return $true }
    }
  }
  return $false
}
$pwsh = Install-Pwsh7
$cli = Find-Cli
New-Item -ItemType Directory -Force -Path $BrowserPath | Out-Null
[Environment]::SetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH',$BrowserPath,'Machine')
$env:PLAYWRIGHT_BROWSERS_PATH=$BrowserPath
if($OfflineBrowserZip) {
  if(!(Test-Path -LiteralPath $OfflineBrowserZip -PathType Leaf)) { throw "Offline archive missing: $OfflineBrowserZip" }
  if($ExpectedBrowserZipSha256) {
    $actual = (Get-FileHash -LiteralPath $OfflineBrowserZip -Algorithm SHA256).Hash
    if($actual -ne $ExpectedBrowserZipSha256) { throw 'Offline ZIP SHA256 mismatch.' }
  }
  Say 'Unpacking offline Playwright browser cache. Archive must contain chromium-* directories at its root.'
  $staging = Join-Path $work 'offline-browser'
  if(Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force -Recurse }
  Expand-Archive -LiteralPath $OfflineBrowserZip -DestinationPath $staging -Force
  $dirs = @(Get-ChildItem -LiteralPath $staging -Directory | Where-Object { $_.Name -match '^(chromium|chromium_headless_shell|ffmpeg)-\d+$' })
  if(!$dirs.Count) { throw 'Archive must contain versioned Playwright browser cache directories.' }
  foreach($dir in $dirs) { Copy-Item -LiteralPath $dir.FullName -Destination $BrowserPath -Recurse -Force }
} else {
  if($ProxyUrl) {
    $env:HTTPS_PROXY=$ProxyUrl
    $env:HTTP_PROXY=$ProxyUrl
  }
  if($DownloadHost) { $env:PLAYWRIGHT_DOWNLOAD_HOST=$DownloadHost }
  Say "Installing Chromium via the matching Playwright CLI: $cli"
  & $pwsh -NoProfile -File $cli install chromium
  if($LASTEXITCODE -ne 0) {
    throw "Playwright browser download failed (exit $LASTEXITCODE). If CDN returns 403, retry with -ProxyUrl or create an offline browser ZIP on a machine running the SAME Playwright version, then use -OfflineBrowserZip. An arbitrary Chrome ZIP is not compatible."
  }
}
if(!(Test-Browser)) {
  throw 'Chromium not executable in managed cache. Offline archive may be incomplete or incompatible.'
}
Say 'Chromium executable verification succeeded.'
Say "PLAYWRIGHT_BROWSERS_PATH=$BrowserPath"
Say 'IMPORTANT: Validate launching a browser through AiBOS BrowserHost separately; executable --version is not a complete functional test.'
Say 'Restart the BrowserHost service / IIS application pool after the environment change, if required.'
