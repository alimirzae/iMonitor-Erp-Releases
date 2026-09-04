[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP',
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [string]$MySqlServer,
    [int]$MySqlPort = 0,
    [string]$TestDatabase,
    [string]$ProductionDatabase,
    [string]$TestUser,
    [string]$ProductionUser,
    [string]$TestPassword,
    [string]$ProductionPassword,
    [string]$MySqlAdminUser = 'root',
    [string]$MySqlAdminPassword,
    [switch]$SkipMySqlProvisioning,
    [switch]$UpdateOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}

$repo = 'alimirzae/iMonitor-Erp-Releases'
$installerHome = Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $installerHome | Out-Null

function Download-CoreUpdater([string]$OutFile) {
    $cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $mirror = "https://testerp.imonitor.ir/downloads/erp/install/Install-iMonitorERP-v2.0.6.ps1.txt?cb=$cb"
    $github = "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.6.ps1?cb=$cb"

    foreach ($item in @(@('mirror',$mirror,$false),@('github',$github,$true))) {
        $name = [string]$item[0]
        $uri = [string]$item[1]
        $ipv4 = [bool]$item[2]
        try {
            Write-Host "Core updater download via $name..."
            $args = @('--silent','--http1.1','--fail','--location','--connect-timeout','8','--max-time','120','--retry','2','--retry-all-errors',$uri,'-o',$OutFile)
            if ($ipv4) { $args = @('-4') + $args }
            & curl.exe @args 2>$null
            $exit = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            if ($exit -ne 0) { throw "curl exit code $exit" }
            if ((Get-Item $OutFile -ErrorAction Stop).Length -le 0) { throw 'Downloaded updater is empty.' }
            return
        }
        catch {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Warning "Core updater via $name unavailable; trying fallback."
        }
    }
    throw 'Could not download core updater from domestic mirror or GitHub IPv4.'
}

$core = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.6-core.ps1'
Download-CoreUpdater $core

function Build-Arguments([string]$TargetChannel) {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$core,'-Channel',$TargetChannel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',$TestPort,'-ProductionPort',$ProductionPort)
    foreach ($pair in @(
        @('MySqlServer',$MySqlServer),@('MySqlPort',$MySqlPort),@('TestDatabase',$TestDatabase),@('ProductionDatabase',$ProductionDatabase),
        @('TestUser',$TestUser),@('ProductionUser',$ProductionUser),@('TestPassword',$TestPassword),@('ProductionPassword',$ProductionPassword),
        @('MySqlAdminUser',$MySqlAdminUser),@('MySqlAdminPassword',$MySqlAdminPassword))) {
        $name = [string]$pair[0]
        $value = $pair[1]
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value) -and -not ($name -eq 'MySqlPort' -and [int]$value -le 0)) {
            $args += "-$name"
            $args += [string]$value
        }
    }
    if ($SkipMySqlProvisioning) { $args += '-SkipMySqlProvisioning' }
    if ($UpdateOnly) { $args += '-UpdateOnly' }
    if ($Force) { $args += '-Force' }
    return $args
}

function Get-FriendlyFailure([string]$Text,[string]$Target) {
    if ($Text -match 'MySQL login failed for\s+([^\.\r\n]+)') {
        return "MySQL credentials are invalid for $($matches[1]). $Target was skipped; run once without -UpdateOnly to repair credentials."
    }
    if ($Text -match 'No release found for\s+([^\r\n]+)') {
        return "No release is currently published for $Target."
    }
    if ($Text -match 'failed after 5 attempts') {
        return "$Target package download failed after retries."
    }
    return "$Target updater exited with an error."
}

function Invoke-ChannelUpdate([string]$Target) {
    $stdout = Join-Path $env:TEMP ("imonitor-$($Target.ToLowerInvariant())-stdout-$([guid]::NewGuid().ToString('N')).log")
    $stderr = Join-Path $env:TEMP ("imonitor-$($Target.ToLowerInvariant())-stderr-$([guid]::NewGuid().ToString('N')).log")
    try {
        Write-Host "=== Updating $Target independently ==="
        $p = Start-Process powershell.exe -ArgumentList (Build-Arguments $Target) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $outText = if (Test-Path $stdout) { Get-Content $stdout -Raw -ErrorAction SilentlyContinue } else { '' }
        $errText = if (Test-Path $stderr) { Get-Content $stderr -Raw -ErrorAction SilentlyContinue } else { '' }
        $combined = "$outText`n$errText"

        if ($p.ExitCode -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace($outText)) { Write-Host $outText.TrimEnd() }
            return [pscustomobject]@{ Channel=$Target; Success=$true; Error=$null }
        }

        return [pscustomobject]@{ Channel=$Target; Success=$false; Error=(Get-FriendlyFailure $combined $Target) }
    }
    finally {
        Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }
}

$targets = if ($Channel -eq 'Both') { @('Test','Production') } else { @($Channel) }
$results = @()
foreach ($target in $targets) {
    $result = Invoke-ChannelUpdate $target
    $results += $result
    if (-not $result.Success) {
        Write-Warning "$($result.Channel): $($result.Error)"
        if ($Channel -ne 'Both') {
            Remove-Item $core -Force -ErrorAction SilentlyContinue
            throw $result.Error
        }
    }
}
Remove-Item $core -Force -ErrorAction SilentlyContinue

if (-not ($results | Where-Object Success)) {
    throw 'No requested channel could be updated.'
}

$self = Join-Path $installerHome 'Install-iMonitorERP-v2.0.8.ps1'
Copy-Item $PSCommandPath $self -Force
$testAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction | Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /TR $prodAction | Out-Null
$global:LASTEXITCODE = 0

Write-Host ''
Write-Host 'iMonitor ERP installer/updater v2.0.8 completed.'
foreach ($r in $results) {
    if ($r.Success) { Write-Host "$($r.Channel): update completed." }
    else { Write-Warning "$($r.Channel): skipped without blocking other channels. $($r.Error)" }
}
Write-Host "Scheduled updater: $self"
Write-Host 'Test and Production updates are isolated; a broken Production MySQL login cannot block Test updates.'
