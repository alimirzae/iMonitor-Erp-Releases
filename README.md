# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.19

PowerShell را با **Run as Administrator** باز کنید و وارد پوشه‌ای شوید که می‌خواهید ERP همان‌جا نصب شود:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.19.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.19.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.19` نسخه رسمی نصب Windows است. نسخه‌های `v2.0.15` تا `v2.0.18` بازنشسته شده‌اند.

### رفتار مستقل Test و Production

از `v2.0.19` دو کانال مستقل deploy می‌شوند:

```text
Test       -> ecomm_dev -> port 8081
Production -> ecomm     -> port 8080
```

اگر Test با موفقیت نصب و Online شود ولی Production خطا بدهد، Test فعال باقی می‌ماند و نصب کلی برای حالت `-Channel Both` به خاطر خطای Production rollback نمی‌شود. خطای Production به شکل Warning ثبت می‌شود و Scheduled Task مخصوص Production هر ۵ دقیقه دوباره تلاش می‌کند.

بنابراین سیاست نصب به شکل زیر است:

```text
Test success + Production success -> نصب کامل
Test success + Production failure -> Test فعال می‌ماند؛ Production بعداً retry می‌شود
Test failure                       -> نصب ناموفق
Production-only failure            -> همان اجرای Production ناموفق است و updater بعداً retry می‌کند
```

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

نام دیتابیس‌های مورد انتظار:

```text
Test       ecomm_dev
Production ecomm
```

Installer دیتابیس یا User جدید ایجاد نمی‌کند و هیچ `CREATE DATABASE`، `CREATE USER`، `ALTER USER` یا `GRANT` اجرا نمی‌کند.

### Releaseهای ERP

الگوی Releaseهای Windows:

```text
Test       imonitor-ecomerp-test-v*
Production imonitor-ecomerp-master-v*
Asset      iMonitor-EcomERP-win-x64.zip
```

انتشار عمومی از مخزن `alimirzae/Ecomm` انجام می‌شود. Workflow مربوط به `test` و `master` هر دو را build/test می‌کند و SHA تاییدشده را به `alimirzae/iMonitor-Erp-Releases` dispatch می‌کند. در مخزن Release، برای `master` تگ با الگوی `imonitor-ecomerp-master-v*` ساخته می‌شود و برای `test` تگ `imonitor-ecomerp-test-v*`.

### appsettings و رفع 404 Production

در `v2.0.19` وابستگی به دانلود مستقیم فایل زیر از شاخه source حذف شده است:

```text
Ecomm/<branch>/Ecomm/appsettings.json
```

Installer بعد از Extract، همان `appsettings.json` داخل پکیج Release را مبنا قرار می‌دهد؛ اگر نصب قبلی موجود باشد، appsettings موجود محلی نیز می‌تواند به عنوان پایه استفاده شود. به این ترتیب خطای 404 با عنوان `Production base appsettings` دیگر نباید رخ دهد.

### Migration فعلاً غیرفعال است

```text
Database:Type=MySql
Database:AutoMigrate=false
Database:MigrateOnStartup=false
Database:EnsureCreatedIfNotExists=false
Database:SeedDataOnMigrate=false
Database:DropDatabaseOnStartup=false
```

Migrationهای EF Core در مرحله جداگانه و کنترل‌شده انجام خواهند شد.

### Automatic Updater

Updater از ابتدای نصب ثبت می‌شود و هر ۵ دقیقه اجرا می‌شود:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

فایل پایدار Installer:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.19.ps1
```

Taskها با حساب `SYSTEM` و Highest Privileges اجرا می‌شوند و هر کانال را مستقل به‌روزرسانی می‌کنند. اگر Production هنگام نصب اولیه آماده نباشد یا انتشار جدید نرسیده باشد، `iMonitorERP-Update-Production` بعداً آن را دوباره امتحان می‌کند.

### تنظیمات اتصال MySQL

اطلاعات لازم برای اجرای بدون تعامل updater در مسیر زیر نگهداری می‌شود:

```text
D:\erp_ins\config\mysql-external.json
```

ACL این پوشه به `Administrators` و `SYSTEM` محدود می‌شود. این فایل را منتشر نکنید.

### Cache و IPv4

دانلود Bootstrap/Core و Releaseهای ERP با `curl.exe -4 --http1.1` انجام می‌شوند. cache-buster میلی‌ثانیه‌ای و هدرهای `Cache-Control: no-cache` و `Pragma: no-cache` استفاده می‌شوند. فایل Core موقت در هر اجرا نام GUID جدید دارد.

اگر ZIP معتبر Release در `PackageCacheDirectory` موجود باشد دوباره دانلود نمی‌شود.

**هیچ دانلود MySQL انجام نمی‌شود.**

### آدرس‌های محلی

```text
Test       http://127.0.0.1:8081/
Production http://127.0.0.1:8080/
```

صفحه setup در صورت نیاز برنامه:

```text
Test       http://127.0.0.1:8081/account/setup
Production http://127.0.0.1:8080/account/setup
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
