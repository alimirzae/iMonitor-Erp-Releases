# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.20

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.20.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.20.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.20` علاوه بر رفتار مستقل Test/Production نسخه `v2.0.19`، مشکل `Bad Request - Invalid Hostname` در IIS را هم هدف قرار می‌دهد.

### اصلاحات IIS در v2.0.20

Installer بعد از deploy این موارد را برای هر کانال normalize می‌کند:

```text
Test       -> IIS site iMonitorERP-Test       -> *:8081:  (بدون Host Header)
Production -> IIS site iMonitorERP-Production -> *:8080:  (بدون Host Header)
```

همچنین:

```text
AllowedHosts = "*"
AppPool .NET CLR Version = No Managed Code
AppPool Pipeline = Integrated
web.config hostingModel = inprocess
```

بنابراین درخواست‌های `localhost`، `127.0.0.1`، IP سیستم و نام کامپیوتر نباید به علت Host Header رد شوند.

### MySQL

Installer هیچ بسته MySQL را دانلود، نصب یا به‌روزرسانی نمی‌کند. MySQL باید از قبل نصب باشد.

```text
Test DB       ecomm_dev
Production DB ecomm
```

Migration و Seed همچنان در Installer غیرفعال‌اند.

### رفتار مستقل Test و Production

```text
Test success + Production success -> نصب کامل
Test success + Production failure -> Test فعال می‌ماند؛ Production بعداً retry می‌شود
Test failure                       -> نصب ناموفق
```

Scheduled Taskها هر ۵ دقیقه اجرا می‌شوند:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

### عیب‌یابی IIS اگر هنوز خطا وجود داشت

اگر بعد از `v2.0.20` هنوز IIS خطا داشت، این خروجی‌ها را ارسال کنید:

```powershell
Import-Module WebAdministration

Get-WebBinding -Name 'iMonitorERP-Test' |
  Format-Table protocol,bindingInformation,sslFlags -AutoSize

Get-ItemProperty 'IIS:\AppPools\iMonitorERP-Test' |
  Select-Object managedRuntimeVersion,managedPipelineMode,state

Get-Content 'D:\erp_ins\test\current\web.config'

Get-Content 'D:\erp_ins\test\current\appsettings.json' -Raw
```

برای بررسی Runtime/Hosting Bundle:

```powershell
dotnet --list-runtimes
Test-Path 'C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
```

خروجی مطلوب:

```text
Microsoft.AspNetCore.App 8.x.x
Microsoft.NETCore.App 8.x.x
True
```

برای لاگ‌های ASP.NET Core Module، اگر stdout logging در `web.config` فعال باشد، فایل‌ها معمولاً در مسیر زیر هستند:

```text
D:\erp_ins\test\current\logs\stdout_*.log
```

برای لاگ IIS سایت Test نیز ابتدا این مسیر را بررسی کنید:

```text
C:\inetpub\logs\LogFiles\
```

فولدر دقیق سایت را می‌توان با این دستور پیدا کرد:

```powershell
Import-Module WebAdministration
$site = Get-Website -Name 'iMonitorERP-Test'
$site.id
```

سپس لاگ مربوطه معمولاً در این مسیر است:

```text
C:\inetpub\logs\LogFiles\W3SVC<SITE_ID>\
```

### آدرس‌های محلی

```text
Test       http://127.0.0.1:8081/
Production http://127.0.0.1:8080/
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
