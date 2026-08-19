[CmdletBinding()]
param(
    [ValidateSet('main','test')][string]$Channel = 'main',
    [int]$Port = 0,
    [string]$Distribution = 'Ubuntu-24.04',
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$ReleaseBase = 'https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main'
$StateRoot = 'C:\ProgramData\iMonitorERP'
$ResumeScript = Join-Path $StateRoot 'Install-iMonitorERP-Server.ps1'
$ResumeTask = 'iMonitorERP-Server-Install-Resume'
$ProxyTask = "iMonitorERP-$Channel-WSL-PortProxy"

if ($Port -le 0) { $Port = if ($Channel -eq 'main') { 8080 } else { 8081 } }

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run PowerShell as Administrator.'
    }
}

function Test-PendingReboot {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Register-ResumeTask {
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
    Invoke-WebRequest "$ReleaseBase/scripts/Install-iMonitorERP-Server.ps1" -OutFile $ResumeScript -UseBasicParsing
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$ResumeScript`" -Channel $Channel -Port $Port -Distribution `"$Distribution`" -NoReboot"
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument $args
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Ensure-WSL {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe is unavailable. Install current Windows Server updates first.'
    }

    $featuresChanged = $false
    foreach ($feature in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
        if ($state -ne 'Enabled') {
            Write-Host "Enabling Windows feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
            $featuresChanged = $true
        }
    }

    if ($featuresChanged -or (Test-PendingReboot)) {
        Register-ResumeTask
        Write-Host '[INFO] Windows must reboot before WSL2 can continue.'
        if ($NoReboot) {
            Write-Host "Reboot the server; task '$ResumeTask' will resume installation automatically."
            exit 20
        }
        Restart-Computer -Force
        exit 0
    }

    try { wsl.exe --set-default-version 2 | Out-Null } catch {}

    $distros = @(wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ })
    if ($distros -notcontains $Distribution) {
        Write-Host "Installing WSL distribution: $Distribution"
        & wsl.exe --install -d $Distribution --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "WSL distribution installation failed with exit code $LASTEXITCODE."
        }
        if (Test-PendingReboot) {
            Register-ResumeTask
            if ($NoReboot) {
                Write-Host "Reboot the server; task '$ResumeTask' will resume installation automatically."
                exit 20
            }
            Restart-Computer -Force
            exit 0
        }
    }

    & wsl.exe -d $Distribution -u root -- bash -lc 'echo WSL_READY' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not start WSL distribution '$Distribution' as root." }
}

function Configure-PortProxy {
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
    $proxyScript = Join-Path $StateRoot "Update-$Channel-PortProxy.ps1"
    @"
`$ErrorActionPreference = 'Stop'
`$ip = (& wsl.exe -d '$Distribution' -u root -- sh -lc "hostname -I | awk '{print `$1}'").Trim()
if (-not `$ip) { throw 'Could not resolve WSL IP address.' }
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>`$null | Out-Null
netsh interface portproxy add v4tov4 listenport=$Port listenaddress=0.0.0.0 connectport=$Port connectaddress=`$ip | Out-Null
"@ | Set-Content -Path $proxyScript -Encoding UTF8

    & PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $proxyScript
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$proxyScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $ProxyTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    $rule = "iMonitor ERP $Channel $Port"
    if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
    }
}

Assert-Administrator
Ensure-WSL

$linuxCommand = "curl -fsSL $ReleaseBase/scripts/Install-iMonitorERP-Server.sh | bash -s -- --channel $Channel --port $Port"
Write-Host "Installing iMonitor ERP $Channel inside WSL2..."
& wsl.exe -d $Distribution -u root -- bash -lc $linuxCommand
if ($LASTEXITCODE -ne 0) { throw "Linux stack installer failed with exit code $LASTEXITCODE." }

Configure-PortProxy
Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $ResumeScript -Force -ErrorAction SilentlyContinue

Write-Host "[OK] iMonitor ERP $Channel installed on Windows Server through WSL2."
Write-Host "[OK] URL: http://localhost:$Port/health"
Write-Host "[OK] Port proxy task: $ProxyTask"
Write-Host 'Run this same installer again later to update the channel.'
