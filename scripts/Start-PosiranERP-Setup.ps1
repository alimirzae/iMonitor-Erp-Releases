[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  throw 'PowerShell را با Run as Administrator اجرا کنید.'
}

$root = Join-Path $env:ProgramData 'PosiranERP\Setup'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$zip = Join-Path $root 'PosiranERP-Setup-win-x64.zip'
$sha = "$zip.sha256"
$releaseBase = 'https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/posiran-installer-preview'

function Get-File([string]$Url,[string]$Out){
  $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  & curl.exe -4 --http1.1 --fail --location --silent --show-error --connect-timeout 10 --retry 4 --retry-all-errors -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "${Url}?cb=$cacheBust" -o $Out
  if($LASTEXITCODE -ne 0){ throw "Download failed: $Url" }
}

Write-Host 'Downloading latest Posiran ERP Setup...' -ForegroundColor Cyan
Get-File "$releaseBase/PosiranERP-Setup-win-x64.zip" $zip
Get-File "$releaseBase/PosiranERP-Setup-win-x64.zip.sha256" $sha
$expected=((Get-Content $sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if($expected -ne $actual){ throw "SHA256 mismatch. expected=$expected actual=$actual" }

$extract = Join-Path $root 'current'

# Stop a previously launched Setup Host before refreshing the extracted files or reusing port 8099.
Get-Process -Name 'PosiranERP.Setup' -ErrorAction SilentlyContinue | ForEach-Object {
  try {
    $processPath = $_.Path
    if([string]::IsNullOrWhiteSpace($processPath) -or $processPath.StartsWith($root,[System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Host "Stopping previous Posiran ERP Setup process (PID $($_.Id))..." -ForegroundColor Yellow
      Stop-Process -Id $_.Id -Force -ErrorAction Stop
      $_.WaitForExit(5000) | Out-Null
    }
  } catch {
    Write-Warning "Could not stop previous Setup process PID $($_.Id): $($_.Exception.Message)"
  }
}
Start-Sleep -Milliseconds 500

if(Test-Path $extract){ Remove-Item $extract -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
Expand-Archive $zip -DestinationPath $extract -Force
$exe = Join-Path $extract 'PosiranERP.Setup.exe'
if(!(Test-Path $exe)){ throw 'PosiranERP.Setup.exe was not found after extraction.' }

# ASP.NET ContentRoot/WebRoot must resolve relative to the published setup directory,
# not to the caller's current PowerShell directory (C:\pos, C:\Windows\System32, etc.).
Start-Process -FilePath $exe -WorkingDirectory $extract -Verb RunAs

$ready=$false
for($i=0;$i -lt 20;$i++){
  Start-Sleep -Milliseconds 500
  try {
    $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8099/health' -TimeoutSec 2
    if($r.StatusCode -eq 200){$ready=$true;break}
  } catch {}
}
if(-not $ready){ throw 'Posiran ERP Setup did not become healthy on http://127.0.0.1:8099/health' }

Start-Process 'http://127.0.0.1:8099/'
Write-Host 'Posiran ERP Setup started on http://127.0.0.1:8099/' -ForegroundColor Green
