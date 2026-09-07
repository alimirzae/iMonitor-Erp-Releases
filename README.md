# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.21

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.21.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.21.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.21` نسخه رسمی فعلی Windows است و اصلاحات نسخه‌های قبلی شامل MySQL موجود، استقلال Test/Production، رفع cache، انتخاب Release صحیح، Binding بدون Hostname و `AllowedHosts="*"` را حفظ می‌کند.

### اصلاح 503 / AppPool در v2.0.21

اگر اجرای مستقیم زیر سالم باشد ولی IIS خطای `503 Service Unavailable` بدهد:

```powershell
cd D:\erp_ins\test\current
dotnet .\Ecomm.dll
```

مشکل معمولاً در App Pool، مجوز فایل‌ها، ANCM یا startup process همان سایت است. `v2.0.21` بعد از deploy برای هر کانال این موارد را اصلاح و بررسی می‌کند:

```text
AppPool .NET CLR Version = No Managed Code
AppPool Pipeline         = Integrated
AppPool startMode        = AlwaysRunning
AppPool autoStart        = true
AppPool Identity         = ApplicationPoolIdentity
Load User Profile        = true
Site serverAutoStart     = true
Binding                  = *:<port>:  بدون Host Header
AllowedHosts             = "*"
web.config hostingModel  = inprocess
```

همچنین برای مسیر برنامه به Identity اختصاصی App Pool دسترسی `Modify` داده می‌شود تا `App_Data` و لاگ‌های ASP.NET Core قابل استفاده باشند.

### ANCM stdout diagnostics

در `v2.0.21` برای تشخیص startup failure، stdout logging در `web.config` فعال می‌شود:

```text
stdoutLogEnabled = true
stdoutLogFile    = .\logs\stdout
```

مسیر دقیق لاگ Test:

```text
D:\erp_ins\test\current\logs\stdout_*.log
```

مسیر Production:

```text
D:\erp_ins\production\current\logs\stdout_*.log
```

Installer بعد از Start کردن سایت و App Pool، چند بار endpoint `/health` را بررسی می‌کند. اگر App Pool هنگام startup متوقف شود یا health check موفق نشود، آخرین رخدادهای IIS / ASP.NET Core / .NET Runtime / WAS / W3SVC را همان‌جا در کنسول چاپ می‌کند.

### IIS Binding و Invalid Hostname

برای هر کانال Binding به شکل زیر normalize می‌شود:

```text
Test       -> iMonitorERP-Test       -> *:8081:
Production -> iMonitorERP-Production -> *:8080:
```

Host Header خالی است. بنابراین این آدرس‌ها باید قابل استفاده باشند:

```text
http://127.0.0.1:8081/
http://localhost:8081/
http://127.0.0.1:8080/
http://localhost:8080/
```

### MySQL

Installer هیچ MySQL را دانلود، نصب یا به‌روزرسانی نمی‌کند.

```text
Test DB       ecomm_dev
Production DB ecomm
```

Migration و Seed همچنان در Installer غیرفعال‌اند.

### رفتار مستقل Test و Production

```text
Test success + Production success -> نصب کامل
Test success + Production failure -> Test فعال می‌ماند؛ Production updater بعداً retry می‌کند
Production success + Test failure -> Production فعال می‌ماند؛ Test updater بعداً retry می‌کند
```

Scheduled Taskها هر ۵ دقیقه اجرا می‌شوند:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

فایل پایدار Installer:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.21.ps1
```

### اگر Test هنوز 503 بود

ابتدا App Pool را بررسی کنید:

```powershell
Import-Module WebAdministration

Get-Website -Name 'iMonitorERP-Test' |
  Format-List Name,State,PhysicalPath,ApplicationPool,Bindings

Get-WebAppPoolState 'iMonitorERP-Test'

Get-ItemProperty 'IIS:\AppPools\iMonitorERP-Test' |
  Select-Object managedRuntimeVersion,managedPipelineMode,startMode,autoStart,
    @{N='IdentityType';E={$_.processModel.identityType}},
    @{N='LoadUserProfile';E={$_.processModel.loadUserProfile}},
    @{N='RapidFailProtection';E={$_.failure.rapidFailProtection}}
```

آخرین stdout:

```powershell
$log = Get-ChildItem 'D:\erp_ins\test\current\logs\stdout_*.log' `
  -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if ($log) {
  Write-Host $log.FullName
  Get-Content $log.FullName -Tail 200
}
```

خطاهای Application Event Log:

```powershell
Get-WinEvent -FilterHashtable @{
  LogName='Application'
  StartTime=(Get-Date).AddMinutes(-30)
} -ErrorAction SilentlyContinue |
Where-Object {
  $_.ProviderName -match 'IIS|AspNetCore|Application Error|\.NET Runtime'
} |
Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message |
Format-List
```

خطاهای WAS / W3SVC:

```powershell
Get-WinEvent -FilterHashtable @{
  LogName='System'
  StartTime=(Get-Date).AddMinutes(-30)
} -ErrorAction SilentlyContinue |
Where-Object {
  $_.ProviderName -match 'WAS|W3SVC'
} |
Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message |
Format-List
```

### IIS access logs

شناسه سایت Test:

```powershell
(Get-Website -Name 'iMonitorERP-Test').id
```

سپس:

```text
C:\inetpub\logs\LogFiles\W3SVC<SITE_ID>\
```

### بررسی .NET 8 Hosting Bundle / ANCM

```powershell
dotnet --list-runtimes
Test-Path 'C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
```

خروجی مورد انتظار شامل موارد زیر است:

```text
Microsoft.AspNetCore.App 8.x.x
Microsoft.NETCore.App 8.x.x
True
```

---

## Linux / Ubuntu ERP

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash -s -- --channel both
```

---

## New_Win_Edge

```text
Health             http://127.0.0.1:17891/health
Printer discovery  http://127.0.0.1:17891/api/printers
Direct label print POST http://127.0.0.1:17891/api/labels/print
```
