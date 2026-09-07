# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.15

PowerShell را با **Run as Administrator** باز کنید و وارد پوشه‌ای شوید که می‌خواهید ERP همان‌جا نصب شود:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.15.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

curl.exe -4 --http1.1 -fL `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.15.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.15` نسخه رسمی نصب Windows است.

### MySQL موجود — بدون دانلود MySQL

به علت محدودیت دسترسی به MySQL در برخی شبکه‌ها، Installer دیگر MySQL را دانلود یا نصب نمی‌کند. در اولین اجرای تعاملی، Installer MySQL موجود را پیدا می‌کند یا از کاربر این موارد را می‌پرسد:

```text
Path to mysql.exe or MySQL bin directory
MySQL host/address [127.0.0.1]
MySQL port [3306]
MySQL administrative user [root]
Password for MySQL user 'root'
```

رمز در کنسول نمایش داده نمی‌شود. Installer ابتدا اتصال واقعی با کاربر مدیریتی را تست می‌کند و فقط در صورت موفق بودن ادامه می‌دهد.

اگر `mysql.exe` در PATH یا مسیرهای استاندارد MySQL Server 8.0/8.4 پیدا شود، مسیر آن به‌صورت خودکار تشخیص داده می‌شود.

### نصب صفر تا صد ERP با MySQL موجود

```text
IIS / Management Tools
→ .NET 8 ASP.NET Core Hosting Bundle
→ اتصال و تست MySQL موجود
→ ساخت دیتابیس Test و Production
→ ساخت Userهای اختصاصی Test و Production
→ Grant و تست Login واقعی
→ تولید appsettings.json با Connection String معتبر
→ دریافت/استفاده از Cache آخرین Release
→ Stage و Activation
→ اجرای Migrationهای EF Core هنگام Startup
→ Health Check واقعی
→ Rollback در صورت خطا
→ First-run Wizard برای دیتابیس تازه
```

دیتابیس‌ها و Userهای پیش‌فرض:

```text
Test       imonitor_erp_test        user: imonitor_test
Production imonitor_erp_production  user: imonitor_production
```

Passwordهای کاربران برنامه توسط Installer تولید می‌شوند.

### نگهداری تنظیمات MySQL برای updater

بعد از اتصال موفق، تنظیمات لازم برای اجرای بدون تعامل updater در مسیر زیر ذخیره می‌شود:

```text
D:\erp_ins\config\mysql-external.json
```

این فایل شامل اطلاعات اتصال MySQL و credentialهای لازم برای نگهداری خودکار است و ACL پوشه به `Administrators` و `SYSTEM` محدود می‌شود. فایل را منتشر یا حذف نکنید.

### Migration و First-run Wizard

Installer این تنظیمات را فعال می‌کند:

```text
Database:Type=MySql
Database:AutoMigrate=true
Database:MigrateOnStartup=true
Database:EnsureCreatedIfNotExists=true
Database:SeedDataOnMigrate=true
Database:DropDatabaseOnStartup=false
```

پس از آماده‌شدن دیتابیس، Ecomm Migrationهای EF Core را هنگام Startup اجرا می‌کند.

پس از نصب موفق:

```text
Test wizard       http://127.0.0.1:8081/account/setup
Production wizard http://127.0.0.1:8080/account/setup
```

### Automatic Updater

Updater از ابتدای نصب ثبت می‌شود و هر ۵ دقیقه اجرا می‌شود:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

فایل پایدار Installer:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.15.ps1
```

Taskها با حساب `SYSTEM` و Highest Privileges اجرا می‌شوند. در اجرای خودکار، اطلاعات MySQL از `config\mysql-external.json` خوانده می‌شود و هیچ Prompt تعاملی نمایش داده نمی‌شود.

### اجرای کاملاً غیرتعاملی اختیاری

در صورت نیاز می‌توان اطلاعات MySQL را هنگام اجرای اولیه به‌صورت پارامتر داد:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -MySqlBinPath 'C:\Program Files\MySQL\MySQL Server 8.0\bin' `
  -MySqlHost '127.0.0.1' `
  -MySqlPort 3306 `
  -MySqlRootUser 'root' `
  -Force
```

برای امنیت بهتر، Password را در Command History وارد نکنید؛ در اجرای عادی Installer آن را به‌صورت Secure Prompt می‌پرسد.

### Cache و IPv4

دانلود Bootstrap/Core و Releaseهای ERP با `curl.exe -4 --http1.1` انجام می‌شوند. اگر ZIP معتبر Release در `PackageCacheDirectory` موجود باشد دوباره دانلود نمی‌شود. هیچ دانلود MySQL انجام نمی‌شود.

### مهاجرت نصب قبلی

اگر نصب قبلی در مسیر زیر وجود داشته باشد:

```text
C:\ProgramData\iMonitorERP
```

Installer تنظیمات عمومی و `App_Data` را در صورت وجود حفظ می‌کند، اما Connection String دیتابیس را با اطلاعات MySQL تاییدشده نصب فعلی جایگزین می‌کند. مسیر قدیمی حذف نمی‌شود.

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
