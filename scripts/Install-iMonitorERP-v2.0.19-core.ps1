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

$repo='alimirzae/iMonitor-Erp-Releases'
$baseCommit='8afb0468c216908fba028026a79221d768a85259'
$source=Join-Path $env:TEMP ('imonitor-core-base-'+[guid]::NewGuid().ToString('N')+'.ps1')
$patched=Join-Path $env:TEMP ('imonitor-core-v2019-'+[guid]::NewGuid().ToString('N')+'.ps1')
$raw="https://raw.githubusercontent.com/$repo/$baseCommit/scripts/Install-iMonitorERP-v2.0.15-core.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"

try {
  Write-Host '=== iMonitor ERP CORE v2.0.19 ===' -ForegroundColor Cyan
  Write-Host 'Core revision : 2.0.19-r1 (independent channels + packaged appsettings)' -ForegroundColor DarkCyan
  Write-Host 'MySQL policy  : existing installation only; no download/install/update' -ForegroundColor Cyan
  Write-Host 'Test DB       : ecomm_dev'
  Write-Host 'Production DB : ecomm'
  Write-Host 'Migration     : deferred/disabled during installer run'
  Write-Host 'Channel policy: Test success is preserved even if Production fails.' -ForegroundColor Cyan

  & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $raw -o $source 2>$null
  $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
  if($ec -ne 0 -or -not(Test-Path $source -PathType Leaf) -or (Get-Item $source).Length -le 0){throw "Could not load base core. curl exit=$ec"}
  $text=Get-Content $source -Raw

  $oldCurl="            & `$curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.15' `$Uri -o `$OutFile`r`n            `$code = `$LASTEXITCODE"
  $newCurl="            & `$curl.Source -4 --http1.1 --silent --show-error --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.19' `$Uri -o `$OutFile 2>`$null`r`n            `$code = `$LASTEXITCODE"
  if(-not $text.Contains($oldCurl)){ $oldCurl=$oldCurl.Replace("`r`n","`n"); $newCurl=$newCurl.Replace("`r`n","`n") }
  if(-not $text.Contains($oldCurl)){throw 'Could not patch Invoke-CurlDownload in base core.'}
  $text=$text.Replace($oldCurl,$newCurl)

  $oldGetLatest=@'
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
  $newGetLatest=@'
function Get-LatestRelease([string]$Prefix) {
    $tmp = Join-Path $env:TEMP ('imonitor-releases-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-CurlDownload "https://api.github.com/repos/$repo/releases?per_page=100" $tmp 'Release metadata download over GitHub IPv4' 300 | Out-Null
        $json = Get-Content $tmp -Raw
        $escapedPrefix = [regex]::Escape($Prefix)
        $tagMatch = [regex]::Match($json, '"tag_name"\s*:\s*"(?<tag>' + $escapedPrefix + '[^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if(-not $tagMatch.Success) { throw "No release found for $Prefix" }
        $tagName = [string]$tagMatch.Groups['tag'].Value
        if([string]::IsNullOrWhiteSpace($tagName)) { throw "No valid release tag found for $Prefix" }
        $assetName='iMonitor-EcomERP-win-x64.zip'
        $downloadUrl="https://github.com/$repo/releases/download/$tagName/$assetName"
        Write-Host "Selected release: $tagName" -ForegroundColor Cyan
        return [pscustomobject]@{tag_name=$tagName;assets=@([pscustomobject]@{name=$assetName;browser_download_url=$downloadUrl})}
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
'@
  if(-not $text.Contains($oldGetLatest)){ $oldGetLatest=$oldGetLatest.Replace("`r`n","`n"); $newGetLatest=$newGetLatest.Replace("`r`n","`n") }
  if(-not $text.Contains($oldGetLatest)){throw 'Could not patch Get-LatestRelease.'}
  $text=$text.Replace($oldGetLatest,$newGetLatest)

  $oldDir='    $dir = Join-Path $PackageCacheDirectory $Release.tag_name'
  $newDir=@'
    if($Release -is [array]) { $Release = $Release | Select-Object -First 1 }
    $tagProp = $Release.PSObject.Properties['tag_name']
    if($null -eq $tagProp){throw 'Release object has no tag_name property.'}
    $tagName=[string]$tagProp.Value
    if([string]::IsNullOrWhiteSpace($tagName)){throw 'Release tag_name is empty or invalid.'}
    Write-Host "Release tag: $tagName" -ForegroundColor DarkCyan
    $dir = Join-Path -Path ([string]$PackageCacheDirectory) -ChildPath $tagName
'@
  if(-not $text.Contains($oldDir)){throw 'Could not patch Ensure-Package Join-Path block.'}
  $text=$text.Replace($oldDir,$newDir.TrimEnd())

  $oldCache="    if (Test-Path `$zip -PathType Leaf -and (Get-Item `$zip).Length -gt 5MB) {"
  $newCache="    if ((Test-Path `$zip -PathType Leaf) -and ((Get-Item `$zip).Length -gt 5MB)) {"
  if(-not $text.Contains($oldCache)){throw 'Could not patch Ensure-Package cache condition.'}
  $text=$text.Replace($oldCache,$newCache)

  $oldEnsure='    Ensure-DatabaseUser $Conn $Database $User $Password'
  $newEnsure=@'
    Write-Host "Checking existing MySQL database '$Database'..." -ForegroundColor Cyan
    if (-not (Test-MySqlLogin $Conn.Client $Conn.Host $Conn.Port $Conn.RootUser $Conn.RootPassword $Database)) {
        throw "Database '$Database' is not available with the configured MySQL account. Create it manually first, then rerun the installer. MySQL says: $($script:LastMySqlError)"
    }
    Write-Host "[OK] Existing database accessible: $Database" -ForegroundColor Green
'@
  if(-not $text.Contains($oldEnsure)){throw 'Could not patch database provisioning call.'}
  $text=$text.Replace($oldEnsure,$newEnsure.TrimEnd())

  $text=$text.Replace("Set-JsonValue `$databaseSettings 'AutoMigrate' `$true","Set-JsonValue `$databaseSettings 'AutoMigrate' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$true","Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'EnsureCreatedIfNotExists' `$true","Set-JsonValue `$databaseSettings 'EnsureCreatedIfNotExists' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'SeedDataOnMigrate' `$true","Set-JsonValue `$databaseSettings 'SeedDataOnMigrate' `$false")

  $oldBase=@'
function Get-BaseSettings([string]$Name,[string]$Destination) {
    $current = Join-Path (Join-Path $InstallRoot $Name.ToLowerInvariant()) 'current\appsettings.json'
    $legacy = Join-Path 'C:\ProgramData\iMonitorERP' ($Name.ToLowerInvariant() + '\current\appsettings.json')
    if (Test-Path $current -PathType Leaf) { Copy-Item $current $Destination -Force; return }
    if (Test-Path $legacy -PathType Leaf) { Copy-Item $legacy $Destination -Force; return }
    $branch = if ($Name -eq 'Production') { 'master' } else { 'test' }
    $uri = "https://raw.githubusercontent.com/alimirzae/Ecomm/$branch/Ecomm/appsettings.json?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Invoke-CurlDownload $uri $Destination "$Name base appsettings" 300
}
'@
  $newBase=@'
function Get-BaseSettings([string]$Name,[string]$Destination) {
    $current = Join-Path (Join-Path $InstallRoot $Name.ToLowerInvariant()) 'current\appsettings.json'
    $legacy = Join-Path 'C:\ProgramData\iMonitorERP' ($Name.ToLowerInvariant() + '\current\appsettings.json')
    if (Test-Path $current -PathType Leaf) { Copy-Item $current $Destination -Force; return }
    if (Test-Path $legacy -PathType Leaf) { Copy-Item $legacy $Destination -Force; return }
    if (Test-Path $Destination -PathType Leaf) { return }
    throw "$Name base appsettings is missing from both the package and existing installation."
}
'@
  if(-not $text.Contains($oldBase)){ $oldBase=$oldBase.Replace("`r`n","`n"); $newBase=$newBase.Replace("`r`n","`n") }
  if(-not $text.Contains($oldBase)){throw 'Could not patch Get-BaseSettings.'}
  $text=$text.Replace($oldBase,$newBase)

  $oldWrite=@'
    try {
        Get-BaseSettings $Name $temp
        $settings = Get-Content $temp -Raw | ConvertFrom-Json
'@
  $newWrite=@'
    try {
        if (Test-Path $Destination -PathType Leaf) { Copy-Item $Destination $temp -Force }
        else { Get-BaseSettings $Name $temp }
        $settings = Get-Content $temp -Raw | ConvertFrom-Json
'@
  if(-not $text.Contains($oldWrite)){ $oldWrite=$oldWrite.Replace("`r`n","`n"); $newWrite=$newWrite.Replace("`r`n","`n") }
  if(-not $text.Contains($oldWrite)){throw 'Could not patch Write-ChannelSettings package-base behavior.'}
  $text=$text.Replace($oldWrite,$newWrite)

  $oldTest="    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' `$TestPort `$conn.TestDatabase `$conn.TestUser `$conn.TestPassword `$conn"
  $newTest="    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' `$TestPort 'ecomm_dev' `$conn.RootUser `$conn.RootPassword `$conn"
  if(-not $text.Contains($oldTest)){throw 'Could not patch Test mapping.'}
  $text=$text.Replace($oldTest,$newTest)

  $oldProd="    Deploy-Channel 'Production' 'imonitor-ecomerp-production-v' `$ProductionPort `$conn.ProductionDatabase `$conn.ProductionUser `$conn.ProductionPassword `$conn"
  $newProd="    Deploy-Channel 'Production' 'imonitor-ecomerp-master-v' `$ProductionPort 'ecomm' `$conn.RootUser `$conn.RootPassword `$conn"
  if(-not $text.Contains($oldProd)){throw 'Could not patch Production mapping.'}
  $text=$text.Replace($oldProd,$newProd)

  $oldTail=@'
if ($Channel -in @('Both','Test')) {
    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' $TestPort $conn.TestDatabase $conn.TestUser $conn.TestPassword $conn
}
if ($Channel -in @('Both','Production')) {
    Deploy-Channel 'Production' 'imonitor-ecomerp-production-v' $ProductionPort $conn.ProductionDatabase $conn.ProductionUser $conn.TestPassword $conn
}

Write-Host '[OK] Installation completed.' -ForegroundColor Green
'@

  # The exact old tail varies because mapping replacements above happen first, so patch by smaller stable blocks.
  $testBlock="if (`$Channel -in @('Both','Test')) {`r`n    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' `$TestPort 'ecomm_dev' `$conn.RootUser `$conn.RootPassword `$conn`r`n}"
  if(-not $text.Contains($testBlock)){ $testBlock=$testBlock.Replace("`r`n","`n") }
  $prodBlock="if (`$Channel -in @('Both','Production')) {`r`n    Deploy-Channel 'Production' 'imonitor-ecomerp-master-v' `$ProductionPort 'ecomm' `$conn.RootUser `$conn.RootPassword `$conn`r`n}"
  if(-not $text.Contains($prodBlock)){ $prodBlock=$prodBlock.Replace("`r`n","`n") }
  if(-not $text.Contains($testBlock)){throw 'Could not locate final Test deployment block.'}
  if(-not $text.Contains($prodBlock)){throw 'Could not locate final Production deployment block.'}

  $newTestBlock=@'
$script:TestSucceeded = $false
if ($Channel -in @('Both','Test')) {
    try {
        Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' $TestPort 'ecomm_dev' $conn.RootUser $conn.RootPassword $conn
        $script:TestSucceeded = $true
    } catch {
        Write-Warning "Test deployment failed: $($_.Exception.Message)"
        if ($Channel -eq 'Test') { throw }
    }
}
'@
  $newProdBlock=@'
if ($Channel -in @('Both','Production')) {
    try {
        Deploy-Channel 'Production' 'imonitor-ecomerp-master-v' $ProductionPort 'ecomm' $conn.RootUser $conn.RootPassword $conn
    } catch {
        Write-Warning "Production deployment deferred: $($_.Exception.Message)"
        Write-Warning 'Test installation (if successful) remains active. The Production updater task will retry automatically every 5 minutes.'
        if ($Channel -eq 'Production') { throw }
    }
}
if ($Channel -eq 'Both' -and -not $script:TestSucceeded) {
    throw 'Test deployment did not succeed; installation cannot be considered successful.'
}
Write-Host '[OK] Installation completed. Available channels remain active; failed Production will be retried by updater.' -ForegroundColor Green
'@
  $text=$text.Replace($testBlock,$newTestBlock.TrimEnd())
  $text=$text.Replace($prodBlock,$newProdBlock.TrimEnd())

  $text=$text.Replace("Write-Host 'iMonitor ERP installer core v2.0.15' -ForegroundColor Cyan","Write-Host 'iMonitor ERP installer core v2.0.19' -ForegroundColor Cyan")
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
