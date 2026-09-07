# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.14

PowerShell را با **Run as Administrator** باز کنید و وارد پوشه‌ای شوید که می‌خواهید ERP همان‌جا نصب شود:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.14.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

curl.exe -4 --http1.1 -fL `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.14.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.14` نسخه رسمی نصب Windows است.

### نصب صفر تا صد در v2.0.14

Installer حالا فقط فایل ERP را کپی نمی‌کند. نصب تازه این زنجیره را انجام می‌دهد:

```text
IIS / Management Tools / WebSockets
→ .NET 8 ASP.NET Core Hosting Bundle
→ MySQL 8.4 LTS managed instance
→ Windows Service: iMonitorERP-MySQL
→ ساخت credential تصادفی و ذخیره امن محلی
→ ساخت دیتابیس Test و Production
→ ساخت Userهای اختصاصی Test و Production
→ Grant و تست Login واقعی
→ تولید/اصلاح appsettings.json با Connection String معتبر
→ دریافت و Stage آخرین Release
→ اجرای Migrationهای EF Core هنگام Startup
→ Health Check واقعی
→ Rollback در صورت خطا
→ First-run Wizard برای دیتابیس تازه
```

MySQL مدیریت‌شده به‌صورت پیش‌فرض فقط روی Loopback و پورت `3307` گوش می‌دهد تا با MySQL موجود روی `3306` تداخل نداشته باشد.

مسیرهای نمونه:

```text
D:\erp_ins\mysql\server
D:\erp_ins\mysql\data
D:\erp_ins\mysql\my.ini
D:\erp_ins\config\mysql-managed.json
D:\erp_ins\test\current
D:\erp_ins\production\current
D:\erp_ins\installer
```

فایل `mysql-managed.json` شامل credentialهای داخلی است و ACL آن به `Administrators` و `SYSTEM` محدود می‌شود. آن را منتشر یا حذف نکنید.

### دیتابیس‌های پیش‌فرض

```text
Test       imonitor_erp_test        user: imonitor_test
Production imonitor_erp_production  user: imonitor_production
```

Passwordها هنگام اولین نصب به‌صورت تصادفی تولید می‌شوند و در فایل تنظیمات امن محلی نگه داشته می‌شوند. Installer از Password ثابت توسعه‌ای Package استفاده نمی‌کند.

### Migration و First-run Wizard

`Database:MigrateOnStartup=true` و `Database:AutoMigrate=true` توسط Installer تنظیم می‌شود. بنابراین پس از آماده شدن MySQL، خود Ecomm Migrationهای EF Core را روی دیتابیس تازه اجرا می‌کند.

پس از نصب موفق:

```text
Test wizard       http://127.0.0.1:8081/account/setup
Production wizard http://127.0.0.1:8080/account/setup
```

Wizard برای اطلاعات اولیه کسب‌وکار/کاربر استفاده می‌شود؛ Installer دیتای واقعی فروشگاه را حدس نمی‌زند.

### Automatic Updater

Updater از ابتدای نصب ثبت می‌شود، نه فقط بعد از Health Check. بنابراین حتی اگر Activation اولین اجرا نیاز به اصلاح داشته باشد، Taskهای updater از بین نمی‌روند.

فایل پایدار Installer:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.14.ps1
```

Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر دو هر ۵ دقیقه با حساب `SYSTEM` و Highest Privileges اجرا می‌شوند. هر Task همان `InstallRoot`، `PackageCacheDirectory`، پورت‌های IIS و پورت Managed MySQL نصب اولیه را حفظ می‌کند.

در حالت updater، MySQL و credentialها دوباره ساخته نمی‌شوند؛ وضعیت موجود بررسی و حفظ می‌شود و فقط Release جدید در صورت وجود نصب می‌شود.

### Cache و IPv4

دانلودهای Installer با `curl.exe -4 --http1.1` انجام می‌شوند. Packageهای ERP با SHA-256 بررسی می‌شوند و ZIP معتبر موجود در `PackageCacheDirectory` دوباره دانلود نمی‌شود. Package MySQL نیز در Cache نگه داشته می‌شود تا اجرای بعدی نیاز به دانلود مجدد نداشته باشد.

### مهاجرت نصب قبلی

اگر نصب قبلی در مسیر زیر وجود داشته باشد:

```text
C:\ProgramData\iMonitorERP
```

Installer می‌تواند تنظیمات عمومی موجود را به‌عنوان پایه بخواند، اما بخش Database/MySQL را با credential معتبر Managed MySQL جایگزین می‌کند. مسیر قدیمی حذف نمی‌شود.

### انتشار امن و Rollback

```text
Validate package
→ Preserve persistent config/data
→ Stage release
→ Stop IIS only when needed
→ Atomic swap
→ Start IIS
→ Run startup migrations
→ /health
→ write installed version only after success
→ rollback on failure
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
