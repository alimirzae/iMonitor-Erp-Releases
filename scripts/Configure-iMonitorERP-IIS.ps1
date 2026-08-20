param(
  [Parameter(Mandatory=$true)][ValidateSet('test','stable')][string]$Environment,
  [Parameter(Mandatory=$true)][string]$Domain,
  [int]$BackendPort = 0
)

$ErrorActionPreference = 'Stop'
if ($BackendPort -eq 0) { $BackendPort = if ($Environment -eq 'test') { 8081 } else { 8080 } }

Write-Host "iMonitor ERP IIS reverse proxy" -ForegroundColor Cyan
Write-Host "Environment : $Environment"
Write-Host "Domain      : $Domain"
Write-Host "Backend     : http://127.0.0.1:$BackendPort"

if (-not (Get-WindowsFeature Web-Server).Installed) {
  Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null
}

$rewrite = Get-WebGlobalModule -Name RewriteModule -ErrorAction SilentlyContinue
$arr = Get-WebGlobalModule -Name ApplicationRequestRouting -ErrorAction SilentlyContinue
if (-not $rewrite -or -not $arr) {
  Write-Warning 'IIS URL Rewrite and Application Request Routing (ARR) are required.'
  Write-Warning 'Install those IIS extensions, then rerun this script.'
  exit 2
}

Import-Module WebAdministration
Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter 'system.webServer/proxy' -name 'enabled' -value 'True'

$siteName = "iMonitor ERP $Environment"
$root = "C:\inetpub\imonitor-erp-$Environment-proxy"
New-Item -ItemType Directory -Force -Path $root | Out-Null

if (-not (Test-Path "IIS:\Sites\$siteName")) {
  New-Website -Name $siteName -Port 80 -HostHeader $Domain -PhysicalPath $root | Out-Null
} else {
  Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $root
}

$webConfig = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="iMonitor reverse proxy" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://127.0.0.1:$BackendPort/{R:1}" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
"@
Set-Content -Path (Join-Path $root 'web.config') -Value $webConfig -Encoding UTF8

Write-Host '[OK] IIS reverse proxy site configured.' -ForegroundColor Green
Write-Host 'TLS certificate: use the dashboard Windows certificate action / ACME client integration when enabled.'
