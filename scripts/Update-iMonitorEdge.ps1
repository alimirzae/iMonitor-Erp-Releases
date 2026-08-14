param(
    [ValidateSet('preview','stable')]
    [string]$Channel='preview'
)

$ErrorActionPreference='Stop'
$statePath = Join-Path $env:ProgramData 'iMonitor\Edge\install-state.json'
$manifestUrl = "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/manifests/edge-$Channel.json"
$installerUrl = 'https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEdge.ps1'

if (-not (Test-Path $statePath)) { exit 0 }
$state = Get-Content $statePath -Raw | ConvertFrom-Json
$manifest = Invoke-RestMethod $manifestUrl -Headers @{ 'Cache-Control'='no-cache' } -TimeoutSec 15
if (-not $manifest.published) { exit 0 }
if ([string]$state.sha -eq [string]$manifest.sourceSha -and [string]$state.version -eq [string]$manifest.version) { exit 0 }

$temp = Join-Path $env:TEMP 'Install-iMonitorEdge.ps1'
Invoke-WebRequest $installerUrl -OutFile $temp -UseBasicParsing
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $temp -Channel $Channel -Port ([int]$state.port) -AllowLan ([bool]$state.allowLan) -SkipAutoUpdate
    if ($LASTEXITCODE -ne 0) { throw "Updater installer exit code: $LASTEXITCODE" }
}
finally {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
}
