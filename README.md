# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.8

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.8.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Invoke-WebRequest `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.8.ps1?cb=$cacheBust" `
  -UseBasicParsing `
  -OutFile $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -UpdateOnly `
  -PackageCacheDirectory 'D:\erp_ins'
```

`v2.0.8` نسخه رسمی فعلی است. اگر هنوز دستور `v2.0.7` را اجرا کنید، فایل v2.0.7 موجود در همین مخزن به‌صورت خودکار v2.0.8 را دریافت و اجرا می‌کند.

### تغییر مهم v2.0.8

Test و Production کاملاً مستقل Update می‌شوند. اگر مثلاً credential دیتابیس Production خراب باشد:

- Update کانال Test ادامه پیدا می‌کند.
- Production فقط Skip می‌شود.
- stack trace طولانی PowerShell/MySQL روی کنسول نمایش داده نمی‌شود.
- فقط Warning کوتاه و قابل‌فهم نمایش داده می‌شود.
- Scheduled Taskها بعد از اجرای موفق به `Install-iMonitorERP-v2.0.8.ps1` اشاره می‌کنند.

نمونه خروجی مورد انتظار در صورت خراب بودن credential Production:

```text
Test: update completed.
WARNING: Production: MySQL credentials are invalid ... Production was skipped.
iMonitor ERP installer/updater v2.0.8 completed.
```

### Mirror داخلی ایران و Fallback خودکار

مسیرهای اصلی Mirror:

```text
https://testerp.imonitor.ir/downloads/erp/test/latest.json
https://testerp.imonitor.ir/downloads/erp/test/iMonitor-EcomERP-win-x64.zip
https://testerp.imonitor.ir/downloads/erp/test/iMonitor-EcomERP-win-x64.zip.sha256.txt
https://testerp.imonitor.ir/downloads/erp/master/latest.json
https://testerp.imonitor.ir/downloads/erp/master/iMonitor-EcomERP-win-x64.zip
https://testerp.imonitor.ir/downloads/erp/install/Install-iMonitorERP-v2.0.8.ps1.txt
```

Installer ابتدا Mirror داخلی و GitHub را بررسی می‌کند. اگر Mirror آماده نباشد، GitHub با IPv4 (`curl -4`) fallback است. خراب بودن Mirror نباید نصب یا Update را متوقف کند.

برای bootstrap از Mirror داخلی:

```powershell
$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.8.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-WebRequest `
  "https://testerp.imonitor.ir/downloads/erp/install/Install-iMonitorERP-v2.0.8.ps1.txt?cb=$cb" `
  -UseBasicParsing `
  -OutFile $installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

اگر Mirror 404 باشد، دستور GitHub بالا را اجرا کنید.

### پورت‌ها و مسیرهای Windows

| کانال | آدرس | مسیر برنامه |
|---|---|---|
| Production | `http://localhost:8080` | `C:\ProgramData\iMonitorERP\production\current` |
| Test | `http://localhost:8081` | `C:\ProgramData\iMonitorERP\test\current` |

### MySQL

تنظیمات پایدار MySQL در این فایل نگهداری می‌شود:

```text
C:\ProgramData\iMonitorERP\config\mysql-credentials.json
```

اولویت تنظیمات:

```text
پارامتر صریح خط فرمان
    ↓
mysql-credentials.json
    ↓
appsettings.json نصب موجود
    ↓
مقدار پیش‌فرض Installer
```

فایل runtime واقعی هر کانال:

```text
C:\ProgramData\iMonitorERP\test\current\appsettings.json
C:\ProgramData\iMonitorERP\production\current\appsettings.json
```

اگر فقط `appsettings.json` را دستی تغییر دهید ولی `mysql-credentials.json` مقدار دیگری داشته باشد، updater ممکن است مقدار ذخیره‌شده credentials را دوباره اعمال کند. برای اصلاح پایدار credential، یک بار Installer را بدون `-UpdateOnly` و با اطلاعات صحیح اجرا کنید.

نمونه اصلاح فقط Production:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Production `
  -ProductionDatabase 'imonitor_erp_production' `
  -ProductionUser 'imonitor_production'
```

در صورت نیاز Installer رمز مدیر MySQL را به‌صورت تعاملی درخواست می‌کند.

### استفاده از ZIP از قبل دانلودشده

اگر `iMonitor-EcomERP-win-x64.zip` در `D:\erp_ins` وجود داشته باشد:

```powershell
Set-Location D:\erp_ins
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Test `
  -UpdateOnly `
  -PackageCacheDirectory 'D:\erp_ins'
```

اگر checksum فایل محلی با آخرین Release یکی باشد، دانلود مجدد Package انجام نمی‌شود.

### Scheduled Taskها

بعد از اجرای v2.0.8:

```text
C:\ProgramData\iMonitorERP\installer\Install-iMonitorERP-v2.0.8.ps1
```

و Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر کانال هر ۵ دقیقه و مستقل از کانال دیگر بررسی می‌شود.

### راه‌اندازی اولیه / Recovery

در وضعیت فعلی، `/Account/Setup` عمداً از مسیر اصلی سیستم خارج شده تا روی بوت Dashboard و Login اثر نگذارد. برای Migration و Recovery از ابزارهای مدیریتی فعال سیستم استفاده کنید. تا زمانی که طراحی Recovery جدید نهایی نشده، README نباید نصب اولیه را به `/Account/Setup` وابسته بداند.

### عیب‌یابی IIS

```powershell
Import-Module WebAdministration
Get-Website | Select-Object Name, State, PhysicalPath, Bindings
Get-WebAppPoolState 'iMonitorERP-Production'
Get-WebAppPoolState 'iMonitorERP-Test'

Get-WinEvent -LogName Application -MaxEvents 100 |
  Where-Object ProviderName -in @('IIS AspNetCore Module V2','IIS-W3SVC-WP','.NET Runtime') |
  Select-Object TimeCreated, ProviderName, Id, Message |
  Format-List
```

لاگ‌ها:

```text
C:\ProgramData\iMonitorERP\production\current\logs
C:\ProgramData\iMonitorERP\test\current\logs
```

### Linux / Ubuntu ERP

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash -s -- --channel both
```

---

## New_Win_Edge

Endpointهای اصلی:

```text
Health             http://127.0.0.1:17891/health
Printer discovery  http://127.0.0.1:17891/api/printers
Direct label print POST http://127.0.0.1:17891/api/labels/print
```

نصب One-Click:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-New-Win-Edge.ps1 | iex"
```
