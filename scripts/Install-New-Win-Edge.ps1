param(
    [ValidateSet('preview')][string]$Channel = 'preview',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'iMonitor\WindowsEdge.Web'),
    [switch]$SkipAutoUpdate,
    [switch]$NoStart
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$Repo='alimirzae/iMonitor-Erp-Releases'
$Raw="https://raw.githubusercontent.com/$Repo/main"
$ManifestUrl="$Raw/manifests/windows-edge-web-$Channel.json?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$ExeName='WindowsEdge.Web.exe'
$Current=Join-Path $InstallRoot 'current'
$Backups=Join-Path $InstallRoot 'backups'
$StatePath=Join-Path $InstallRoot 'install-state.json'
$Updater=Join-Path $InstallRoot 'Update-WindowsEdge.ps1'

if($env:OS -ne 'Windows_NT'){throw 'Windows Edge Web can only be installed on Windows.'}
$manifest=Invoke-RestMethod $ManifestUrl -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 30
if(-not $manifest.published -or [string]::IsNullOrWhiteSpace([string]$manifest.url)){throw "No published Windows Edge Web package is available for '$Channel'."}

$temp=Join-Path $env:TEMP ("WindowsEdgeWeb-"+[guid]::NewGuid().ToString('N'))
$zip=Join-Path $temp 'edge.zip'
$extract=Join-Path $temp 'payload'
New-Item -ItemType Directory -Path $temp,$extract,$InstallRoot,$Backups -Force|Out-Null
try{
    Write-Host "Downloading Windows Edge Web $($manifest.version)..." -ForegroundColor Cyan
    Invoke-WebRequest $manifest.url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    $actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actual -ne ([string]$manifest.sha256).ToLowerInvariant()){throw 'Package SHA256 verification failed.'}
    Expand-Archive $zip $extract -Force
    $newExe=Get-ChildItem $extract -Filter $ExeName -Recurse|Select-Object -First 1
    if(-not $newExe){throw "$ExeName is missing from the package."}
    foreach($dll in @('Stimulsoft.Report.Web.dll','Stimulsoft.Report.dll')){
        if(-not(Test-Path(Join-Path $newExe.Directory.FullName $dll))){throw "$dll is missing from the package."}
    }

    Get-CimInstance Win32_Process -Filter "Name='$ExeName'" -ErrorAction SilentlyContinue|
      Where-Object{$_.ExecutablePath -eq (Join-Path $Current $ExeName)}|
      ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}

    if(Test-Path $Current){Move-Item $Current (Join-Path $Backups (Get-Date -Format 'yyyyMMdd-HHmmss'))}
    New-Item -ItemType Directory $Current -Force|Out-Null
    Copy-Item (Join-Path $newExe.Directory.FullName '*') $Current -Recurse -Force

    Invoke-WebRequest "$Raw/scripts/Update-New-Windows-Edge.ps1?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile $Updater -UseBasicParsing -TimeoutSec 30
    [ordered]@{product='WindowsEdge.Web';channel=$Channel;version=$manifest.version;sourceSha=$manifest.sourceSha;installedAt=[DateTime]::UtcNow.ToString('o');installRoot=$InstallRoot;healthUrl='http://127.0.0.1:9001/health'}|ConvertTo-Json|Set-Content $StatePath -Encoding UTF8

    if(-not $SkipAutoUpdate){
        $action="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Updater`" -Channel $Channel -InstallRoot `"$InstallRoot`""
        schtasks.exe /Create /TN 'iMonitor Windows Edge Auto Update' /SC HOURLY /MO 1 /TR $action /F|Out-Null
    }

    if(-not $NoStart){
        Start-Process (Join-Path $Current $ExeName) -WorkingDirectory $Current
        $ready=$false
        for($i=0;$i -lt 30;$i++){try{$h=Invoke-RestMethod 'http://127.0.0.1:9001/health' -TimeoutSec 2;if($h.ok){$ready=$true;break}}catch{};Start-Sleep -Milliseconds 500}
        if(-not $ready){throw 'Windows Edge Web was installed but its health endpoint did not become ready.'}
    }
    Get-ChildItem $Backups -Directory -ErrorAction SilentlyContinue|Sort-Object Name -Descending|Select-Object -Skip 2|Remove-Item -Recurse -Force
    Write-Host "Windows Edge Web $($manifest.version) installed successfully." -ForegroundColor Green
    Write-Host "Portal: http://127.0.0.1:9001"
}catch{
    if(-not(Test-Path $Current)){
        $last=Get-ChildItem $Backups -Directory -ErrorAction SilentlyContinue|Sort-Object Name -Descending|Select-Object -First 1
        if($last){Move-Item $last.FullName $Current}
    }
    throw
}finally{Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}
