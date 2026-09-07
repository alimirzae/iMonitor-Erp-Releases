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
$pinnedCommit='c2e696ffb3fb9a5070eb1ad3b7d2278f70c5c5be'
$pinned=Join-Path $env:TEMP ('Install-iMonitorERP-v2.0.23-core-'+[guid]::NewGuid().ToString('N')+'.ps1')
$backupRoot=Join-Path $env:TEMP ('imonitor-config-backup-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$cb=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$uri="https://raw.githubusercontent.com/$repo/$pinnedCommit/scripts/Install-iMonitorERP-v2.0.23-core.ps1?cb=$cb"

function Get-ChannelInfo([string]$Name) {
    $lower=$Name.ToLowerInvariant()
    [pscustomobject]@{
        Name=$Name
        Site="iMonitorERP-$Name"
        Pool="iMonitorERP-$Name"
        Root=(Join-Path (Join-Path ([IO.Path]::GetFullPath($InstallRoot)) $lower) 'current')
        Database=$(if($Name -eq 'Test'){'ecomm_dev'}else{'ecomm'})
        Port=$(if($Name -eq 'Test'){$TestPort}else{$ProductionPort})
    }
}

function Stop-ChannelForActivation($info) {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if(Test-Path "IIS:\Sites\$($info.Site)") {
            try { Stop-Website $info.Site -ErrorAction SilentlyContinue } catch {}
        }
        if(Test-Path "IIS:\AppPools\$($info.Pool)") {
            try { Stop-WebAppPool $info.Pool -ErrorAction SilentlyContinue } catch {}
        }
        Start-Sleep -Seconds 2
        Write-Host "[OK] $($info.Name) IIS stopped before package activation." -ForegroundColor Green
    } catch {
        Write-Warning "$($info.Name) IIS pre-stop failed: $($_.Exception.Message)"
    }
}

function Backup-ChannelSettings($info) {
    $src=Join-Path $info.Root 'appsettings.json'
    $dst=Join-Path $backupRoot ($info.Name.ToLowerInvariant()+'-appsettings.json')
    if(Test-Path $src -PathType Leaf) {
        Copy-Item $src $dst -Force
        Write-Host "[OK] $($info.Name) appsettings preserved before activation." -ForegroundColor Green
        return $dst
    }
    return $null
}

function Set-ObjectProperty($obj,[string]$name,$value) {
    $p=$obj.PSObject.Properties[$name]
    if($p){$p.Value=$value}else{$obj | Add-Member -NotePropertyName $name -NotePropertyValue $value}
}

function Force-MySqlSettings($info,[string]$backupPath) {
    $settings=Join-Path $info.Root 'appsettings.json'
    if(-not(Test-Path $settings -PathType Leaf)) {
        Write-Warning "$($info.Name) appsettings.json not found after activation: $settings"
        return $false
    }

    try {
        $json=Get-Content $settings -Raw | ConvertFrom-Json
        $backup=$null
        if($backupPath -and (Test-Path $backupPath -PathType Leaf)) {
            try { $backup=Get-Content $backupPath -Raw | ConvertFrom-Json } catch {}
        }

        if(-not $json.PSObject.Properties['Database']) {
            $json | Add-Member -NotePropertyName Database -NotePropertyValue ([pscustomobject]@{})
        }
        $db=$json.Database
        Set-ObjectProperty $db 'Type' 'MySql'
        foreach($flag in @('AutoMigrate','MigrateOnStartup','UseBackgroundMigration','EnsureCreatedIfNotExists','SeedDataOnMigrate')) {
            Set-ObjectProperty $db $flag $false
        }
        Set-ObjectProperty $db 'DropDatabaseOnStartup' $false

        $mysql=$null
        if($db.PSObject.Properties['MySql']) {$mysql=$db.MySql}
        if(($null -eq $mysql) -and $backup -and $backup.PSObject.Properties['Database'] -and $backup.Database.PSObject.Properties['MySql']) {
            $mysql=$backup.Database.MySql
            $db | Add-Member -NotePropertyName MySql -NotePropertyValue $mysql
        }
        if($null -eq $mysql) {
            $mysql=[pscustomobject]@{}
            $db | Add-Member -NotePropertyName MySql -NotePropertyValue $mysql
        }

        $hostValue=if($MySqlHost){$MySqlHost}elseif($mysql.PSObject.Properties['Server'] -and $mysql.Server){[string]$mysql.Server}else{'localhost'}
        $portValue=if($MySqlPort -gt 0){$MySqlPort}elseif($mysql.PSObject.Properties['Port'] -and $mysql.Port){[int]$mysql.Port}else{3306}
        $userValue=if($MySqlRootUser){$MySqlRootUser}elseif($mysql.PSObject.Properties['UserId'] -and $mysql.UserId){[string]$mysql.UserId}else{''}
        $passValue=if($MySqlRootPassword){$MySqlRootPassword}elseif($mysql.PSObject.Properties['Password']){[string]$mysql.Password}else{''}

        Set-ObjectProperty $mysql 'Server' $hostValue
        Set-ObjectProperty $mysql 'Port' $portValue
        Set-ObjectProperty $mysql 'UserId' $userValue
        if($passValue){Set-ObjectProperty $mysql 'Password' $passValue}

        $existingCs=''
        if($mysql.PSObject.Properties['ConnectionString'] -and $mysql.ConnectionString){$existingCs=[string]$mysql.ConnectionString}
        if($userValue -and $passValue) {
            $cs="Server=$hostValue;Port=$portValue;Database=$($info.Database);User=$userValue;Password=$passValue;"
        } elseif($existingCs) {
            if($existingCs -match '(?i)(Database|Initial Catalog)\s*=') {
                $cs=[regex]::Replace($existingCs,'(?i)(Database|Initial Catalog)\s*=\s*[^;]*',"Database=$($info.Database)")
            } else {
                $cs=$existingCs.TrimEnd(';')+";Database=$($info.Database);"
            }
        } else {
            throw 'No usable MySQL credentials/connection string were found in current or preserved appsettings.'
        }
        Set-ObjectProperty $mysql 'ConnectionString' $cs
        Set-ObjectProperty $json 'AllowedHosts' '*'

        $tmp=$settings+'.v2.0.24.tmp'
        $json | ConvertTo-Json -Depth 60 | Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $settings -Force
        Write-Host "[OK] $($info.Name) database forced to MySql / $($info.Database); startup migrations disabled." -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "$($info.Name) MySQL appsettings repair failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-And-VerifyChannel($info) {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if(Test-Path "IIS:\AppPools\$($info.Pool)") { Start-WebAppPool $info.Pool -ErrorAction SilentlyContinue }
        if(Test-Path "IIS:\Sites\$($info.Site)") { Start-Website $info.Site -ErrorAction SilentlyContinue }
    } catch {}

    for($i=1;$i -le 12;$i++) {
        Start-Sleep -Seconds 2
        try {
            $r=Invoke-WebRequest "http://127.0.0.1:$($info.Port)/health" -UseBasicParsing -TimeoutSec 8
            if($r.StatusCode -eq 200) {
                Write-Host "[OK] $($info.Name) healthy on 127.0.0.1:$($info.Port)." -ForegroundColor Green
                return $true
            }
        } catch {
            if($i -eq 12){Write-Warning "$($info.Name) health failed after MySQL repair: $($_.Exception.Message)"}
        }
    }
    return $false
}

$selected=@()
if($Channel -in @('Both','Test')){$selected+=Get-ChannelInfo 'Test'}
if($Channel -in @('Both','Production')){$selected+=Get-ChannelInfo 'Production'}
$backups=@{}

try {
    Write-Host '=== iMonitor ERP CORE v2.0.24 ===' -ForegroundColor Cyan
    Write-Host 'Core revision : 2.0.24-r1 (safe IIS activation + enforced MySQL settings)' -ForegroundColor DarkCyan

    foreach($info in $selected) {
        $backups[$info.Name]=Backup-ChannelSettings $info
        Stop-ChannelForActivation $info
    }

    & curl.exe -4 --http1.1 --silent --show-error --fail --location --connect-timeout 8 --max-time 300 --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' $uri -o $pinned 2>$null
    $ec=$LASTEXITCODE; $global:LASTEXITCODE=0
    if($ec -ne 0 -or -not(Test-Path $pinned -PathType Leaf)){throw "Could not download pinned v2.0.23 core. curl exit=$ec"}

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
    if($baseExit -ne 0){Write-Warning "Base deploy returned exit code $baseExit; applying v2.0.24 recovery before deciding final status."}

    $allOk=$true
    foreach($info in $selected) {
        $configOk=Force-MySqlSettings $info $backups[$info.Name]
        $healthOk=$false
        if($configOk){$healthOk=Start-And-VerifyChannel $info}
        if(-not($configOk -and $healthOk)){$allOk=$false}
    }

    if(-not $allOk){exit 24}
    exit 0
}
finally {
    Remove-Item $pinned -Force -ErrorAction SilentlyContinue
    Remove-Item $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
}
