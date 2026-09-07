[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = (Get-Location).Path,
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [string]$MySqlBinPath = '',
    [string]$MySqlHost = '',
    [int]$MySqlPort = 0,
    [string]$MySqlRootUser = '',
    [string]$MySqlRootPassword = '',
    [switch]$Force,
    [switch]$UpdateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# v2.0.15 hotfix wrapper.
# It downloads the last known-good core revision, applies the PowerShell native-output fix,
# then executes the patched core with the original arguments. Keeping the bootstrap/Core
# contract unchanged means existing scheduled tasks automatically receive this repair.

$repo = 'alimirzae/iMonitor-Erp-Releases'
$baseCommit = '8afb0468c216908fba028026a79221d768a85259'
$raw = "https://raw.githubusercontent.com/$repo/$baseCommit/scripts/Install-iMonitorERP-v2.0.15-core.ps1"
$source = Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.15-core-base-' + [guid]::NewGuid().ToString('N') + '.ps1')
$patched = Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.15-core-patched-' + [guid]::NewGuid().ToString('N') + '.ps1')

try {
    Write-Host 'Loading patched installer core v2.0.15...' -ForegroundColor Cyan
    & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors $raw -o $source
    $curlExit = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($curlExit -ne 0 -or -not (Test-Path $source -PathType Leaf)) {
        throw "Could not load base installer core. curl exit code=$curlExit"
    }

    $text = Get-Content $source -Raw

    $oldCurl = @"
            & `$curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.15' `$Uri -o `$OutFile
            `$code = `$LASTEXITCODE
"@
    $newCurl = @"
            & `$curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.15' `$Uri -o `$OutFile 2>&1 | ForEach-Object { Write-Host `$_ }
            `$code = `$LASTEXITCODE
"@
    if (-not $text.Contains($oldCurl)) { throw 'Hotfix could not find Invoke-CurlDownload block in base core.' }
    $text = $text.Replace($oldCurl,$newCurl)

    $oldLatest = @"
        `$r = Get-Content `$tmp -Raw | ConvertFrom-Json | Where-Object { `$_.tag_name -like "`$Prefix*" } | Select-Object -First 1
        if (-not `$r) { throw "No release found for `$Prefix" }
        return `$r
"@
    $newLatest = @"
        `$allReleases = @(Get-Content `$tmp -Raw | ConvertFrom-Json)
        `$r = @(`$allReleases | Where-Object { `$_.tag_name -like "`$Prefix*" } | Select-Object -First 1)
        if (`$r.Count -eq 0 -or -not `$r[0]) { throw "No release found for `$Prefix" }
        return `$r[0]
"@
    if (-not $text.Contains($oldLatest)) { throw 'Hotfix could not find Get-LatestRelease block in base core.' }
    $text = $text.Replace($oldLatest,$newLatest)

    $oldEnsure = '$dir = Join-Path $PackageCacheDirectory $Release.tag_name'
    $newEnsure = '$tagName = [string]$Release.tag_name' + [Environment]::NewLine + '    if ([string]::IsNullOrWhiteSpace($tagName)) { throw ''Release tag_name is empty or invalid.'' }' + [Environment]::NewLine + '    $dir = Join-Path $PackageCacheDirectory $tagName'
    if (-not $text.Contains($oldEnsure)) { throw 'Hotfix could not find Ensure-Package tag_name block in base core.' }
    $text = $text.Replace($oldEnsure,$newEnsure)

    Set-Content $patched $text -Encoding UTF8

    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$patched,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
    if ($MySqlBinPath) { $args += @('-MySqlBinPath',$MySqlBinPath) }
    if ($MySqlHost) { $args += @('-MySqlHost',$MySqlHost) }
    if ($MySqlPort -gt 0) { $args += @('-MySqlPort',[string]$MySqlPort) }
    if ($MySqlRootUser) { $args += @('-MySqlRootUser',$MySqlRootUser) }
    if ($MySqlRootPassword) { $args += @('-MySqlRootPassword',$MySqlRootPassword) }
    if ($Force) { $args += '-Force' }
    if ($UpdateOnly) { $args += '-UpdateOnly' }

    $p = Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}
finally {
    Remove-Item $source,$patched -Force -ErrorAction SilentlyContinue
}
