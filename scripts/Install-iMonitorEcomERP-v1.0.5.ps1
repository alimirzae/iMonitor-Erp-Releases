[CmdletBinding()]
param(
    [ValidateSet('test','master')][string]$Channel = 'test',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = 'alimirzae/iMonitor-Erp-Releases'
$prefix = "imonitor-ecomerp-$Channel-v"
$assetName = 'iMonitor-EcomERP-win-x64.zip'
$base = Join-Path $InstallRoot $Channel
$runtime = Join-Path $InstallRoot 'dotnet'
$current = Join-Path $base 'current'
$versionFile = Join-Path $base 'version'
New-Item -ItemType Directory -Force -Path $base, $runtime | Out-Null
$hasRuntime = $false
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $hasRuntime = @(& dotnet --list-runtimes) -match '^Microsoft.AspNetCore.App 8\.'
}
if (-not $hasRuntime) {
    $installer = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing https://dot.net/v1/dotnet-install.ps1 -OutFile $installer
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel 8.0 -Runtime aspnetcore -InstallDir $runtime -NoPath
    if ($LASTEXITCODE -ne 0) { throw 'ASP.NET Core Runtime 8 installation failed.' }
    $dotnetExe = Join-Path $runtime 'dotnet.exe'
} else {
    $dotnetExe = $dotnet.Source
}
$releases = Invoke-RestMethod -Headers @{Accept='application/vnd.github+json'} -Uri "https://api.github.com/repos/$repo/releases?per_page=50"
$release = $releases | Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name.StartsWith($prefix) } | Select-Object -First 1
if (-not $release) { throw "No release found for channel $Channel" }
$installed = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
if ($installed -ne $release.tag_name) {
    $asset = $release.assets | Where-Object name -eq $assetName | Select-Object -First 1
    $checksumAsset = $release.assets | Where-Object name -eq "$assetName.sha256" | Select-Object -First 1
    if (-not $asset -or -not $checksumAsset) { throw 'Windows release asset or checksum is missing.' }
    $work = Join-Path $env:TEMP ("imonitor-erp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $zip = Join-Path $work $assetName
        $checksum = Join-Path $work "$assetName.sha256"
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $zip
        Invoke-WebRequest -UseBasicParsing $checksumAsset.browser_download_url -OutFile $checksum
        $expected = ((Get-Content $checksum -Raw) -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw 'SHA-256 verification failed.' }
        $next = Join-Path $work 'new'
        Expand-Archive $zip $next -Force
        if (-not (Test-Path (Join-Path $next 'Ecomm.dll'))) { throw 'Release does not contain Ecomm.dll.' }
        $previous = Join-Path $base 'previous'
        if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
        if (Test-Path $current) { Move-Item $current $previous }
        Move-Item $next $current
        Set-Content $versionFile $release.tag_name -Encoding ASCII
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$launcher = Join-Path $base 'Start-iMonitorERP.cmd'
$port = if ($Channel -eq 'master') { 80 } else { 8080 }
$line1 = '@echo off'
$line2 = '"' + $dotnetExe + '" "' + (Join-Path $current 'Ecomm.dll') + '" --urls http://0.0.0.0:' + $port
Set-Content $launcher @($line1, $line2) -Encoding ASCII
Write-Host "Installed $($release.tag_name) at $current"
Write-Host "Start with: $launcher"
