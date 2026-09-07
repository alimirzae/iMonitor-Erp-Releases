[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [Parameter(Mandatory=$true)][string]$OverlayRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
$OverlayRoot=[IO.Path]::GetFullPath($OverlayRoot)
function Ensure-Parent([string]$p){$d=Split-Path $p -Parent;if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}}
function Copy-Overlay([string]$relative){$src=Join-Path $OverlayRoot $relative;$dst=Join-Path $SourceRoot $relative;if(!(Test-Path $src)){throw "Canonical Posiran overlay missing: $src"};Ensure-Parent $dst;Copy-Item $src $dst -Force}

foreach($p in @(
  'Ecomm\wwwroot\posiran-brand.css',
  'Ecomm\wwwroot\img\posiran-logo.svg',
  'Ecomm\wwwroot\build-info.css',
  '.github\workflows\publish-posiran-windows.yml',
  '.github\workflows\deploy-posiran-local.yml',
  'POSIRAN_WHITE_LABEL.md'
)){Copy-Overlay $p}

$app=Join-Path $SourceRoot 'Ecomm\Components\App.razor'
if(!(Test-Path $app)){throw "App.razor missing: $app"}
$t=Get-Content $app -Raw
if($t -notmatch '<title>Posiran ERP \| پوزایران ERP</title>'){
  $t=$t -replace '(<base href="/"\s*/>)',"`$1`r`n    <title>Posiran ERP | پوزایران ERP</title>"
}
$t=$t -replace '<link rel="icon" type="image/webp" href="/img/logo\.webp"\s*/>','<link rel="icon" type="image/svg+xml" href="/img/posiran-logo.svg" />'
$t=$t -replace '<link rel="shortcut icon" type="image/webp" href="/img/logo\.webp"\s*/>','<link rel="shortcut icon" type="image/svg+xml" href="/img/posiran-logo.svg" />'
$t=$t -replace '<link rel="apple-touch-icon" href="/img/logo\.webp"\s*/>','<link rel="apple-touch-icon" href="/img/posiran-logo.svg" />'
$t=$t -replace 'src="img/logo\.webp" alt="iMonitor ERP" class="erp-reconnect-logo"','src="img/posiran-logo.svg" alt="Posiran ERP" class="erp-reconnect-logo"'
Set-Content $app $t -Encoding UTF8

$layout=Join-Path $SourceRoot 'Ecomm\Components\Layout\MainLayout.razor'
if(Test-Path $layout){
  $l=Get-Content $layout -Raw
  $l=$l.Replace('aria-label="iMonitor ERP"','aria-label="Posiran ERP"')
  $l=$l.Replace('src="/img/logo.webp" alt="iMonitor ERP"','src="/img/posiran-logo.svg" alt="Posiran ERP"')
  Set-Content $layout $l -Encoding UTF8
}

$css=Get-Content (Join-Path $SourceRoot 'Ecomm\wwwroot\posiran-brand.css') -Raw
if($css -notmatch 'پوزایران ERP' -or $css -notmatch 'posiran\.ir'){throw 'Posiran brand contract validation failed.'}
Write-Host 'Posiran ERP white-label overlay applied successfully.' -ForegroundColor Green
