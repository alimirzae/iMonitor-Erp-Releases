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

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

# Cache-safe v2.0.16 wrapper around the proven v2.0.15 core revision.
$repo='alimirzae/iMonitor-Erp-Releases'
$baseCommit='8afb0468c216908fba028026a79221d768a85259'
$source=Join-Path $env:TEMP ('imonitor-core-base-'+[guid]::NewGuid().ToString('N')+'.ps1')
$patched=Join-Path $env:TEMP ('imonitor-core-v2016-'+[guid]::NewGuid().ToString('N')+'.ps1')
$raw="https://raw.githubusercontent.com/$repo/$baseCommit/scripts/Install-iMonitorERP-v2.0.15-core.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"

try {
  Write-Host 'Loading installer core v2.0.16...' -ForegroundColor Cyan
  & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors $raw -o $source
  $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
  if($ec -ne 0 -or -not(Test-Path $source -PathType Leaf)){throw "Could not load base core. curl exit=$ec"}
  $text=Get-Content $source -Raw

  # 1) Native curl progress must never become function output.
  $text=$text.Replace("            & `$curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.15' `$Uri -o `$OutFile`r`n            `$code = `$LASTEXITCODE",
                      "            & `$curl.Source -4 --http1.1 --silent --show-error --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.16' `$Uri -o `$OutFile`r`n            `$code = `$LASTEXITCODE")

  # 2) Replace release lookup with a function that returns exactly one PSCustomObject.
  $old=@'
function Get-LatestRelease([string]$Prefix) {
    $tmp = Join-Path $env:TEMP ('imonitor-releases-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-CurlDownload "https://api.github.com/repos/$repo/releases?per_page=100" $tmp 'Release metadata download over GitHub IPv4' 300
        $r = Get-Content $tmp -Raw | ConvertFrom-Json | Where-Object { $_.tag_name -like "$Prefix*" } | Select-Object -First 1
        if (-not $r) { throw "No release found for $Prefix" }
        return $r
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
'@
  $new=@'
function Get-LatestRelease([string]$Prefix) {
    $tmp = Join-Path $env:TEMP ('imonitor-releases-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-CurlDownload "https://api.github.com/repos/$repo/releases?per_page=100" $tmp 'Release metadata download over GitHub IPv4' 300 | Out-Null
        $json = Get-Content $tmp -Raw
        $items = @($json | ConvertFrom-Json)
        $match = $null
        foreach($item in $items) {
            if($item -and ([string]$item.tag_name) -like ($Prefix + '*')) { $match = $item; break }
        }
        if($null -eq $match) { throw "No release found for $Prefix" }
        Write-Host ("Selected release: " + [string]$match.tag_name) -ForegroundColor Cyan
        return [pscustomobject]$match
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
'@
  if(-not $text.Contains($old)){throw 'Could not patch Get-LatestRelease in base core.'}
  $text=$text.Replace($old,$new)

  # 3) Do not pass a property expression directly to Join-Path.
  $old2='    $dir = Join-Path $PackageCacheDirectory $Release.tag_name'
  $new2=@'
    if($Release -is [array]) { $Release = $Release | Select-Object -First 1 }
    $tagName = [string]($Release.PSObject.Properties['tag_name'].Value)
    if([string]::IsNullOrWhiteSpace($tagName)) { throw 'Release tag_name is empty or invalid.' }
    Write-Host "Release tag: $tagName" -ForegroundColor DarkCyan
    $dir = Join-Path -Path ([string]$PackageCacheDirectory) -ChildPath $tagName
'@
  if(-not $text.Contains($old2)){throw 'Could not patch Ensure-Package Join-Path block.'}
  $text=$text.Replace($old2,$new2.TrimEnd())

  Set-Content $patched $text -Encoding UTF8

  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$patched,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
  if($MySqlBinPath){$args+=@('-MySqlBinPath',$MySqlBinPath)}
  if($MySqlHost){$args+=@('-MySqlHost',$MySqlHost)}
  if($MySqlPort -gt 0){$args+=@('-MySqlPort',[string]$MySqlPort)}
  if($MySqlRootUser){$args+=@('-MySqlRootUser',$MySqlRootUser)}
  if($MySqlRootPassword){$args+=@('-MySqlRootPassword',$MySqlRootPassword)}
  if($Force){$args+='-Force'}
  if($UpdateOnly){$args+='-UpdateOnly'}

  $p=Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
  exit $p.ExitCode
}
finally {
  Remove-Item $source,$patched -Force -ErrorAction SilentlyContinue
}
