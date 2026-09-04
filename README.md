# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.11

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.11.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

curl.exe -4 --http1.1 -fL `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.11.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -Force `
  -PackageCacheDirectory 'D:\erp_ins'
```

`v2.0.11` نسخه رسمی فعلی است.

### تغییر مهم v2.0.11 — انتشار امن روی IIS

هنگام Update دیگر فقط AppPool متوقف نمی‌شود. ترتیب Activation به شکل زیر است:

```text
Validate package
→ Stage new release
→ Stop IIS Site
→ Stop IIS AppPool
→ Wait/retry for file handles to be released
→ Atomic swap current
→ Start AppPool
→ Start Site
→ Health check
→ Rollback automatically if health fails
```

این تغییر خطای زیر را هنگام جایگزینی `current` رفع می‌کند:

```text
The process cannot access the file because it is being used by another process.
Move-Item ... current ...
```

قبل از فعال‌سازی وجود این موارد اجباری است:

```text
Ecomm.dll
web.config
wwwroot
Reports
Reports\Invoice.mrt
Reports\Label.mrt
```

Package ناقص فعال نمی‌شود و در صورت شکست، `current` قبلی بازیابی می‌شود.

### تشخیص آخرین Release

GitHub Release از طریق IPv4 مرجع تشخیص نسخه است. بنابراین mirror داخلی قدیمی دیگر باعث باقی ماندن کلاینت روی نسخه قبلی نمی‌شود.

ZIP دانلودشده در `D:\erp_ins` با SHA-256 کنترل می‌شود. اگر همان نسخه قبلاً کامل دانلود شده باشد، دانلود مجدد انجام نمی‌شود.

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

فایل runtime واقعی هر کانال:

```text
C:\ProgramData\iMonitorERP\test\current\appsettings.json
C:\ProgramData\iMonitorERP\production\current\appsettings.json
```

### Scheduled Taskها

بعد از اجرای موفق v2.0.11:

```text
C:\ProgramData\iMonitorERP\installer\Install-iMonitorERP-v2.0.11.ps1
```

Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر کانال هر ۵ دقیقه مستقل بررسی می‌شود.

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
