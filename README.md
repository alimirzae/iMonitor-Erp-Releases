# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.24

PowerShell را با **Run as Administrator** باز کنید:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.24.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.24.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.24` نسخه رسمی فعلی Windows است. این نسخه همه اصلاحات نسخه‌های قبلی شامل IPv4/no-cache، انتخاب Release صحیح، استقلال Test/Production، IIS/AppPool repair، Binding بدون Host Header، `AllowedHosts="*"` و ANCM diagnostics را حفظ می‌کند.

### اصلاح Production activation و خطای file in use

قبل از جایگزینی فایل‌های هر کانال، Installer سایت و AppPool همان کانال را متوقف می‌کند تا `w3wp.exe` فایل‌های `current` را قفل نگه ندارد. بنابراین خطای زیر نباید باعث نیمه‌کاره ماندن activation شود:

```text
The process cannot access the file because it is being used by another process.
```

ترتیب deployment در `v2.0.24`:

```text
1. Backup appsettings.json کانال فعلی
2. Stop IIS Site + AppPool همان کانال
3. Stage/Activate آخرین Release
4. Restore/normalize تنظیمات MySQL
5. Force Database.Type = MySql
6. Disable startup migration/seed
7. Start IIS Site + AppPool
8. Verify /health
```

### MySQL enforcement

این نصب فقط از MySQL موجود استفاده می‌کند و هیچ MySQL را دانلود، نصب یا به‌روزرسانی نمی‌کند.

```text
Test       -> Database.Type = MySql -> Database = ecomm_dev
Production -> Database.Type = MySql -> Database = ecomm
```

اگر appsettings قدیمی یا package اشتباهاً `Database.Type=SqlServer` داشته باشد، Installer قبل از Start برنامه آن را به `MySql` اصلاح می‌کند. Connection string موجود MySQL حفظ می‌شود و فقط Database کانال به مقدار صحیح تنظیم می‌شود. اگر اطلاعات MySQL در اجرای interactive داده شده باشد همان مقادیر استفاده می‌شوند.

Migration و Seed در Installer غیرفعال‌اند:

```text
AutoMigrate=false
MigrateOnStartup=false
UseBackgroundMigration=false
EnsureCreatedIfNotExists=false
SeedDataOnMigrate=false
DropDatabaseOnStartup=false
```

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

سیستم هر یک دقیقه آخرین Release منتشرشده از شاخه `test` را بررسی می‌کند و اگر نسخه جدیدی در `alimirzae/iMonitor-Erp-Releases` منتشر شده باشد، کانال Test را خودکار update می‌کند.

Production مستقل است و هر 5 دقیقه بررسی می‌شود:

```text
iMonitorERP-Update-Production -> every 5 minutes
```

برای بررسی Taskها:

```powershell
schtasks /Query /TN "iMonitorERP-Update-Test" /V /FO LIST
schtasks /Query /TN "iMonitorERP-Update-Production" /V /FO LIST
```

فایل پایدار Installer:

```text
D:\erp_ins\installer\Install-iMonitorERP-v2.0.24.ps1
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

### ANCM stdout diagnostics

```text
Test       D:\erp_ins\test\current\logs\stdout_*.log
Production D:\erp_ins\production\current\logs\stdout_*.log
```

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
