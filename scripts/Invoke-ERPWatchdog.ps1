#requires -Version 5.1
<#
Independent health recovery worker for Unified ERP Setup Host.
Create a SYSTEM scheduled task every minute; this script does not require Setup Host or AiBOS.
Settings: %ProgramData%\iMonitor\ERPDeploymentManager\watchdog\*.json
#>
[CmdletBinding()]
param([string]$StateRoot = "$env:ProgramData\iMonitor\ERPDeploymentManager")
$ErrorActionPreference = 'Stop'
$settingsRoot = Join-Path $StateRoot 'watchdog'
$logDir = Join-Path $StateRoot 'watchdog-logs'
New-Item -ItemType Directory -Path $settingsRoot,$logDir -Force | Out-Null
$mutex = [Threading.Mutex]::new($false, 'Global\iBOS-ERP-Watchdog')
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0)
    if (-not $acquired) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $settingsRoot -Filter '*.json' -File)) {
        try {
            $cfg = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (-not $cfg.Enabled) { continue }
            $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($id -notmatch '^[a-zA-Z0-9_-]+$') { continue }
            $interval = [Math]::Max(1,[Math]::Min(1440,[int]$cfg.IntervalMinutes))
            $grace = [Math]::Max(1,[Math]::Min(60,[int]$cfg.AfterRestartDelayMinutes))
            $timeout = [Math]::Max(2,[Math]::Min(60,[int]$cfg.TimeoutSeconds))
            $log = Join-Path $logDir ($id+'.jsonl')
            $status = Join-Path $logDir ($id+'.state.json')
            $now = [DateTime]::UtcNow
            $prior = $null
            if (Test-Path $status) { try { $prior=Get-Content $status -Raw | ConvertFrom-Json } catch {} }
            $next = if($prior -and $prior.NextCheckUtc) { [datetime]$prior.NextCheckUtc } else { [datetime]::MinValue }
            if ($now -lt $next) { continue }
            $uri = [uri]$cfg.HealthUrl
            if ($uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Host -notmatch '^[A-Za-z0-9.:-]+$') {
                throw 'Invalid health endpoint URI'
            }
            $healthy=$false; $detail=''
            try {
                $response=Invoke-WebRequest -Uri $uri.AbsoluteUri -UseBasicParsing -TimeoutSec $timeout -MaximumRedirection 0
                $healthy=($response.StatusCode -eq 200)
                $detail='HTTP '+$response.StatusCode
            } catch { $detail=$_.Exception.Message }
            $restarted=$false
            $next=$now.AddMinutes($interval)
            if (-not $healthy -and $cfg.RestartOnFailure) {
                # Only named local IIS resources stored by the trusted installer may be controlled.
                $manifestPath=Join-Path (Join-Path $StateRoot 'instances') ($id+'.json')
                if (-not (Test-Path $manifestPath)) { throw 'Installation manifest absent' }
                $manifest=Get-Content $manifestPath -Raw | ConvertFrom-Json
                $pool=[string]$manifest.AppPool
                $site=[string]$manifest.IisSite
                if ($pool -notmatch '^[\w. -]{1,100}$' -or $site -notmatch '^[\w. -]{1,100}$') { throw 'Invalid IIS names' }
                Import-Module WebAdministration -ErrorAction Stop
                if (Test-Path ('IIS:\AppPools\'+$pool)) {
                    Restart-WebAppPool -Name $pool -ErrorAction Stop
                    if((Get-Website -Name $site -ErrorAction Stop).State -ne 'Started') { Start-Website -Name $site -ErrorAction Stop }
                    $restarted=$true
                    $next=$now.AddMinutes($grace)
                } else { throw 'Application pool not found' }
            }
            $tmp=$status+'.tmp'
            @{ LastCheckUtc=$now.ToString('o'); NextCheckUtc=$next.ToString('o'); Healthy=$healthy; Detail=$detail; Restarted=$restarted } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $status -Force
            @{ AtUtc=$now.ToString('o'); Healthy=$healthy; Detail=$detail; Restarted=$restarted; NextCheckUtc=$next.ToString('o') } |
                ConvertTo-Json -Compress | Add-Content -LiteralPath $log -Encoding UTF8
            # Retain recent log lines only, independently of application releases.
            if ((Get-Item $log).Length -gt 1048576) {
                @(Get-Content $log -Tail 250) | Set-Content -LiteralPath $log -Encoding UTF8
            }
        } catch {
            $message=($_.Exception.Message -replace '[\r\n]',' ')
            @{ AtUtc=[DateTime]::UtcNow.ToString('o'); Error=$message } |
                ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $logDir ($file.BaseName+'.jsonl')) -Encoding UTF8
        }
    }
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
