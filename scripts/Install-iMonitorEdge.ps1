param(
    [ValidateSet('preview','stable')]
    [string]$Channel = 'preview',
    [string]$Root,
    [string]$ServiceName = 'iMonitorEdge',
    [int]$Port = 9000,
    [bool]$AllowLan = $true,
    [bool]$EnablePos = $false,
    [switch]$SkipAutoUpdate,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ReleaseRepo = 'alimirzae/iMonitor-Erp-Releases'
$RawBase = "https://raw.githubusercontent.com/$ReleaseRepo/main"
$ManifestUrl = "$RawBase/manifests/edge-$Channel.json"
$DefaultRoot = 'C:\ERP'

function Resolve-InstallRoot {
    param([string]$RequestedRoot,[switch]$NoPrompt)
    if(-not [string]::IsNullOrWhiteSpace($RequestedRoot)){ return [System.IO.Path]::GetFullPath($RequestedRoot.Trim()) }
    if($NoPrompt){ return $DefaultRoot }

    Write-Host ''
    Write-Host 'iMonitor Edge installation' -ForegroundColor Cyan
    Write-Host "Default installation folder: $DefaultRoot"
    $answer = Read-Host 'Create and use C:\ERP? [Y/n]'
    if([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|yes)$'){ return $DefaultRoot }

    while($true){
        $custom = Read-Host 'Enter the full installation folder path (example: D:\ERP)'
        if([string]::IsNullOrWhiteSpace($custom)){ Write-Host 'Folder path cannot be empty.' -ForegroundColor Yellow; continue }
        try { return [System.IO.Path]::GetFullPath($custom.Trim()) }
        catch { Write-Host "Invalid folder path: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'PowerShell must be run as Administrator.' }
}

function Test-GatewayPrerequisites {
    Write-Host ''
    Write-Host 'Running gateway prerequisite checks...' -ForegroundColor Cyan

    if($PSVersionTable.PSVersion.Major -lt 5){ throw "PowerShell 5.1 or newer is required. Current version: $($PSVersionTable.PSVersion)" }
    Write-Host "[OK] PowerShell $($PSVersionTable.PSVersion)"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $null = Invoke-WebRequest -Uri 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 15
        Write-Host '[OK] Internet access to GitHub'
    }
    catch { throw "Cannot reach GitHub over HTTPS. Check Internet, DNS, proxy, or TLS settings. $($_.Exception.Message)" }

    if(-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)){ throw 'Windows Firewall PowerShell cmdlets are not available on this system.' }
    Write-Host '[OK] Windows Firewall cmdlets'

    if(-not (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue)){ throw 'Windows Scheduled Tasks PowerShell cmdlets are not available on this system.' }
    Write-Host '[OK] Scheduled Tasks cmdlets'

    Write-Host '[OK] Separate .NET Runtime installation is not required because iMonitor Edge is published self-contained.' -ForegroundColor Green
}

function Get-Manifest {
    Write-Host "Checking iMonitor Edge $Channel channel..." -ForegroundColor Cyan
    $m = Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'Cache-Control'='no-cache' } -TimeoutSec 20
    if (-not $m.published -or [string]::IsNullOrWhiteSpace([string]$m.url)) { throw "No iMonitor Edge artifact has been published for the $Channel channel yet." }
    return $m
}

function Download-Verified([object]$Manifest, [string]$Destination) {
    Write-Host 'Downloading iMonitor Edge package...'
    Invoke-WebRequest -Uri $Manifest.url -OutFile $Destination -UseBasicParsing
    $actual = (Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = ([string]$Manifest.sha256).ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA256 verification failed. Expected $expected, got $actual"
    }
}

function Configure-Firewall {
    $rule = "iMonitor Edge Gateway TCP $Port"
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if ($AllowLan) { New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private -RemoteAddress LocalSubnet | Out-Null }
}

function Install-AutoUpdater {
    if ($SkipAutoUpdate) { return }
    $updater = Join-Path $ConfigRoot 'Update-iMonitorEdge.ps1'
    Invoke-WebRequest "$RawBase/scripts/Update-iMonitorEdge.ps1" -OutFile $updater -UseBasicParsing
    $taskName = "iMonitor Edge Auto Update ($Channel)"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -Channel $Channel -Root `"$Root`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Description 'Keeps iMonitor Edge updated from the public release channel.' -Force | Out-Null
}

Assert-Administrator
Test-GatewayPrerequisites
$Root = Resolve-InstallRoot -RequestedRoot $Root -NoPrompt:$NonInteractive
$InstallDir = Join-Path $Root 'Edge'
$ConfigRoot = Join-Path $Root 'Config'
$BackupRoot = Join-Path $Root 'Backup\Edge'
$LogsRoot = Join-Path $Root 'Logs\Edge'
$StatePath = Join-Path $ConfigRoot 'edge-state.json'
New-Item -ItemType Directory -Path $Root,$InstallDir,$ConfigRoot,$BackupRoot,$LogsRoot -Force | Out-Null

Write-Host "Installation root: $Root" -ForegroundColor Cyan
$manifest = Get-Manifest
$tempRoot = Join-Path $env:TEMP ("iMonitorEdge-" + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $tempRoot 'edge.zip'
$extract = Join-Path $tempRoot 'payload'
New-Item -ItemType Directory -Path $extract -Force | Out-Null

try {
    Download-Verified $manifest $zip
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    $exe = Get-ChildItem $extract -Filter 'PosGateway_api.exe' -Recurse | Select-Object -First 1
    if (-not $exe) { throw 'PosGateway_api.exe was not found in the release package.' }
    $sourceDir = $exe.Directory.FullName

    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') {
        Write-Host "Stopping Windows service $ServiceName..."
        Stop-Service $ServiceName -Force
        (Get-Service $ServiceName).WaitForStatus('Stopped','00:00:30')
    }

    $backup = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $config = Join-Path $InstallDir 'appsettings.json'
    foreach ($item in @('appsettings.json','drivers','data')) {
        $src = Join-Path $InstallDir $item
        if (Test-Path $src) { Copy-Item $src (Join-Path $backup $item) -Recurse -Force }
    }

    Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('appsettings.json','drivers','data') } | Remove-Item -Recurse -Force
    Copy-Item (Join-Path $sourceDir '*') $InstallDir -Recurse -Force

    foreach ($item in @('appsettings.json','drivers','data')) {
        $saved = Join-Path $backup $item
        $target = Join-Path $InstallDir $item
        if (Test-Path $saved) {
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            Copy-Item $saved $target -Recurse -Force
        }
    }

    if (Test-Path $config) {
        $json = Get-Content $config -Raw | ConvertFrom-Json
        if (-not $json.ApplicationSettings) { $json | Add-Member -NotePropertyName ApplicationSettings -NotePropertyValue ([pscustomobject]@{}) }
        foreach ($pair in @(@('Port',$Port),@('AllowLan',$AllowLan),@('EnablePos',$EnablePos))) {
            $name=$pair[0]; $value=$pair[1]
            if ($json.ApplicationSettings.PSObject.Properties.Name -contains $name) { $json.ApplicationSettings.$name = $value }
            else { $json.ApplicationSettings | Add-Member -NotePropertyName $name -NotePropertyValue $value }
        }
        $json | ConvertTo-Json -Depth 30 | Set-Content $config -Encoding UTF8
    }

    Configure-Firewall
    $exePath = Join-Path $InstallDir 'PosGateway_api.exe'
    if (-not $existing) {
        New-Service -Name $ServiceName -BinaryPathName ('"{0}"' -f $exePath) -DisplayName 'iMonitor Edge' -Description 'iMonitor branch gateway for receipt printers and local devices' -StartupType Automatic | Out-Null
    } else {
        sc.exe config $ServiceName binPath= ('"{0}"' -f $exePath) start= auto | Out-Null
    }
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
    sc.exe failureflag $ServiceName 1 | Out-Null
    Start-Service $ServiceName
    (Get-Service $ServiceName).WaitForStatus('Running','00:00:30')

    $health = "http://127.0.0.1:$Port/api/health"
    $ok=$false
    for($i=0;$i -lt 25;$i++) {
        try { $r=Invoke-RestMethod $health -TimeoutSec 3; if($r.status -eq 'ok'){$ok=$true;break} } catch { Start-Sleep 1 }
    }
    if(-not $ok){ throw "Health check failed: $health" }

    @{ channel=$Channel; version=$manifest.version; sha=$manifest.sourceSha; installedAt=(Get-Date).ToString('o'); port=$Port; allowLan=$AllowLan; root=$Root } | ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
    Install-AutoUpdater

    Write-Host ''
    Write-Host 'iMonitor Edge installed successfully.' -ForegroundColor Green
    Write-Host "Root    : $Root"
    Write-Host "Version : $($manifest.version)"
    Write-Host "Service : $ServiceName"
    Write-Host "Health  : $health"
    Write-Host "Swagger : http://127.0.0.1:$Port/swagger"
    if($AllowLan){ Write-Host "LAN     : TCP $Port / Private profile / LocalSubnet" -ForegroundColor Cyan }
    Write-Host 'POS integration is optional and remains disabled unless explicitly enabled.'
}
finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
















