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

# App shell: favicon, reconnect/loading and canonical theme.
$app=Join-Path $SourceRoot 'Ecomm\Components\App.razor'
if(!(Test-Path $app)){throw "App.razor missing: $app"}
$t=Get-Content $app -Raw
$t=[regex]::Replace($t,'<title>.*?</title>','<title>POS IRAN ERP | پوز ایران ERP</title>',1)
if($t -notmatch 'posiran-brand\.css'){
  $marker='<link rel="stylesheet" href="build-info.css" />'
  $themeLink='<link rel="stylesheet" href="posiran-brand.css?v=3" />'
  if($t.Contains($marker)){$t=$t.Replace($marker,$marker+"`r`n    "+$themeLink)}
  else{$t=$t -replace '(<HeadOutlet\s*/>)',("    "+$themeLink+"`r`n    `$1")}
}
$t=$t -replace '<link rel="icon"[^>]*href="/img/logo\.webp"\s*/>','<link rel="icon" type="image/svg+xml" href="/img/posiran-logo.svg" />'
$t=$t -replace '<link rel="shortcut icon"[^>]*href="/img/logo\.webp"\s*/>','<link rel="shortcut icon" type="image/svg+xml" href="/img/posiran-logo.svg" />'
$t=$t -replace '<link rel="apple-touch-icon" href="/img/logo\.webp"\s*/>','<link rel="apple-touch-icon" href="/img/posiran-logo.svg" />'
$t=$t -replace 'src="img/logo\.webp" alt="iMonitor ERP" class="erp-reconnect-logo"','src="img/posiran-logo.svg" alt="POS IRAN ERP" class="erp-reconnect-logo"'
Set-Content $app $t -Encoding UTF8

# Main layout branding.
$layout=Join-Path $SourceRoot 'Ecomm\Components\Layout\MainLayout.razor'
if(!(Test-Path $layout)){throw "MainLayout.razor missing: $layout"}
$l=Get-Content $layout -Raw
$l=$l.Replace('aria-label="iMonitor ERP"','aria-label="POS IRAN ERP"')
$l=$l.Replace('src="/img/logo.webp" alt="iMonitor ERP"','src="/img/posiran-logo.svg" alt="POS IRAN ERP"')
Set-Content $layout $l -Encoding UTF8

# Account surfaces: merge-proof login/register branding and lightweight login endpoint.
$login=Join-Path $SourceRoot 'Ecomm\Components\Account\Pages\Login.razor'
if(Test-Path $login){
  $q=Get-Content $login -Raw
  $q=$q.Replace('ورود | iMonitor ERP','ورود | POS IRAN ERP')
  $q=$q.Replace('action="/Login"','action="/PosiranAuth/Login"')
  $q=$q.Replace('src="/img/app-icon.webp"','src="/img/posiran-logo.svg"')
  $q=$q.Replace('iMonitor ERP','POS IRAN ERP')
  Set-Content $login $q -Encoding UTF8
}
$register=Join-Path $SourceRoot 'Ecomm\Components\Account\Pages\Register.razor'
if(Test-Path $register){
  $q=Get-Content $register -Raw
  $q=$q.Replace('src="/img/logo.webp"','src="/img/posiran-logo.svg"')
  $q=$q.Replace('ECom ERP','POS IRAN ERP')
  Set-Content $register $q -Encoding UTF8
}

# Posiran packages always run safe EF migrations before accepting traffic. MigrateAsync is idempotent;
# destructive database recreation remains disabled and local connection strings remain untouched.
$program=Join-Path $SourceRoot 'Ecomm\Program.cs'
if(!(Test-Path $program)){throw "Program.cs missing: $program"}
$p=Get-Content $program -Raw
$p=[regex]::Replace(
  $p,
  'bool\s+migrateOnStartup\s*=\s*builder\.Configuration\.GetValue<bool>\(\s*"Database:MigrateOnStartup",\s*false\s*\);',
  'bool migrateOnStartup = true; // POS IRAN canonical build: safe/idempotent migrations are mandatory.',
  1)
Set-Content $program $p -Encoding UTF8

$css=Get-Content (Join-Path $SourceRoot 'Ecomm\wwwroot\posiran-brand.css') -Raw
$appCheck=Get-Content $app -Raw
$layoutCheck=Get-Content $layout -Raw
$programCheck=Get-Content $program -Raw
if($css -notmatch 'پوز\s*ایران ERP' -or $css -notmatch 'posiran\.ir'){throw 'Posiran brand contract validation failed.'}
if($appCheck -notmatch 'posiran-brand\.css'){throw 'Posiran theme stylesheet is not loaded by App.razor.'}
if($appCheck -match 'alt="iMonitor ERP"' -or $appCheck -match 'href="/img/logo\.webp"'){throw 'App shell still exposes iMonitor branding.'}
if($layoutCheck -match 'aria-label="iMonitor ERP"' -or $layoutCheck -match 'alt="iMonitor ERP"' -or $layoutCheck -match 'src="/img/logo\.webp"'){throw 'Main layout still exposes iMonitor branding.'}
if($programCheck -notmatch 'POS IRAN canonical build: safe/idempotent migrations are mandatory'){throw 'Posiran mandatory migration policy was not applied.'}
if(Test-Path $login){$loginCheck=Get-Content $login -Raw;if($loginCheck -notmatch '/PosiranAuth/Login'){throw 'Posiran login endpoint was not applied.'}}
Write-Host 'POS IRAN ERP white-label/migration overlay applied successfully.' -ForegroundColor Green
