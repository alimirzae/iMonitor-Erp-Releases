param(
    [ValidateSet('preview','stable')]
    [string]$Channel = 'preview',
    [string]$InstallDir = "$env:ProgramFiles\iMonitor\Edge",
    [string]$ServiceName = 'iMonitorEdge',
    [int]$Port = 9000,
    [bool]$AllowLan = $true,
    [bool]$EnablePos = $false,
    [switch]$SkipAutoUpdate
)

$ErrorActionPreference = 'Stop'
$ReleaseRepo = 'alimirzae/iMonitor-Erp-Releases'
$RawBase = "https://raw.githubusercontent.com/$ReleaseRepo/main"
$ManifestUrl = "$RawBase/manifests/edge-$Channel.json"
$ProgramDataRoot = Join-Path $env:ProgramData 'iMonitor\Edge'
$StatePath = Join-Path $ProgramDataRoot 'install-state.json'

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'PowerShell را با Run as Administrator اجرا کنید.'
    }
}

function Get-Manifest {
    Write-Host "Checking iMonitor Edge $Channel channel..." -ForegroundColor Cyan
    $m = Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'Cache-Control'='no-cache' } -TimeoutSec 20
    if (-not $m.published -or [string]::IsNullOrWhiteSpace([string]$m.url)) {
        throw "هنوز artifact کانال $Channel منتشر نشده است. چند دقیقه بعد دوباره اجرا کنید."
    }
    return $m
}

function Download-Verified([object]$Manifest, [string]$Destination) {
    Invoke-WebRequest -Uri $Manifest.url -OutFile $Destination -UseBasicParsing
    $actual = (Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = ([string]$Manifest.sha256).ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch. Expected $expected, got $actual"
    }
}

function Configure-Firewall {
    $rule = "iMonitor Edge Gateway TCP $Port"
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if ($AllowLan) {
        New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private -RemoteAddress LocalSubnet | Out-Null
    }
}

function Install-AutoUpdater {
    if ($SkipAutoUpdate) { return }
    New-Item -ItemType Directory -Path $ProgramDataRoot -Force | Out-Null
    $updater = Join-Path $ProgramDataRoot 'Update-iMonitorEdge.ps1'
    Invoke-WebRequest "$RawBase/scripts/Update-iMonitorEdge.ps1" -OutFile $updater -UseBasicParsing

    $taskName = "iMonitor Edge Auto Update ($Channel)"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -Channel $Channel"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Description 'Keeps iMonitor Edge updated from the public release channel.' -Force | Out-Null
}

Assert-Administrator
New-Item -ItemType Directory -Path $ProgramDataRoot -Force | Out-Null
$manifest = Get-Manifest
$tempRoot = Join-Path $env:TEMP ("iMonitorEdge-" + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $tempRoot 'edge.zip'
$extract = Join-Path $tempRoot 'payload'
New-Item -ItemType Directory -Path $extract -Force | Out-Null

try {
    Download-Verified $manifest $zip
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    $exe = Get-ChildItem $extract -Filter 'PosGateway_api.exe' -Recurse | Select-Object -First 1
    if (-not $exe) { throw 'PosGateway_api.exe در artifact پیدا نشد.' }
    $sourceDir = $exe.Directory.FullName

    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') {
        Stop-Service $ServiceName -Force
        (Get-Service $ServiceName).WaitForStatus('Stopped','00:00:30')
    }

    $backup = Join-Path $ProgramDataRoot 'upgrade-backup'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $config = Join-Path $InstallDir 'appsettings.json'
    $drivers = Join-Path $InstallDir 'drivers'
    $data = Join-Path $InstallDir 'data'
    if (Test-Path $config) { Copy-Item $config (Join-Path $backup 'appsettings.json') -Force }
    foreach ($folder in @('drivers','data')) {
        $src = Join-Path $InstallDir $folder
        $dst = Join-Path $backup $folder
        if (Test-Path $src) {
            if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
            Copy-Item $src $dst -Recurse -Force
        }
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('appsettings.json','drivers','data') } | Remove-Item -Recurse -Force
    Copy-Item (Join-Path $sourceDir '*') $InstallDir -Recurse -Force

    if (Test-Path (Join-Path $backup 'appsettings.json')) { Copy-Item (Join-Path $backup 'appsettings.json') $config -Force }
    foreach ($folder in @('drivers','data')) {
        $saved = Join-Path $backup $folder
        $target = Join-Path $InstallDir $folder
        if (Test-Path $saved) {
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            Copy-Item $saved $target -Recurse -Force
        }
    }

    if (Test-Path $config) {
        $json = Get-Content $config -Raw | ConvertFrom-Json
        if (-not $json.ApplicationSettings) { $json | Add-Member ApplicationSettings ([pscustomobject]@{}) }
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

    @{ channel=$Channel; version=$manifest.version; sha=$manifest.sourceSha; installedAt=(Get-Date).ToString('o'); port=$Port; allowLan=$AllowLan } | ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
    Install-AutoUpdater

    Write-Host ''
    Write-Host 'iMonitor Edge installed successfully.' -ForegroundColor Green
    Write-Host "Version : $($manifest.version)"
    Write-Host "Service : $ServiceName"
    Write-Host "Health  : $health"
    Write-Host "Swagger : http://127.0.0.1:$Port/swagger"
    if($AllowLan){ Write-Host "LAN     : TCP $Port / Private + LocalSubnet" -ForegroundColor Cyan }
    Write-Host 'POS is optional and is disabled unless explicitly enabled.'
}
finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
