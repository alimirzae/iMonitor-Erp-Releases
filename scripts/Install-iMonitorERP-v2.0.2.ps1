[CmdletBinding()]
param(
    [ValidateSet('Both','Test','Production')][string]$Channel = 'Both',
    [string]$InstallRoot = 'C:\ProgramData\iMonitorERP',
    [string]$PackageCacheDirectory = (Get-Location).Path,
    [int]$TestPort = 8081,
    [int]$ProductionPort = 8080,
    [string]$MySqlServer = '127.0.0.1',
    [int]$MySqlPort = 3306,
    [string]$TestDatabase = 'imonitor_erp_test',
    [string]$ProductionDatabase = 'imonitor_erp_production',
    [string]$TestUser = 'imonitor_test',
    [string]$ProductionUser = 'imonitor_production',
    [string]$TestPassword,
    [string]$ProductionPassword,
    [string]$MySqlAdminUser = 'root',
    [string]$MySqlAdminPassword,
    [string]$BootstrapAdminNationalCode = $env:IMONITOR_BOOTSTRAP_NATIONAL_CODE,
    [string]$BootstrapAdminMobile = $env:IMONITOR_BOOTSTRAP_MOBILE,
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
$mirrorRoot = 'https://testerp.imonitor.ir/downloads/erp'
$sourceStateRoot = Join-Path $InstallRoot 'state'
$sourcePreferenceFile = Join-Path $sourceStateRoot 'download-source.txt'
New-Item -ItemType Directory -Force -Path $sourceStateRoot | Out-Null

function Test-UrlLatency([string]$Uri,[bool]$ForceIpv4=$false) {
    try {
        $sw=[Diagnostics.Stopwatch]::StartNew()
        $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
        if($curl){
            $args=@('--silent','--show-error','--fail','--location','--head','--connect-timeout','3','--max-time','6')
            if($ForceIpv4){$args=@('-4')+$args}
            & $curl.Source @args $Uri | Out-Null
            if($LASTEXITCODE -ne 0){return [double]::PositiveInfinity}
        } else {
            Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Uri -TimeoutSec 6 | Out-Null
        }
        $sw.Stop(); return $sw.Elapsed.TotalMilliseconds
    } catch { return [double]::PositiveInfinity }
}

function Get-PreferredSource {
    $mirrorProbe="$mirrorRoot/test/latest.json?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $githubProbe="https://api.github.com/repos/$repo/releases?per_page=1&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $mirrorMs=Test-UrlLatency $mirrorProbe $false
    $githubMs=Test-UrlLatency $githubProbe $true
    Write-Host ("Download source probe: mirror={0} ms, github-ipv4={1} ms" -f ([math]::Round($mirrorMs)),([math]::Round($githubMs)))
    if([double]::IsPositiveInfinity($mirrorMs) -and [double]::IsPositiveInfinity($githubMs)){return 'mirror'}
    $selected=if($mirrorMs -le $githubMs){'mirror'}else{'github'}
    Set-Content $sourcePreferenceFile $selected -Encoding ASCII
    return $selected
}

function Invoke-SourceDownload([string]$MirrorUri,[string]$GithubUri,[string]$OutFile,[string]$Label) {
    $preferred=Get-PreferredSource
    $sources=if($preferred -eq 'mirror'){@(@('mirror',$MirrorUri,$false),@('github',$GithubUri,$true))}else{@(@('github',$GithubUri,$true),@('mirror',$MirrorUri,$false))}
    $last=$null
    foreach($source in $sources){
        $name=$source[0]; $uri=$source[1]; $ipv4=[bool]$source[2]
        try {
            Write-Host "$Label via $name..."
            $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
            if($curl){
                $args=@('--http1.1','--fail','--location','--connect-timeout','8','--max-time','120','--retry','3','--retry-all-errors',$uri,'-o',$OutFile)
                if($ipv4){$args=@('-4')+$args}
                & $curl.Source @args
                if($LASTEXITCODE -ne 0){throw "curl exit code $LASTEXITCODE"}
            } else {
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $OutFile -TimeoutSec 120
            }
            if(!(Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0){throw 'Downloaded file is empty.'}
            Set-Content $sourcePreferenceFile $name -Encoding ASCII
            return
        } catch {
            $last=$_.Exception.Message
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            Write-Warning "$Label via $name failed: $last"
        }
    }
    throw "$Label failed from domestic mirror and GitHub IPv4. Last error: $last"
}

$baseInstaller = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.1-hardened.ps1'
Invoke-SourceDownload `
    "$mirrorRoot/install/Install-iMonitorERP-v2.0.1.ps1.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.1.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    $baseInstaller 'Base installer download'

# Keep all verified v2.0.1 install/cache/MySQL/IIS behavior, but route release discovery and assets
# through the fastest healthy source. GitHub is explicitly forced to IPv4.
$text = Get-Content $baseInstaller -Raw
$needle = "Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$true"
$replacement = "Set-JsonValue `$databaseSettings 'MigrateOnStartup' `$false"
if (-not $text.Contains($needle)) { throw 'Compatibility check failed: MigrateOnStartup assignment was not found in v2.0.1.' }
$text = $text.Replace($needle, $replacement)

$healthNeedle = '$url = "http://127.0.0.1:$Port/"'
$healthReplacement = '$url = "http://127.0.0.1:$Port/health"'
if (-not $text.Contains($healthNeedle)) { throw 'Compatibility check failed: IIS health URL was not found in v2.0.1.' }
$text = $text.Replace($healthNeedle, $healthReplacement)

$releaseNeedle = '$releases = Invoke-RestMethod -Headers @{Accept=''application/vnd.github+json''} -Uri "https://api.github.com/repos/$repo/releases?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"'
$releaseReplacement = @'
function Get-DomesticMirrorCatalog {
    $items = @()
    foreach ($c in @('test','master')) {
        $manifestUri = "https://testerp.imonitor.ir/downloads/erp/$c/latest.json?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $m = Invoke-RestMethod -Uri $manifestUri -TimeoutSec 8
        $items += [pscustomobject]@{
            draft = $false
            prerelease = ($c -eq 'test')
            tag_name = [string]$m.tag
            published_at = [string]$m.publishedAt
            created_at = [string]$m.publishedAt
            assets = @(
                [pscustomobject]@{ name=$assetName; browser_download_url="https://testerp.imonitor.ir/downloads/erp/$c/$assetName" },
                [pscustomobject]@{ name="$assetName.sha256"; browser_download_url="https://testerp.imonitor.ir/downloads/erp/$c/$assetName.sha256.txt" }
            )
        }
    }
    return $items
}
function Get-GitHubCatalogIpv4 {
    $tmp=Join-Path $env:TEMP ("imonitor-releases-"+[guid]::NewGuid().ToString('N')+'.json')
    try {
        $uri="https://api.github.com/repos/$repo/releases?per_page=100&cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
        if($curl){
            & $curl.Source -4 --http1.1 --fail --location --connect-timeout 8 --max-time 30 --retry 2 --retry-all-errors -H 'Accept: application/vnd.github+json' -H 'User-Agent: iMonitorERP-Installer' $uri -o $tmp
            if($LASTEXITCODE -ne 0){throw "curl exit code $LASTEXITCODE"}
            return (Get-Content $tmp -Raw | ConvertFrom-Json)
        }
        return Invoke-RestMethod -Headers @{Accept='application/vnd.github+json'} -Uri $uri -TimeoutSec 30
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
$mirrorCatalog=$null; $githubCatalog=$null
$mirrorMs=[double]::PositiveInfinity; $githubMs=[double]::PositiveInfinity
try { $sw=[Diagnostics.Stopwatch]::StartNew(); $mirrorCatalog=Get-DomesticMirrorCatalog; $sw.Stop(); $mirrorMs=$sw.Elapsed.TotalMilliseconds } catch { Write-Warning "Domestic mirror metadata unavailable: $($_.Exception.Message)" }
try { $sw=[Diagnostics.Stopwatch]::StartNew(); $githubCatalog=Get-GitHubCatalogIpv4; $sw.Stop(); $githubMs=$sw.Elapsed.TotalMilliseconds } catch { Write-Warning "GitHub IPv4 metadata unavailable: $($_.Exception.Message)" }
if($mirrorCatalog -and ($mirrorMs -le $githubMs -or -not $githubCatalog)){
    $releases=$mirrorCatalog
    Write-Host ("Release source selected: domestic mirror ({0:N0} ms)" -f $mirrorMs)
} elseif($githubCatalog) {
    $releases=$githubCatalog
    Write-Host ("Release source selected: GitHub over IPv4 ({0:N0} ms)" -f $githubMs)
} else { throw 'No release metadata source is available (domestic mirror and GitHub IPv4 both failed).' }
'@
if (-not $text.Contains($releaseNeedle)) { throw 'Compatibility check failed: release catalog line was not found in v2.0.1.' }
$text = $text.Replace($releaseNeedle, $releaseReplacement)
Set-Content $baseInstaller $text -Encoding UTF8

$invoke = @{
    Channel=$Channel; InstallRoot=$InstallRoot; PackageCacheDirectory=$PackageCacheDirectory;
    TestPort=$TestPort; ProductionPort=$ProductionPort; MySqlServer=$MySqlServer; MySqlPort=$MySqlPort;
    TestDatabase=$TestDatabase; ProductionDatabase=$ProductionDatabase; TestUser=$TestUser; ProductionUser=$ProductionUser;
    MySqlAdminUser=$MySqlAdminUser
}
if ($TestPassword) { $invoke.TestPassword=$TestPassword }
if ($ProductionPassword) { $invoke.ProductionPassword=$ProductionPassword }
if ($MySqlAdminPassword) { $invoke.MySqlAdminPassword=$MySqlAdminPassword }
if ($SkipMySqlProvisioning) { $invoke.SkipMySqlProvisioning=$true }
if ($UpdateOnly) { $invoke.UpdateOnly=$true }
if ($Force) { $invoke.Force=$true }
try { & $baseInstaller @invoke } finally { Remove-Item $baseInstaller -Force -ErrorAction SilentlyContinue }

function Ensure-Object([object]$Parent,[string]$Name) {
    $p=$Parent.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { $v=[pscustomobject]@{}; if($p){$p.Value=$v}else{$Parent|Add-Member NoteProperty $Name $v}; return $v }
    return $p.Value
}
function Set-Value([object]$Parent,[string]$Name,[object]$Value) {
    $p=$Parent.PSObject.Properties[$Name]; if($p){$p.Value=$Value}else{$Parent|Add-Member NoteProperty $Name $Value}
}
function Find-InstalledMySqlClient {
    $command = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($root in @($env:ProgramFiles)) {
        if (-not $root) { continue }
        $mysqlRoot = Join-Path $root 'MySQL'
        if (-not (Test-Path $mysqlRoot)) { continue }
        $candidate = Get-ChildItem $mysqlRoot -Filter mysql.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}
$mysqlClientPath = Find-InstalledMySqlClient

function Harden-Config([string]$Name) {
    $path=Join-Path $InstallRoot (Join-Path $Name.ToLowerInvariant() 'current\appsettings.json')
    if(-not(Test-Path $path)){return}
    $settings=Get-Content $path -Raw|ConvertFrom-Json
    $database=Ensure-Object $settings 'Database'
    Set-Value $database 'MigrateOnStartup' $false
    Set-Value $database 'AutoMigrate' $false
    if($mysqlClientPath){Set-Value $database 'MySqlClientPath' $mysqlClientPath}
    $maintenance=Ensure-Object $settings 'Maintenance'
    Set-Value $maintenance 'OtpExpiryMinutes' 5
    Set-Value $maintenance 'AuthorizationMinutes' 15
    Set-Value $maintenance 'MaxOtpAttempts' 5
    Set-Value $maintenance 'ResendCooldownSeconds' 60
    $sms=Ensure-Object $settings 'SMS'
    Set-Value $sms 'AllowSystemFallbackWhenDatabaseUnavailable' $true
    $bootstrap=Ensure-Object $settings 'BootstrapAdmin'
    if($BootstrapAdminNationalCode){Set-Value $bootstrap 'NationalCode' $BootstrapAdminNationalCode.Trim()}
    if($BootstrapAdminMobile){Set-Value $bootstrap 'Mobile' $BootstrapAdminMobile.Trim()}
    $settings|ConvertTo-Json -Depth 100|Set-Content $path -Encoding UTF8
}
if($Channel -in @('Both','Test')){Harden-Config 'Test'}
if($Channel -in @('Both','Production')){Harden-Config 'Production'}

Import-Module WebAdministration -ErrorAction SilentlyContinue
foreach($name in @('Test','Production')){
    if($Channel -ne 'Both' -and $Channel -ne $name){continue}
    $pool="iMonitorERP-$name"
    if(Test-Path "IIS:\AppPools\$pool"){Restart-WebAppPool -Name $pool}
}

$installerHome=Join-Path $InstallRoot 'installer'
New-Item -ItemType Directory -Force -Path $installerHome|Out-Null
$self=Join-Path $installerHome 'Install-iMonitorERP-v2.0.2.ps1'
Invoke-SourceDownload `
    "$mirrorRoot/install/Install-iMonitorERP-v2.0.2.ps1.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    "https://raw.githubusercontent.com/$repo/main/scripts/Install-iMonitorERP-v2.0.2.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" `
    $self 'Installer self-refresh'
$testAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Test -UpdateOnly"
$prodAction="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$self`" -Channel Production -UpdateOnly"
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Test' /SC MINUTE /MO 5 /RU SYSTEM /TR $testAction|Out-Null
& schtasks.exe /Create /F /TN 'iMonitorERP-Update-Production' /SC MINUTE /MO 5 /RU SYSTEM /TR $prodAction|Out-Null

Write-Host 'iMonitor ERP installer v2.0.2 completed.'
Write-Host "Production: http://localhost:$ProductionPort"
Write-Host "Test: http://localhost:$TestPort"
Write-Host "Preferred download source is persisted at: $sourcePreferenceFile"
Write-Host 'Emergency recovery: /Admin/Database/Migrate, /Admin/Database/Recovery or /Account/Reset'
