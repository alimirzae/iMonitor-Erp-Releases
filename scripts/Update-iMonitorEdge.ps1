param(
    [ValidateSet('preview','stable')]
    [string]$Channel='preview',
    [string]$Root='C:\ERP'
)

$ErrorActionPreference='Stop'
$statePath = Join-Path $Root 'Config\edge-state.json'
$manifestUrl = "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/manifests/edge-$Channel.json"
$installerUrl = 'https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEdge.ps1'
$logRoot = Join-Path $Root 'Logs\Edge'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$logPath = Join-Path $logRoot 'updater.log'

function Write-UpdateLog([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

try {
    if (-not (Test-Path $statePath)) {
        Write-UpdateLog 'No installation state found. Update skipped.'
        exit 0
    }

    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    $manifest = Invoke-RestMethod $manifestUrl -Headers @{ 'Cache-Control'='no-cache' } -TimeoutSec 20
    if (-not $manifest.published -or [string]::IsNullOrWhiteSpace([string]$manifest.url)) {
        Write-UpdateLog "No published artifact is available for channel '$Channel'."
        exit 0
    }

    if ([string]$state.sha -eq [string]$manifest.sourceSha -and [string]$state.version -eq [string]$manifest.version) {
        Write-UpdateLog "Already current: version $($state.version)."
        exit 0
    }

    $temp = Join-Path $env:TEMP ("Install-iMonitorEdge-" + [guid]::NewGuid().ToString('N') + '.ps1')
    Invoke-WebRequest $installerUrl -OutFile $temp -UseBasicParsing -TimeoutSec 30
    try {
        $port = if ($null -ne $state.port) { [int]$state.port } else { 9000 }
        $allowLan = if ($null -ne $state.allowLan) { [bool]$state.allowLan } else { $true }
        Write-UpdateLog "Updating from $($state.version) to $($manifest.version)."

        # Invoke the installer in the current PowerShell process. This preserves native Boolean
        # parameter types; spawning powershell.exe would stringify Boolean arguments.
        & $temp -Channel $Channel -Root $Root -Port $port -AllowLan $allowLan -SkipAutoUpdate -NonInteractive
        if (-not $?) { throw 'The Edge installer reported a failure.' }
        Write-UpdateLog "Update completed successfully: version $($manifest.version)."
    }
    finally {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-UpdateLog ("Update failed: " + $_.Exception.Message)
    throw
}
