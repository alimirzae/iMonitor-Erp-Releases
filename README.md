# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.16

PowerShell را با **Run as Administrator** باز کنید و وارد پوشه‌ای شوید که می‌خواهید ERP همان‌جا نصب شود:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.16.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.16.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.16` نسخه رسمی نصب Windows است. نسخه‌های `v2.0.15` بازنشسته شده‌اند و در صورت اجرا به `v2.0.16` هدایت می‌شوند.

### MySQL موجود — بدون دانلود یا نصب MySQL

Installer هیچ بسته MySQL را دانلود، نصب یا به‌روزرسانی نمی‌کند. MySQL باید از قبل روی سیستم نصب باشد.

در اولین اجرای تعاملی، Installer مسیر و اطلاعات اتصال MySQL موجود را پیدا می‌کند یا از کاربر این موارد را می‌پرسد:

```text
Path to mysql.exe or MySQL bin directory
MySQL host/address [localhost]
MySQL port [3306]
MySQL administrative user [root]
Password for MySQL user 'root'
```

رمز در کنسول نمایش داده نمی‌شود. Installer فقط اتصال واقعی به MySQL را تست می‌کند و در صورت موفق بودن ادامه می‌دهد.

اگر `mysql.exe` در PATH یا مسیرهای استاندارد MySQL Server 8.0/8.4 پیدا شود، مسیر آن به‌صورت خودکار تشخیص داده می‌شود.

> نکته: عبارت `Release metadata download over GitHub IPv4` مربوط به بررسی آخرین Release خود ERP در GitHub است و هیچ ارتباطی با دانلود MySQL ندارد.

### دیتابیس‌های از قبل ایجادشده

Installer در `v2.0.16` دیتابیس یا User جدید ایجاد نمی‌کند و هیچ `CREATE DATABASE`، `CREATE USER`، `ALTER USER` یا `GRANT` اجرا نمی‌کند.

نام دیتابیس‌های مورد انتظار:

```text
Test       ecomm_dev
Production ecomm
```

این دو دیتابیس باید قبل از نصب توسط مدیر سیستم ایجاد شده باشند.

نمونه SQL اختیاری برای ساخت دستی:

```sql
CREATE DATABASE ecomm
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE ecomm_dev
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
```

Installer بعد از تست اتصال MySQL، وجود و دسترسی به دیتابیس مربوط به هر Channel را بررسی می‌کند. اگر دیتابیس وجود نداشته باشد یا قابل دسترسی نباشد، نصب با پیام واضح متوقف می‌شود.

### Migration فعلاً غیرفعال است

برای ساده و قابل‌کنترل نگه‌داشتن نصب اولیه، اجرای خودکار Migration و Seed فعلاً غیرفعال است:

```text
Database:Type=MySql
Database:AutoMigrate=false
Database:MigrateOnStartup=false
Database:EnsureCreatedIfNotExists=false
Database:SeedDataOnMigrate=false
Database:DropDatabaseOnStartup=false
```

بنابراین Installer فعلاً فقط:

```text
IIS / Management Tools
→ .NET 8 ASP.NET Core Hosting Bundle
→ پیدا کردن mysql.exe
→ تست اتصال MySQL موجود
→ بررسی دسترسی به ecomm_dev / ecomm
→ تولید appsettings.json
→ دریافت یا استفاده از Cache آخرین Release ERP
→ Stage و Activation
→ تنظیم IIS
→ Health Check
→ Rollback در صورت خطا
```

Migrationهای EF Core در مرحله جداگانه و کنترل‌شده انجام خواهند شد.

### تنظیمات اتصال MySQL

بعد از اتصال موفق، اطلاعات لازم برای اجرای بدون تعامل updater در مسیر زیر نگهداری می‌شود:

```text
D:\erp_ins\config\mysql-external.json
```

ACL این پوشه به `Administrators` و `SYSTEM` محدود می‌شود. این فایل را منتشر نکنید.

### آدرس‌های محلی

پس از نصب موفق:

```text
Test       http://127.0.0.1:8081/
Production http://127.0.0.1:8080/
```

صفحه setup در صورت نیاز برنامه:

```text
Test       http://127.0.0.1:8081/account/setup
Production http://127.0.0.1:8080/account/setup
```

توجه: با توجه به غیرفعال بودن Migration، آماده بودن این صفحات به وضعیت Schema دیتابیس بستگی دارد.

### Automatic Updater

Updater از ابتدای نصب ثبت می‌شود و هر ۵ دقیقه اجرا می‌شود:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

فایل پایدار Installer:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.16.ps1
```

Taskها با حساب `SYSTEM` و Highest Privileges اجرا می‌شوند و به `v2.0.16` اشاره می‌کنند. در اجرای خودکار، اطلاعات MySQL از `config\mysql-external.json` خوانده می‌شود و Prompt تعاملی نمایش داده نمی‌شود.

### اجرای غیرتعاملی اختیاری

در صورت نیاز می‌توان اطلاعات MySQL را هنگام اجرای اولیه به‌صورت پارامتر داد:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -MySqlBinPath 'C:\Program Files\MySQL\MySQL Server 8.0\bin' `
  -MySqlHost 'localhost' `
  -MySqlPort 3306 `
  -MySqlRootUser 'root' `
  -Force
```

برای امنیت بهتر، Password را در Command History وارد نکنید؛ در اجرای عادی Installer آن را به‌صورت Secure Prompt می‌پرسد.

### Cache و IPv4

دانلود Bootstrap/Core و Releaseهای ERP با `curl.exe -4 --http1.1` انجام می‌شوند. اگر ZIP معتبر Release در `PackageCacheDirectory` موجود باشد دوباره دانلود نمی‌شود.

**هیچ دانلود MySQL انجام نمی‌شود.**

### مهاجرت نصب قبلی

اگر نصب قبلی در مسیر زیر وجود داشته باشد:

```text
C:\ProgramData\iMonitorERP
```

Installer تنظیمات عمومی و `App_Data` را در صورت وجود حفظ می‌کند، اما Connection String دیتابیس را با اطلاعات MySQL تاییدشده نصب فعلی و نام دیتابیس کانال جایگزین می‌کند. مسیر قدیمی حذف نمی‌شود.

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
