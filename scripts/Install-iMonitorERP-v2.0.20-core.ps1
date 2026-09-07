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
$pinnedCommit='1e5663ad6910dfc4d1f0be90b59a23d51c31472f'
$pinned=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.20-pinned-'+[guid]::NewGuid().ToString('N')+'.ps1')
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/$pinnedCommit/scripts/Install-iMonitorERP-v2.0.19-core.ps1?cb=$cb"

function Normalize-Channel([string]$Name,[int]$Port) {
    Import-Module WebAdministration -ErrorAction Stop
    $site="iMonitorERP-$Name"
    $pool=$site
    $root=Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) $Name.ToLowerInvariant()) 'current'
    $settings=Join-Path $root 'appsettings.json'
    $webConfig=Join-Path $root 'web.config'

    if (Test-Path $settings -PathType Leaf) {
        try {
            $json=Get-Content $settings -Raw | ConvertFrom-Json
            $prop=$json.PSObject.Properties['AllowedHosts']
            if($prop){$prop.Value='*'} else {$json | Add-Member NoteProperty AllowedHosts '*'}
            $json | ConvertTo-Json -Depth 40 | Set-Content $settings -Encoding UTF8
            Write-Host "[OK] $Name AllowedHosts=*" -ForegroundColor Green
        } catch { Write-Warning "$Name appsettings AllowedHosts normalization failed: $($_.Exception.Message)" }
    }

    if(Test-Path "IIS:\Sites\$site") {
        try {
            Get-WebBinding -Name $site -Protocol http -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
            New-WebBinding -Name $site -Protocol http -IPAddress '*' -Port $Port -HostHeader '' | Out-Null
            Set-ItemProperty "IIS:\Sites\$site" -Name physicalPath -Value $root
            Write-Host "[OK] $Name IIS binding normalized to *:$Port (no host header)." -ForegroundColor Green
        } catch { Write-Warning "$Name IIS binding normalization failed: $($_.Exception.Message)" }
    }

    if(Test-Path "IIS:\AppPools\$pool") {
        try {
            Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
            Set-ItemProperty "IIS:\AppPools\$pool" -Name managedPipelineMode -Value 'Integrated'
            Write-Host "[OK] $Name AppPool = No Managed Code / Integrated." -ForegroundColor Green
        } catch { Write-Warning "$Name AppPool normalization failed: $($_.Exception.Message)" }
    }

    if(Test-Path $webConfig -PathType Leaf) {
        try {
            [xml]$xml=Get-Content $webConfig -Raw
            $node=$xml.configuration.'system.webServer'.aspNetCore
            if($null -ne $node) {
                $node.SetAttribute('hostingModel','inprocess')
                $xml.Save($webConfig)
                Write-Host "[OK] $Name web.config ASP.NET Core hostingModel=inprocess." -ForegroundColor Green
            }
        } catch { Write-Warning "$Name web.config normalization failed: $($_.Exception.Message)" }
    } else { Write-Warning "$Name web.config not found at $webConfig" }

    try { Restart-WebAppPool $pool -ErrorAction SilentlyContinue } catch {}
    try { Restart-WebItem "IIS:\Sites\$site" -ErrorAction SilentlyContinue } catch {}

    try {
        $r=Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 15
        Write-Host "[OK] $Name IIS health HTTP $($r.StatusCode) on 127.0.0.1:$Port" -ForegroundColor Green
    } catch { Write-Warning "$Name IIS health after normalization: $($_.Exception.Message)" }
}

try {
    Write-Host '=== iMonitor ERP CORE v2.0.20 ===' -ForegroundColor Cyan
    Write-Host 'Core revision : 2.0.20-r1 (IIS binding + AllowedHosts + ANCM normalization)' -ForegroundColor DarkCyan
    & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $uri -o $pinned 2>$null
    $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
    if($ec -ne 0 -or -not(Test-Path $pinned -PathType Leaf)){throw "Could not download pinned v2.0.19 core. curl exit=$ec"}

    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$pinned,'-Channel',$Channel,'-InstallRoot',$InstallRoot,'-PackageCacheDirectory',$PackageCacheDirectory,'-TestPort',[string]$TestPort,'-ProductionPort',[string]$ProductionPort)
    if($MySqlBinPath){$args+=@('-MySqlBinPath',$MySqlBinPath)}
    if($MySqlHost){$args+=@('-MySqlHost',$MySqlHost)}
    if($MySqlPort -gt 0){$args+=@('-MySqlPort',[string]$MySqlPort)}
    if($MySqlRootUser){$args+=@('-MySqlRootUser',$MySqlRootUser)}
    if($MySqlRootPassword){$args+=@('-MySqlRootPassword',$MySqlRootPassword)}
    if($Force){$args+='-Force'}
    if($UpdateOnly){$args+='-UpdateOnly'}

    $p=Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    $baseExit=$p.ExitCode

    if($Channel -in @('Both','Test')) { Normalize-Channel 'Test' $TestPort }
    if($Channel -in @('Both','Production')) { Normalize-Channel 'Production' $ProductionPort }

    if($baseExit -ne 0 -and $Channel -ne 'Both'){ exit $baseExit }
    exit 0
}
finally { Remove-Item $pinned -Force -ErrorAction SilentlyContinue }
