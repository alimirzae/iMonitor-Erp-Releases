# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.9

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.9.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Invoke-WebRequest `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.9.ps1?cb=$cacheBust" `
  -UseBasicParsing `
  -OutFile $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -UpdateOnly `
  -PackageCacheDirectory 'D:\erp_ins'
```

`v2.0.9` نسخه رسمی فعلی است. فایل `v2.0.8` موجود در همین مخزن به v2.0.9 forward می‌شود تا اجرای دستور قدیمی نیز منطق جدید را بگیرد.

### تغییر مهم v2.0.9

Test و Production مستقل Update می‌شوند. اجرای child updater دیگر با `Start-Process -ArgumentList` انجام نمی‌شود و آرگومان‌ها مستقیماً به `powershell.exe` داده می‌شوند تا مشکل quoting در PowerShell ویندوز حذف شود.

اگر credential دیتابیس Production خراب باشد:

- Update کانال Test ادامه پیدا می‌کند.
- Production فقط Skip می‌شود.
- stack trace طولانی MySQL/PowerShell برای Production نمایش داده نمی‌شود.
- Warning کوتاه و قابل‌فهم نمایش داده می‌شود.

اگر خود Test شکست بخورد، v2.0.9 به‌جای مخفی‌کردن علت، چند خط انتهایی diagnostic را بعد از حذف اطلاعات حساس چاپ می‌کند تا خطای واقعی قابل تشخیص باشد.

نمونه موفق با Production خراب:

```text
Test: update completed.
WARNING: Production: MySQL credentials are invalid ... Production was skipped.
iMonitor ERP installer/updater v2.0.9 completed.
```

### Mirror داخلی ایران و Fallback خودکار

مسیرهای اصلی Mirror:

```text
https://testerp.imonitor.ir/downloads/erp/test/latest.json
https://testerp.imonitor.ir/downloads/erp/test/iMonitor-EcomERP-win-x64.zip
https://testerp.imonitor.ir/downloads/erp/test/iMonitor-EcomERP-win-x64.zip.sha256.txt
https://testerp.imonitor.ir/downloads/erp/master/latest.json
https://testerp.imonitor.ir/downloads/erp/master/iMonitor-EcomERP-win-x64.zip
https://testerp.imonitor.ir/downloads/erp/install/Install-iMonitorERP-v2.0.9.ps1.txt
```

Installer ابتدا Mirror داخلی و GitHub را بررسی می‌کند. اگر Mirror آماده نباشد، GitHub با IPv4 (`curl -4`) fallback است. خراب بودن Mirror نباید نصب یا Update را متوقف کند.

برای bootstrap از GitHub:

```powershell
$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.9.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-WebRequest `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.9.ps1?cb=$cb" `
  -UseBasicParsing `
  -OutFile $installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

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

برای اصلاح پایدار credential Production، یک بار Installer را بدون `-UpdateOnly` و با اطلاعات صحیح اجرا کنید.

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

بعد از اجرای موفق v2.0.9:

```text
C:\ProgramData\iMonitorERP\installer\Install-iMonitorERP-v2.0.9.ps1
```

و Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر کانال هر ۵ دقیقه و مستقل از کانال دیگر بررسی می‌شود.

### راه‌اندازی اولیه / Recovery

در وضعیت فعلی، `/Account/Setup` عمداً از مسیر اصلی سیستم خارج شده تا روی بوت Dashboard و Login اثر نگذارد. برای Migration و Recovery از ابزارهای مدیریتی فعال سیستم استفاده کنید.

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
