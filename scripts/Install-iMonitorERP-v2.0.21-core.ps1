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
$pinnedCommit='2e2df7b5583933df4ad4e52fe88d4d1b3e341434'
$pinned=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.21-pinned-'+[guid]::NewGuid().ToString('N')+'.ps1')
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/$pinnedCommit/scripts/Install-iMonitorERP-v2.0.20-core.ps1?cb=$cb"

function Write-RecentIisDiagnostics([string]$Name,[string]$Root) {
    Write-Host "--- Recent IIS/ASP.NET Core diagnostics for $Name ---" -ForegroundColor Yellow
    try {
        Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'IIS|AspNetCore|Application Error|\.NET Runtime' } |
            Select-Object -First 12 TimeCreated,ProviderName,Id,LevelDisplayName,Message |
            Format-List | Out-String | Write-Host
    } catch {}
    try {
        Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'WAS|W3SVC' } |
            Select-Object -First 12 TimeCreated,ProviderName,Id,LevelDisplayName,Message |
            Format-List | Out-String | Write-Host
    } catch {}
    $logs=Join-Path $Root 'logs'
    if(Test-Path $logs -PathType Container) {
        $stdout=Get-ChildItem $logs -Filter 'stdout_*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if($stdout) {
            Write-Host "ANCM stdout log: $($stdout.FullName)" -ForegroundColor Yellow
            try { Get-Content $stdout.FullName -Tail 120 | Write-Host } catch {}
        } else {
            Write-Host "ANCM stdout directory: $logs (no stdout file created yet)" -ForegroundColor Yellow
        }
    }
}

function Repair-ChannelIis([string]$Name,[int]$Port) {
    Import-Module WebAdministration -ErrorAction Stop
    $site="iMonitorERP-$Name"
    $pool=$site
    $root=Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) $Name.ToLowerInvariant()) 'current'
    $webConfig=Join-Path $root 'web.config'
    $logs=Join-Path $root 'logs'

    if(-not(Test-Path "IIS:\Sites\$site")){ Write-Warning "$Name IIS site does not exist: $site"; return $false }
    if(-not(Test-Path "IIS:\AppPools\$pool")){ Write-Warning "$Name IIS app pool does not exist: $pool"; return $false }
    if(-not(Test-Path $root -PathType Container)){ Write-Warning "$Name application root does not exist: $root"; return $false }

    New-Item -ItemType Directory -Force -Path $logs | Out-Null

    # ASP.NET Core 8 under IIS should use No Managed Code + Integrated pipeline.
    Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$pool" -Name managedPipelineMode -Value 'Integrated'
    Set-ItemProperty "IIS:\AppPools\$pool" -Name autoStart -Value $true
    Set-ItemProperty "IIS:\AppPools\$pool" -Name startMode -Value 'AlwaysRunning'
    Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.identityType -Value 'ApplicationPoolIdentity'
    Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.loadUserProfile -Value $true
    Set-ItemProperty "IIS:\Sites\$site" -Name serverAutoStart -Value $true
    Set-ItemProperty "IIS:\Sites\$site" -Name applicationPool -Value $pool
    Set-ItemProperty "IIS:\Sites\$site" -Name physicalPath -Value $root

    # Ensure the dedicated AppPool identity can read/run the app and write App_Data/stdout logs.
    try {
        $acl=Get-Acl $root
        $rule=New-Object Security.AccessControl.FileSystemAccessRule("IIS AppPool\$pool",'Modify','ContainerInherit,ObjectInherit','None','Allow')
        $acl.SetAccessRule($rule)
        Set-Acl $root $acl
        Write-Host "[OK] $Name filesystem ACL granted to IIS AppPool\$pool" -ForegroundColor Green
    } catch { Write-Warning "$Name ACL repair failed: $($_.Exception.Message)" }

    # Normalize HTTP binding: all IPv4/IPv6 hostnames on the channel port, no Host Header.
    try {
        Get-WebBinding -Name $site -Protocol http -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
        New-WebBinding -Name $site -Protocol http -IPAddress '*' -Port $Port -HostHeader '' | Out-Null
    } catch { Write-Warning "$Name binding repair failed: $($_.Exception.Message)" }

    # Enable temporary ANCM stdout diagnostics. The updater may leave this enabled until stability is proven.
    if(Test-Path $webConfig -PathType Leaf) {
        try {
            [xml]$xml=Get-Content $webConfig -Raw
            $node=$xml.configuration.'system.webServer'.aspNetCore
            if($null -ne $node) {
                $node.SetAttribute('hostingModel','inprocess')
                $node.SetAttribute('stdoutLogEnabled','true')
                $node.SetAttribute('stdoutLogFile','.\logs\stdout')
                $xml.Save($webConfig)
                Write-Host "[OK] $Name ANCM stdout logging enabled: $logs\stdout_*.log" -ForegroundColor Green
            }
        } catch { Write-Warning "$Name web.config diagnostics setup failed: $($_.Exception.Message)" }
    }

    # Stop first to clear stale worker state, then start app pool/site explicitly.
    try { if((Get-WebsiteState $site).Value -eq 'Started'){ Stop-Website $site -ErrorAction SilentlyContinue } } catch {}
    try { if((Get-WebAppPoolState $pool).Value -eq 'Started'){ Stop-WebAppPool $pool -ErrorAction SilentlyContinue } } catch {}
    Start-Sleep -Seconds 2
    try { Start-WebAppPool $pool -ErrorAction Stop } catch { Write-Warning "$Name AppPool start failed: $($_.Exception.Message)" }
    try { Start-Website $site -ErrorAction Stop } catch { Write-Warning "$Name site start failed: $($_.Exception.Message)" }

    $poolState='Unknown'; $siteState='Unknown'
    try { $poolState=(Get-WebAppPoolState $pool).Value } catch {}
    try { $siteState=(Get-WebsiteState $site).Value } catch {}
    Write-Host "${Name} IIS state: Site=$siteState; AppPool=$poolState; Binding=*:${Port}:" -ForegroundColor Cyan

    for($i=1;$i -le 12;$i++) {
        Start-Sleep -Seconds 2
        try {
            $poolState=(Get-WebAppPoolState $pool).Value
            if($poolState -ne 'Started') {
                Write-Warning "$Name AppPool stopped during startup (attempt $i/12)."
                break
            }
            $r=Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 8
            if($r.StatusCode -eq 200) {
                Write-Host "[OK] $Name IIS health HTTP 200 on 127.0.0.1:$Port" -ForegroundColor Green
                return $true
            }
        } catch {
            if($i -eq 12){ Write-Warning "$Name IIS health failed: $($_.Exception.Message)" }
        }
    }

    Write-RecentIisDiagnostics $Name $root
    Write-Warning "$Name remains unavailable. Diagnostic paths: $logs and C:\inetpub\logs\LogFiles"
    return $false
}

try {
    Write-Host '=== iMonitor ERP CORE v2.0.21 ===' -ForegroundColor Cyan
    Write-Host 'Core revision : 2.0.21-r1 (AppPool recovery + ANCM diagnostics)' -ForegroundColor DarkCyan

    & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $uri -o $pinned 2>$null
    $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
    if($ec -ne 0 -or -not(Test-Path $pinned -PathType Leaf)){throw "Could not download pinned v2.0.20 core. curl exit=$ec"}

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

    $testOk=$true; $prodOk=$true
    if($Channel -in @('Both','Test')) { $testOk=Repair-ChannelIis 'Test' $TestPort }
    if($Channel -in @('Both','Production')) { $prodOk=Repair-ChannelIis 'Production' $ProductionPort }

    if($Channel -eq 'Test' -and -not $testOk){ exit 21 }
    if($Channel -eq 'Production' -and -not $prodOk){ exit 22 }
    if($Channel -eq 'Both' -and -not $testOk){
        Write-Warning 'Production may remain available, but Test is unhealthy. Scheduled Test updater will retry every 5 minutes.'
        exit 21
    }
    if($baseExit -ne 0 -and $Channel -ne 'Both'){ exit $baseExit }
    exit 0
}
finally { Remove-Item $pinned -Force -ErrorAction SilentlyContinue }
