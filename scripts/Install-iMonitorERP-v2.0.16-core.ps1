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
$patched=Join-Path $env:TEMP ('imonitor-core-v2016-'+[guid]::NewGuid().ToString('N')+'.ps1')
$raw="https://raw.githubusercontent.com/$repo/$baseCommit/scripts/Install-iMonitorERP-v2.0.15-core.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"

try {
  Write-Host '=== iMonitor ERP CORE v2.0.16 ===' -ForegroundColor Cyan
  Write-Host 'Database mode: pre-created databases; migrations deferred.' -ForegroundColor Cyan
  Write-Host 'Test DB      : ecomm_dev'
  Write-Host 'Production DB: ecomm'
  Write-Host 'Loading base installer logic for v2.0.16...' -ForegroundColor Cyan

  & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors $raw -o $source 2>$null
  $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
  if($ec -ne 0 -or -not(Test-Path $source -PathType Leaf) -or (Get-Item $source).Length -le 0){throw "Could not load base core. curl exit=$ec"}
  $text=Get-Content $source -Raw

  # Native curl output must never pollute PowerShell function output.
  $oldCurl="            & `$curl.Source -4 --http1.1 --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.15' `$Uri -o `$OutFile`r`n            `$code = `$LASTEXITCODE"
  $newCurl="            & `$curl.Source -4 --http1.1 --silent --show-error --fail --location --connect-timeout 10 --max-time `$MaxTime --retry 2 --retry-all-errors -H 'User-Agent: iMonitorERP-Installer/2.0.16' `$Uri -o `$OutFile 2>`$null`r`n            `$code = `$LASTEXITCODE"
  if(-not $text.Contains($oldCurl)) { $oldCurl=$oldCurl.Replace("`r`n","`n"); $newCurl=$newCurl.Replace("`r`n","`n") }
  if(-not $text.Contains($oldCurl)){throw 'Could not patch Invoke-CurlDownload in base core.'}
  $text=$text.Replace($oldCurl,$newCurl)

  # Return exactly one release object.
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
  if(-not $text.Contains($old)){ $old=$old.Replace("`r`n","`n"); $new=$new.Replace("`r`n","`n") }
  if(-not $text.Contains($old)){throw 'Could not patch Get-LatestRelease in base core.'}
  $text=$text.Replace($old,$new)

  # Never pass an object-valued property expression directly to Join-Path.
  $old2='    $dir = Join-Path $PackageCacheDirectory $Release.tag_name'
  $new2=@'
    if($Release -is [array]) { $Release = $Release | Select-Object -First 1 }
    $tagProp = $Release.PSObject.Properties['tag_name']
    if($null -eq $tagProp) { throw 'Release object has no tag_name property.' }
    $tagName = [string]$tagProp.Value
    if([string]::IsNullOrWhiteSpace($tagName)) { throw 'Release tag_name is empty or invalid.' }
    Write-Host "Release tag: $tagName" -ForegroundColor DarkCyan
    $dir = Join-Path -Path ([string]$PackageCacheDirectory) -ChildPath $tagName
'@
  if(-not $text.Contains($old2)){throw 'Could not patch Ensure-Package Join-Path block.'}
  $text=$text.Replace($old2,$new2.TrimEnd())

  # Do not create databases/users or grant privileges. Only verify that the user-created DB exists and is accessible.
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

  # Defer every schema-changing action to a later explicit step.
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'AutoMigrate' `$true","Set-JsonValue `$databaseSettings 'AutoMigrate' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$true","Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'EnsureCreatedIfNotExists' `$true","Set-JsonValue `$databaseSettings 'EnsureCreatedIfNotExists' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'SeedDataOnMigrate' `$true","Set-JsonValue `$databaseSettings 'SeedDataOnMigrate' `$false")
  $text=$text.Replace("Set-JsonValue `$databaseSettings 'DropDatabaseOnStartup' `$false","Set-JsonValue `$databaseSettings 'DropDatabaseOnStartup' `$false")

  # Use the already-validated MySQL account for the initial appsettings connection.
  # DB names are fixed by convention: ecomm_dev=test, ecomm=production.
  $oldTest="    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' `$TestPort `$conn.TestDatabase `$conn.TestUser `$conn.TestPassword `$conn"
  $newTest="    Deploy-Channel 'Test' 'imonitor-ecomerp-test-v' `$TestPort 'ecomm_dev' `$conn.RootUser `$conn.RootPassword `$conn"
  if(-not $text.Contains($oldTest)){throw 'Could not patch Test database mapping.'}
  $text=$text.Replace($oldTest,$newTest)

  $oldProd="    Deploy-Channel 'Production' 'imonitor-ecomerp-production-v' `$ProductionPort `$conn.ProductionDatabase `$conn.ProductionUser `$conn.ProductionPassword `$conn"
  $newProd="    Deploy-Channel 'Production' 'imonitor-ecomerp-production-v' `$ProductionPort 'ecomm' `$conn.RootUser `$conn.RootPassword `$conn"
  if(-not $text.Contains($oldProd)){throw 'Could not patch Production database mapping.'}
  $text=$text.Replace($oldProd,$newProd)

  $text=$text.Replace("Write-Host 'iMonitor ERP installer core v2.0.15' -ForegroundColor Cyan","Write-Host 'iMonitor ERP installer core v2.0.16' -ForegroundColor Cyan")
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
