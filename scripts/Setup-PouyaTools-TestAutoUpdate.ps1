param(
    [string]$DriveRoot = 'D:\',
    [string]$Repository = 'alimirzae/Ecomm',
    [string]$Branch = 'test',
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference='Stop'
function Step([string]$m){Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run PowerShell as Administrator.'}

$root=Join-Path $DriveRoot 'EcommAutoUpdate'
$src=Join-Path $root 'src'
$keyDir=Join-Path $root 'keys'
$logDir=Join-Path $root 'logs'
$stateDir=Join-Path $root 'state'
$updater=Join-Path $root 'Update-Test.ps1'
$keyPath=Join-Path $keyDir 'ecomm-pouyatools-test-ed25519'
$taskName='iMonitorERP-PouyaTools-Test-AutoUpdate'
New-Item -ItemType Directory -Force $root,$keyDir,$logDir,$stateDir | Out-Null

Step 'Checking GitHub CLI authentication...'
if(-not(Get-Command gh -ErrorAction SilentlyContinue)){throw 'gh.exe is required. Re-run the PouyaTools build-server setup first.'}
& gh auth status -h github.com
if($LASTEXITCODE -ne 0){throw 'GitHub CLI is not authenticated for the administrator account.'}

if(-not(Get-Command ssh-keygen -ErrorAction SilentlyContinue)){
    Step 'Installing Windows OpenSSH Client...'
    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null
}
if(-not(Get-Command ssh-keygen -ErrorAction SilentlyContinue)){throw 'ssh-keygen is still unavailable.'}

if(-not(Test-Path $keyPath)){
    Step 'Generating a dedicated read-only SSH deploy key...'
    & ssh-keygen -t ed25519 -N '' -C 'PouyaTools_Server test auto updater' -f $keyPath | Out-Null
    if($LASTEXITCODE -ne 0){throw "ssh-keygen failed: $LASTEXITCODE"}
}

$pub=(Get-Content "$keyPath.pub" -Raw).Trim()
$title="PouyaTools_Server-Test-AutoUpdate-$env:COMPUTERNAME"
Step 'Ensuring deploy key is registered in GitHub...'
$existing = & gh api "repos/$Repository/keys" --paginate 2>$null | ConvertFrom-Json
$match=$existing | Where-Object {$_.title -eq $title -or $_.key -eq $pub} | Select-Object -First 1
if(-not $match){
    $body=@{title=$title;key=$pub;read_only=$true}|ConvertTo-Json -Compress
    $body | & gh api "repos/$Repository/keys" --method POST --input - | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Failed to register GitHub deploy key.'}
    Step 'Read-only deploy key registered.'
}else{Step "Deploy key already registered: $($match.title)"}

# Restrict key material to Administrators and SYSTEM.
& icacls $keyDir /inheritance:r | Out-Null
& icacls $keyDir /grant:r 'SYSTEM:(OI)(CI)(F)' 'Administrators:(OI)(CI)(F)' | Out-Null

$script=@'
param(
    [string]$DriveRoot='D:\',
    [string]$Repository='alimirzae/Ecomm',
    [string]$Branch='test'
)
$ErrorActionPreference='Stop'
$root=Join-Path $DriveRoot 'EcommAutoUpdate'
$src=Join-Path $root 'src'
$key=Join-Path $root 'keys\ecomm-pouyatools-test-ed25519'
$logs=Join-Path $root 'logs'
$state=Join-Path $root 'state'
$publish=Join-Path $root 'publish'
$marker=Join-Path $DriveRoot 'Sites\Ecomm-Test\.deployed-sha'
$stateJson=Join-Path $state 'last-update.json'
New-Item -ItemType Directory -Force $logs,$state | Out-Null
$log=Join-Path $logs ("update-"+(Get-Date -Format 'yyyyMMdd')+'.log')
function Log([string]$m){$line="[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m";Add-Content -Path $log -Value $line;Write-Host $line}
$mutex=New-Object Threading.Mutex($false,'Global\iMonitorERP-PouyaTools-TestUpdate')
if(-not $mutex.WaitOne(0)){Log 'Another updater/deploy is already running; exiting.';exit 0}
try{
    $env:GIT_SSH_COMMAND="ssh -i `"$key`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=`"$root\keys\known_hosts`""
    $sshUrl="git@github.com:$Repository.git"
    if(-not(Test-Path (Join-Path $src '.git'))){
        Log "Cloning $Repository/$Branch..."
        Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
        git clone --branch $Branch --single-branch --depth 1 $sshUrl $src
        if($LASTEXITCODE -ne 0){throw "git clone failed: $LASTEXITCODE"}
    }
    Set-Location $src
    git remote set-url origin $sshUrl | Out-Null
    git fetch origin $Branch --prune --depth 1
    if($LASTEXITCODE -ne 0){throw "git fetch failed: $LASTEXITCODE"}
    $remote=(git rev-parse "origin/$Branch").Trim()
    $installed=if(Test-Path $marker){(Get-Content $marker -Raw).Trim()}else{''}
    $healthy=$false
    try{$r=Invoke-WebRequest http://localhost:8080/ -UseBasicParsing -TimeoutSec 10;$healthy=$r.StatusCode -ge 200 -and $r.StatusCode -lt 500}catch{}
    Log "remote=$remote installed=$installed healthy=$healthy"
    if($installed -eq $remote -and $healthy){Log 'Already current and healthy; no-op.';exit 0}

    Log "Updating to $remote"
    git reset --hard $remote
    if($LASTEXITCODE -ne 0){throw "git reset failed: $LASTEXITCODE"}
    git clean -fdx -e '.git' | Out-Null

    dotnet restore Ecomm.sln
    if($LASTEXITCODE -ne 0){throw "dotnet restore failed: $LASTEXITCODE"}
    dotnet build Ecomm.sln -c Release --no-restore
    if($LASTEXITCODE -ne 0){throw "dotnet build failed: $LASTEXITCODE"}
    dotnet test Ecomm.sln -c Release --no-build --verbosity normal
    if($LASTEXITCODE -ne 0){throw "dotnet test failed: $LASTEXITCODE"}

    Remove-Item $publish -Recurse -Force -ErrorAction SilentlyContinue
    dotnet publish .\Ecomm\Ecomm.csproj -c Release --no-restore -o $publish -p:BuildNumber="auto-$($remote.Substring(0,12))"
    if($LASTEXITCODE -ne 0){throw "dotnet publish failed: $LASTEXITCODE"}
    if(-not(Test-Path (Join-Path $publish 'Ecomm.dll'))){throw 'Ecomm.dll is missing from publish output.'}

    Log 'Deploying validated build to IIS Test...'
    & .\scripts\Deploy-PouyaTools-Iis.ps1 -Environment Test -PublishPath $publish -DriveRoot $DriveRoot -SourceSha $remote
    if($LASTEXITCODE -ne 0){throw "IIS deploy failed: $LASTEXITCODE"}

    $r=Invoke-WebRequest http://localhost:8080/ -UseBasicParsing -TimeoutSec 20
    if($r.StatusCode -lt 200 -or $r.StatusCode -ge 500){throw "Final health check failed: HTTP $($r.StatusCode)"}
    $obj=[ordered]@{sha=$remote;branch=$Branch;completedAt=[DateTimeOffset]::UtcNow.ToString('o');http=$r.StatusCode;computer=$env:COMPUTERNAME}
    $obj|ConvertTo-Json|Set-Content $stateJson -Encoding UTF8
    Log "UPDATE SUCCESS sha=$remote HTTP=$($r.StatusCode)"
}catch{
    Log ("UPDATE FAILED: "+$_.Exception.ToString())
    $obj=[ordered]@{failedAt=[DateTimeOffset]::UtcNow.ToString('o');error=$_.Exception.ToString();computer=$env:COMPUTERNAME}
    $obj|ConvertTo-Json -Depth 5|Set-Content $stateJson -Encoding UTF8
    exit 1
}finally{
    try{$mutex.ReleaseMutex()}catch{}
    $mutex.Dispose()
}
'@
Set-Content -Path $updater -Value $script -Encoding UTF8

Step 'Creating SYSTEM scheduled task...'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -DriveRoot `"$DriveRoot`" -Repository `"$Repository`" -Branch `"$Branch`""
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$principalTask=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principalTask -Force | Out-Null

Step 'Running the updater once now...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -DriveRoot $DriveRoot -Repository $Repository -Branch $Branch
$rc=$LASTEXITCODE
Write-Host ''
Write-Host '=== PouyaTools Test AutoUpdate installed ===' -ForegroundColor Green
Write-Host "Task       : $taskName"
Write-Host "Interval   : every $IntervalMinutes minutes"
Write-Host "Updater    : $updater"
Write-Host "Logs       : $logDir"
Write-Host "State      : $stateDir"
Write-Host "Test URL   : http://localhost:8080/"
Write-Host "First run  : exitCode=$rc"
if($rc -ne 0){Write-Warning 'AutoUpdate is installed, but its first run failed. Inspect the latest log under D:\EcommAutoUpdate\logs.'}
