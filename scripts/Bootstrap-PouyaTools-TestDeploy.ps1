param(
  [string]$Repo='alimirzae/Ecomm',
  [string]$Branch='test',
  [string]$WorkRoot='D:\PouyaToolsBuild'
)
$ErrorActionPreference='Stop'
function Step([string]$m){Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan}
if(-not(Get-Command gh.exe -ErrorAction SilentlyContinue)){throw 'gh.exe not found'}
if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){throw 'git.exe not found'}
if(-not(Get-Command dotnet.exe -ErrorAction SilentlyContinue)){throw 'dotnet.exe not found'}
& gh auth status -h github.com
if($LASTEXITCODE -ne 0){throw 'GitHub CLI is not authenticated'}
& gh auth setup-git
$src=Join-Path $WorkRoot 'source'
$pub=Join-Path $WorkRoot 'publish-test'
New-Item -ItemType Directory -Force $WorkRoot | Out-Null
if(Test-Path (Join-Path $src '.git')){
  Step 'Refreshing existing repository...'
  Push-Location $src
  git fetch origin $Branch --prune
  if($LASTEXITCODE -ne 0){throw 'git fetch failed'}
  git reset --hard "origin/$Branch"
  if($LASTEXITCODE -ne 0){throw 'git reset failed'}
  git clean -fdx
  Pop-Location
}else{
  if(Test-Path $src){Remove-Item $src -Recurse -Force}
  Step 'Cloning Ecomm repository...'
  gh repo clone $Repo $src -- --branch $Branch --single-branch
  if($LASTEXITCODE -ne 0){throw 'gh repo clone failed'}
}
Push-Location $src
try{
  Step 'Restoring solution...'
  dotnet restore Ecomm.sln
  if($LASTEXITCODE -ne 0){throw "restore failed: $LASTEXITCODE"}
  Step 'Building Release...'
  dotnet build Ecomm.sln -c Release --no-restore
  if($LASTEXITCODE -ne 0){throw "build failed: $LASTEXITCODE"}
  Step 'Running tests...'
  dotnet test Ecomm.sln -c Release --no-build --verbosity normal
  if($LASTEXITCODE -ne 0){throw "tests failed: $LASTEXITCODE"}
  Step 'Publishing ERP...'
  Remove-Item $pub -Recurse -Force -ErrorAction SilentlyContinue
  dotnet publish .\Ecomm\Ecomm.csproj -c Release --no-restore -o $pub
  if($LASTEXITCODE -ne 0){throw "publish failed: $LASTEXITCODE"}
  if(-not(Test-Path (Join-Path $pub 'Ecomm.dll'))){throw 'Ecomm.dll missing from publish output'}
  Step 'Deploying TEST to IIS port 8080...'
  .\scripts\Deploy-PouyaTools-Iis.ps1 -Environment Test -PublishPath $pub -DriveRoot 'D:\'
  if($LASTEXITCODE -ne 0){throw "deploy failed: $LASTEXITCODE"}
  Step 'Final verification...'
  $r=Invoke-WebRequest -Uri 'http://127.0.0.1:8080/' -Headers @{Host='testerp.pouyatools.ir'} -UseBasicParsing -TimeoutSec 20
  Write-Host "TEST DEPLOY OK HTTP $($r.StatusCode)" -ForegroundColor Green
  Write-Host "Source: $src"
  Write-Host "Publish: $pub"
  Write-Host "Site: D:\Sites\Ecomm-Test"
} finally {Pop-Location}
