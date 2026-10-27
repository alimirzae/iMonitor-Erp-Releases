#Requires -RunAsAdministrator
[CmdletBinding()]
param(
 [string]$WorkRoot = 'D:\erp_ins\AiBOSBrowserHost',
 [string]$InstallDir = 'C:\ProgramData\AiBOS\BrowserHost\Service',
 [string]$ChromiumExe = 'C:\ProgramData\AiBOS\ms-playwright\Chromium\Application\chrome.exe',
 [int[]]$CompanyIds = @(),
 [string[]]$AllowedHosts = @('www.digikala.com','digikala.com'),
 [string]$LocalSourceRoot = '',
 [switch]$RestartIis
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$serviceName = 'AiBOSBrowserHost'
$download = 'https://github.com/alimirzae/Ecomm/archive/refs/heads/test.zip'
$zip = Join-Path $WorkRoot 'source.zip'
$extract = Join-Path $WorkRoot 'src'
$staging = Join-Path $WorkRoot 'publish'
$browserConfig = 'C:\ProgramData\AiBOS\BrowserHost\browser-settings.json'
if (-not (Test-Path $ChromiumExe)) { throw "Chromium missing: $ChromiumExe" }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Install .NET 8 SDK (not just runtime) before running.' }

New-Item -ItemType Directory -Force $WorkRoot | Out-Null
# Private repositories commonly return HTTP 404 to anonymous ZIP requests.
if ($LocalSourceRoot) {
 $project = Join-Path $LocalSourceRoot 'tools\AiBOS.BrowserHost\AiBOS.BrowserHost.csproj'
 if (-not (Test-Path $project)) { throw "Project missing under LocalSourceRoot: $project" }
} else {
 $gh = Get-Command gh -ErrorAction SilentlyContinue
 if (-not $gh) { throw 'Private Ecomm repository: install GitHub CLI (gh), run gh auth login, or pass -LocalSourceRoot pointing to a test-branch checkout.' }
 & gh auth status 2>&1 | Out-Null
 if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated. Run gh auth login (with Ecomm access).' }
 Write-Host 'Downloading authenticated test branch archive via GitHub CLI...'
 & gh api 'repos/alimirzae/Ecomm/zipball/test' --header 'Accept: application/vnd.github+json' > $zip
 if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip) -or (Get-Item $zip).Length -lt 10000) { throw 'Authenticated GitHub download failed. Verify account access to alimirzae/Ecomm.' }
 if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
 Expand-Archive -LiteralPath $zip -DestinationPath $extract
 $project = Get-ChildItem $extract -Recurse -Filter AiBOS.BrowserHost.csproj | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $project) { throw 'BrowserHost project not found in source ZIP.' }
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Write-Host 'Publishing BrowserHost...'
& dotnet publish $project --configuration Release --runtime win-x64 --self-contained false --output $staging
if ($LASTEXITCODE -ne 0) { throw "Publish failed (exit $LASTEXITCODE)." }
$exe = Join-Path $staging 'AiBOS.BrowserHost.exe'
if (-not (Test-Path $exe)) { throw "Published executable missing: $exe" }
# Retain same key across subsequent runs.
$key = [Environment]::GetEnvironmentVariable('BrowserHost__InternalApiKey','Machine')
if ([string]::IsNullOrWhiteSpace($key)) {
 $random = New-Object byte[] 48
 [System.Security.Cryptography.RandomNumberGenerator]::Fill($random)
 $key = [Convert]::ToBase64String($random)
 [Environment]::SetEnvironmentVariable('BrowserHost__InternalApiKey',$key,'Machine')
}
[Environment]::SetEnvironmentVariable('BrowserHost__BaseUrl','http://127.0.0.1:5187','Machine')
# Prevent same-file updates from clobbering the executable path stored by deployment manager.
New-Item -ItemType Directory -Force (Split-Path $browserConfig) | Out-Null
$config = @{ BrowserHost = @{ ExecutablePath = $ChromiumExe } }
if (Test-Path $browserConfig) {
 try {
  $old = Get-Content $browserConfig -Raw | ConvertFrom-Json
  if ($old.BrowserHost.ExecutablePath) { $config.BrowserHost.ExecutablePath = [string]$old.BrowserHost.ExecutablePath }
 } catch { throw "Invalid browser settings file: $browserConfig" }
}
$config | ConvertTo-Json -Depth 6 | Set-Content $browserConfig -Encoding UTF8
# Stop service only after successful build.
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
 Stop-Service $serviceName
 (Get-Service $serviceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(35))
}
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $staging '*') -Destination $InstallDir -Recurse -Force
# Company allowlist must be explicit, never wildcard.
$settingsPath = Join-Path $InstallDir 'appsettings.Production.json'
$settings = @{ BrowserHost = @{ ListenUrl = 'http://127.0.0.1:5187'; InternalApiKey = $key; Companies = @{} } }
if (Test-Path $settingsPath) {
 try {
  $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
  if ($existing.BrowserHost.Companies) {
   foreach($entry in $existing.BrowserHost.Companies.PSObject.Properties) {
    $settings.BrowserHost.Companies[$entry.Name] = $entry.Value
   }
  }
 } catch { throw "Invalid existing company config: $settingsPath" }
}
foreach($id in $CompanyIds) {
 if ($id -le 0) { throw "Invalid company ID $id" }
 $settings.BrowserHost.Companies[[string]$id] = @{ Enabled = $true; AllowedHosts = $AllowedHosts }
}
$settings | ConvertTo-Json -Depth 8 | Set-Content $settingsPath -Encoding UTF8
# Tighten secrets: SYSTEM and Administrators only. BrowserHost runs under LocalSystem.
& icacls.exe $settingsPath /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not secure BrowserHost configuration ACL.' }
$installedExe = Join-Path $InstallDir 'AiBOS.BrowserHost.exe'
if (-not $svc) {
 & sc.exe create $serviceName "binPath= `"$installedExe`"" 'start= auto' 'obj= LocalSystem' | Out-Host
} else {
 & sc.exe config $serviceName "binPath= `"$installedExe`"" 'start= auto' | Out-Host
}
if ($LASTEXITCODE -ne 0) { throw 'Windows service creation/configuration failed.' }
& sc.exe failure $serviceName 'reset= 86400' 'actions= restart/60000/restart/60000/restart/60000' | Out-Host
Start-Service $serviceName
Start-Sleep 4
$running = (Get-Service $serviceName).Status -eq 'Running'
Write-Host "Service running: $running"
$port = Get-NetTCPConnection -LocalPort 5187 -State Listen -ErrorAction SilentlyContinue
Write-Host "Port 5187 listening: $([bool]$port)"
if ($RestartIis) {
 Write-Warning 'Restarting IIS WAS and W3SVC may interrupt active ERP users.'
 Restart-Service WAS -Force
 Start-Service W3SVC
}
Write-Host 'Configuration saved. Internal key not displayed.'
Write-Host 'Company access requires explicit -CompanyIds 123 parameter (actual active company IDs).'
Write-Host 'Playwright compatibility still requires authenticated POST /diagnostics/playwright.'
if (-not $running -or -not $port) { throw 'BrowserHost did not start/listen. Check Windows Event Viewer application logs.' }
