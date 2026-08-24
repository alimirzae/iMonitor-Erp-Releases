param(
    [ValidateSet('preview')][string]$Channel = 'preview',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'iMonitor\New_Win_Edge'),
    [switch]$ShowUi
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ReleaseRepo = 'alimirzae/iMonitor-Erp-Releases'
$RawBase = "https://raw.githubusercontent.com/$ReleaseRepo/main"
$ManifestUrl = "$RawBase/manifests/new-win-edge-preview.json?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$ExecutableName = 'New_Win_Edge.exe'
$StartupName = 'iMonitor New Win Edge.lnk'

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT') { throw 'New_Win_Edge can only be installed on Windows.' }
    $release = 0
    try { $release = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release).Release } catch {}
    if ($release -lt 461808) { throw '.NET Framework 4.7.2 or newer is required. Install it and run this command again.' }
}

function Get-Manifest {
    Write-Host '[1/6] Checking New_Win_Edge preview release...' -ForegroundColor Cyan
    $m = Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'Cache-Control'='no-cache' } -TimeoutSec 30
    if (-not $m.published -or [string]::IsNullOrWhiteSpace([string]$m.url)) {
        throw 'The New_Win_Edge preview package has not been published yet.'
    }
    return $m
}

function Stop-Edge([string]$ExePath) {
    Get-CimInstance Win32_Process -Filter "Name='$ExecutableName'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $ExePath } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Set-StartupShortcut([string]$ExePath) {
    $startup = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startup $StartupName
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $ExePath
    $shortcut.WorkingDirectory = Split-Path $ExePath
    $shortcut.Description = 'iMonitor ERP local printing and barcode API'
    $shortcut.Save()
}

Assert-Windows
$manifest = Get-Manifest
$temp = Join-Path $env:TEMP ("NewWinEdge-" + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $temp 'New_Win_Edge.zip'
$extract = Join-Path $temp 'payload'
$current = Join-Path $InstallRoot 'current'
$backupRoot = Join-Path $InstallRoot 'backup'
New-Item -ItemType Directory -Path $temp,$extract,$InstallRoot,$backupRoot -Force | Out-Null

try {
    Write-Host "[2/6] Downloading version $($manifest.version)..."
    Invoke-WebRequest -Uri $manifest.url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = ([string]$manifest.sha256).ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA256 verification failed. Expected $expected, got $actual." }

    Write-Host '[3/6] Extracting verified package...'
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $newExe = Get-ChildItem $extract -Filter $ExecutableName -Recurse | Select-Object -First 1
    if (-not $newExe) { throw "$ExecutableName was not found in the release package." }
    if (-not (Test-Path (Join-Path $newExe.Directory.FullName 'Stimulsoft.Report.dll'))) {
        throw 'Stimulsoft runtime is missing from the release package.'
    }

    $installedExe = Join-Path $current $ExecutableName
    Stop-Edge $installedExe

    Write-Host '[4/6] Installing with rollback backup...'
    if (Test-Path $current) {
        $backup = Join-Path $backupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item $current $backup
    }
    New-Item -ItemType Directory -Path $current -Force | Out-Null
    Copy-Item (Join-Path $newExe.Directory.FullName '*') $current -Recurse -Force

    Write-Host '[5/6] Registering automatic startup and starting local API...'
    Set-StartupShortcut $installedExe
    $arguments = if ($ShowUi) { '--show-ui' } else { '' }
    Start-Process -FilePath $installedExe -ArgumentList $arguments -WorkingDirectory $current

    $health = 'http://127.0.0.1:17891/health'
    $ready = $false
    for ($i=0; $i -lt 30; $i++) {
        try {
            $response = Invoke-RestMethod -Uri $health -TimeoutSec 2
            if ($response.ok -eq $true) { $ready = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "Installation completed but local API health check failed: $health" }

    [ordered]@{
        product='New_Win_Edge'
        channel=$Channel
        version=$manifest.version
        sourceSha=$manifest.sourceSha
        installedAt=[DateTime]::UtcNow.ToString('o')
        installRoot=$InstallRoot
        healthUrl=$health
    } | ConvertTo-Json | Set-Content (Join-Path $InstallRoot 'install-state.json') -Encoding UTF8

    Write-Host '[6/6] New_Win_Edge installed successfully.' -ForegroundColor Green
    Write-Host "Version : $($manifest.version)"
    Write-Host "Path    : $current"
    Write-Host "Health  : $health"
    Write-Host 'The application starts headless with Windows. Use --show-ui only for local maintenance.'
}
catch {
    if (-not (Test-Path $current)) {
        $lastBackup = Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($lastBackup) { Move-Item $lastBackup.FullName $current }
    }
    throw
}
finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
