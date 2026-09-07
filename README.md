# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.23

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.23.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.23.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.23` نسخه رسمی فعلی Windows است. این نسخه همه اصلاحات `v2.0.22-r2` شامل رفع 404، Parser fix، بازیابی IIS/AppPool، Binding بدون Host Header، `AllowedHosts="*"` و ANCM diagnostics را حفظ می‌کند.

### Auto Update کانال Test — هر 1 دقیقه

پس از نصب، این background updater با حساب `SYSTEM` و Highest Privileges ثبت می‌شود:

```text
iMonitorERP-Update-Test
```

تنظیم آن:

```text
Schedule : every 1 minute
Account  : SYSTEM
Channel  : Test
Mode     : UpdateOnly
Source   : latest published imonitor-ecomerp-test-v*
Database : ecomm_dev
IIS      : iMonitorERP-Test / port 8081
```

یعنی سیستم هر یک دقیقه آخرین Release منتشرشده از شاخه `test` را بررسی می‌کند و اگر نسخه جدیدی در `alimirzae/iMonitor-Erp-Releases` منتشر شده باشد، همان کانال Test را به‌صورت خودکار update می‌کند. این کار بدون login کاربر و در پس‌زمینه سیستم انجام می‌شود.

Production مستقل باقی می‌ماند و هر 5 دقیقه بررسی می‌شود:

```text
iMonitorERP-Update-Production  -> every 5 minutes
```

برای بررسی Taskها:

```powershell
schtasks /Query /TN "iMonitorERP-Update-Test" /V /FO LIST
schtasks /Query /TN "iMonitorERP-Update-Production" /V /FO LIST
```

فایل پایدار Installer:

```text
D:\erp_ins\installer\Install-iMonitorERP-v2.0.23.ps1
```

### Release mapping

```text
Test       -> latest imonitor-ecomerp-test-v*   -> ecomm_dev -> IIS port 8081
Production -> latest imonitor-ecomerp-master-v* -> ecomm     -> IIS port 8080
```

### IIS / AppPool

```text
AppPool .NET CLR Version = No Managed Code
AppPool Pipeline         = Integrated
AppPool startMode        = AlwaysRunning
AppPool autoStart        = true
AppPool Identity         = ApplicationPoolIdentity
Load User Profile        = true
Site serverAutoStart     = true
AllowedHosts             = "*"
web.config hostingModel  = inprocess
```

Bindings:

```text
Test       -> iMonitorERP-Test       -> *:8081:
Production -> iMonitorERP-Production -> *:8080:
```

### MySQL

Installer هیچ MySQL را دانلود، نصب یا به‌روزرسانی نمی‌کند.

```text
Test DB       ecomm_dev
Production DB ecomm
```

Migration و Seed همچنان در Installer غیرفعال‌اند.

### ANCM stdout diagnostics

```text
Test       D:\erp_ins\test\current\logs\stdout_*.log
Production D:\erp_ins\production\current\logs\stdout_*.log
```

در صورت خطای 503، Installer وضعیت AppPool و رخدادهای IIS / ASP.NET Core / .NET Runtime / WAS / W3SVC را بررسی و چاپ می‌کند.

برای بررسی .NET 8 Hosting Bundle / ANCM:

```powershell
dotnet --list-runtimes
Test-Path 'C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
```

آدرس‌های محلی:

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
