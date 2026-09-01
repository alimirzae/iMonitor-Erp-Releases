param(
    [ValidateSet('preview')][string]$Channel='preview',
    [string]$InstallRoot=(Join-Path $env:LOCALAPPDATA 'iMonitor\WindowsEdge.Web')
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Repo='alimirzae/iMonitor-Erp-Releases'
$Raw="https://raw.githubusercontent.com/$Repo/main"
$StatePath=Join-Path $InstallRoot 'install-state.json'
$LogRoot=Join-Path $InstallRoot 'logs'
New-Item -ItemType Directory $LogRoot -Force|Out-Null
$Log=Join-Path $LogRoot 'auto-update.log'
function Write-Log([string]$m){Add-Content $Log ("{0:o} {1}" -f [DateTime]::UtcNow,$m) -Encoding UTF8}
try{
    if(-not(Test-Path $StatePath)){Write-Log 'No installation state; skipped.';exit 0}
    $state=Get-Content $StatePath -Raw|ConvertFrom-Json
    $manifest=Invoke-RestMethod "$Raw/manifests/windows-edge-web-$Channel.json?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 30
    if(-not $manifest.published){Write-Log 'No published package; skipped.';exit 0}
    if(([string]$state.sourceSha -eq [string]$manifest.sourceSha)-and([string]$state.version -eq [string]$manifest.version)){Write-Log "Already current: $($state.version).";exit 0}
    $installer=Join-Path $env:TEMP ("Install-WindowsEdge-"+[guid]::NewGuid().ToString('N')+'.ps1')
    Invoke-WebRequest "$Raw/scripts/Install-New-Win-Edge.ps1?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $installer -UseBasicParsing -TimeoutSec 30
    try{
        Write-Log "Updating $($state.version) to $($manifest.version)."
        & $installer -Channel $Channel -InstallRoot $InstallRoot -SkipAutoUpdate
        if(-not $?){throw 'Installer returned failure.'}
        Write-Log "Update completed: $($manifest.version)."
    }finally{Remove-Item $installer -Force -ErrorAction SilentlyContinue}
}catch{Write-Log ("Update failed: "+$_.Exception.Message);throw}
