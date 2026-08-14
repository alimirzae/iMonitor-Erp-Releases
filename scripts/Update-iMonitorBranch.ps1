param(
    [string]$Root='C:\ERP',
    [switch]$UpdateProduction,
    [switch]$UpdatePreview
)
$ErrorActionPreference='Stop'
if(-not $UpdateProduction -and -not $UpdatePreview){$UpdateProduction=$true;$UpdatePreview=$true}
$raw='https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main'
$configRoot=Join-Path $Root 'Config'
$installer=Join-Path $env:TEMP 'Install-iMonitorBranch.ps1'
$needProd=$false;$needPreview=$false

function Needs-Update([string]$Channel){
    $state=Join-Path $configRoot ("state-$Channel.json")
    if(!(Test-Path $state)){return $false}
    $s=Get-Content $state -Raw|ConvertFrom-Json
    $m=Invoke-RestMethod "$raw/manifests/erp-$Channel.json" -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 15
    return $m.published -and (([string]$s.sha -ne [string]$m.sourceSha) -or ([string]$s.version -ne [string]$m.version))
}
if($UpdateProduction){$needProd=Needs-Update 'stable'}
if($UpdatePreview){$needPreview=Needs-Update 'preview'}
if(-not $needProd -and -not $needPreview){exit 0}
Invoke-WebRequest "$raw/scripts/Install-iMonitorBranch.ps1" -OutFile $installer -UseBasicParsing
try{
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$installer,'-Root',$Root,'-SkipAutoUpdate','-NonInteractive')
    if($needProd){$args+='-InstallProduction'}
    if($needPreview){$args+='-InstallPreview'}
    & powershell.exe @args
    if($LASTEXITCODE -ne 0){throw "Branch updater failed with exit code $LASTEXITCODE"}
}finally{Remove-Item $installer -Force -ErrorAction SilentlyContinue}
