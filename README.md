# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نسخه Linux سامانه iMonitor از Releaseهای همین مخزن نصب می‌شود. نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

خروجی معمول Platform شامل Web UI روی `3000`، Gateway روی `80`، API روی `8000` و سرویس‌های Docker/Compose است. تنظیمات و Secretها در `/etc/imonitor-platform/imonitor.env` نگهداری می‌شوند.

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.3

برای جلوگیری از مشکل cache همیشه Installer نسخه‌دار جدید را دریافت کنید. PowerShell را با **Run as Administrator** باز کنید:

```powershell
$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.3.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Invoke-WebRequest `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.3.ps1?cb=$cacheBust" `
  -UseBasicParsing `
  -OutFile $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both
```

پورت‌های رسمی Windows:

| کانال | آدرس | IIS Site / App Pool | مسیر برنامه |
|---|---|---|---|
| Production | `http://localhost:8080` | `iMonitorERP-Production` | `C:\ProgramData\iMonitorERP\production\current` |
| Test | `http://localhost:8081` | `iMonitorERP-Test` | `C:\ProgramData\iMonitorERP\test\current` |

### استفاده از ZIP از قبل دانلودشده

اگر `iMonitor-EcomERP-win-x64.zip` را با مرورگر دانلود کرده‌اید، آن را در پوشه کاری، مثلاً `D:\erp_ins` قرار دهید:

```powershell
Set-Location D:\erp_ins
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -Channel Both `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

Installer checksum آخرین Release را می‌گیرد و SHA-256 فایل محلی را بررسی می‌کند. اگر فایل معتبر و مربوط به همان Release باشد، دانلود Package کاملاً رد می‌شود.

### MySQL

Installer برای Test و Production دیتابیس، User و Grant جداگانه ایجاد و ورود واقعی همان User به Database را تست می‌کند. اگر حساب‌ها هنوز وجود نداشته باشند، رمز مدیر MySQL به‌صورت تعاملی و SecureString درخواست می‌شود و ذخیره نمی‌شود.

تنظیمات پایدار MySQL در فایل زیر نگهداری می‌شوند و ACL آن فقط برای Administrators و SYSTEM است:

```text
C:\ProgramData\iMonitorERP\config\mysql-credentials.json
```

در v2.0.3 این فایل منبع پایدار تنظیمات اتصال برای بروزرسانی‌های خودکار است و این موارد را نگه می‌دارد:

```text
Server
Port
TestDatabase
TestUser
TestPassword
ProductionDatabase
ProductionUser
ProductionPassword
```

اولویت انتخاب تنظیمات در v2.0.3:

```text
پارامتر صریح خط فرمان
    ↓
mysql-credentials.json
    ↓
appsettings.json نصب موجود
    ↓
مقدار پیش‌فرض Installer
```

بنابراین اجرای Scheduled Task با `-UpdateOnly` دیگر نام Database/User سفارشی را به `imonitor_erp_test` یا `imonitor_test` برنمی‌گرداند.

نام‌های پیش‌فرض فقط برای نصب اولیه‌ای هستند که هنوز تنظیم ذخیره‌شده‌ای ندارد:

```text
Test       imonitor_erp_test        imonitor_test
Production imonitor_erp_production  imonitor_production
```

برای تغییر پایدار دیتابیس Test می‌توانید یک بار Installer را با مقادیر صریح اجرا کنید:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -Channel Test `
  -TestDatabase 'your_test_database' `
  -TestUser 'your_test_user' `
  -TestPassword 'your_password' `
  -UpdateOnly
```

پس از آن مقادیر در `mysql-credentials.json` ذخیره می‌شوند و بروزرسانی‌های بعدی همان مقادیر را استفاده می‌کنند. برای امنیت، Password داخل Command Line مربوط به Scheduled Task ذخیره نمی‌شود.

فایل runtime واقعی هر کانال:

```text
C:\ProgramData\iMonitorERP\test\current\appsettings.json
C:\ProgramData\iMonitorERP\production\current\appsettings.json
```

در زمان نصب/بروزرسانی، Installer این فایل‌ها را بر اساس تنظیمات پایدار بالا merge می‌کند. اگر فقط `appsettings.json` را دستی تغییر دهید ولی `mysql-credentials.json` مقدار دیگری داشته باشد، بروزرسانی بعدی مقدار ذخیره‌شده در credentials را دوباره اعمال می‌کند.

### راه‌اندازی اولیه و Recovery

در v2.0.3، مانند v2.0.2، `Database:MigrateOnStartup` عمداً خاموش است. بنابراین خرابی Migration نباید IIS Worker را قبل از بالا آمدن رابط بازیابی متوقف کند. Migration در حالت خرابی از مسیر نگهداری انجام می‌شود:

```text
/Admin/Database/Migrate
/Account/Reset
```

این مسیر با OTP پیامکی محافظت می‌شود. شماره و شناسه مدیر بازیابی را در سورس قرار ندهید؛ روی سرور از Environment Variable استفاده کنید:

```powershell
[Environment]::SetEnvironmentVariable('IMONITOR_BOOTSTRAP_NATIONAL_CODE', '<bootstrap-id>', 'Machine')
[Environment]::SetEnvironmentVariable('IMONITOR_BOOTSTRAP_MOBILE', '<mobile>', 'Machine')
```

یا هنگام اجرای Installer مقدارها را با پارامترهای زیر بدهید:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -Channel Both `
  -BootstrapAdminNationalCode '<bootstrap-id>' `
  -BootstrapAdminMobile '<mobile>'
```

تنظیمات OTP: اعتبار ۵ دقیقه، حداکثر ۵ تلاش، فاصله ارسال مجدد ۶۰ ثانیه و دسترسی نگهداری ۱۵ دقیقه. پیامک System Recovery می‌تواند در زمان خرابی ApplicationDbContext مستقیماً از Provider ابری تنظیم‌شده استفاده کند؛ پیامک‌های وابسته به Company همچنان fail-closed می‌مانند.

پس از Migration، برای نصب خام به `/Account/Setup` بروید تا مدیر، شرکت، شعبه و دفتر اصلی ایجاد شوند.

### نصب و بروزرسانی مستقل کانال‌ها

```powershell
# Production
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Production -Force

# Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Test -Force

# فقط بروزرسانی نصب موجود
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

Test و Production مستقل نصب می‌شوند؛ خطای یکی مانع تلاش برای کانال دیگر نمی‌شود. Scheduled Task مربوط به Test هر ۵ دقیقه و Production روزانه اجرا می‌شود و v2.0.3 را با cache-busting دریافت می‌کند. Scheduled Task فقط `Channel` و `UpdateOnly` را می‌فرستد و v2.0.3 تنظیمات کامل اتصال را از فایل امن credentials بازیابی می‌کند.

### ساختار نصب Windows

```text
C:\ProgramData\iMonitorERP\
├── config\mysql-credentials.json
├── installer\Install-iMonitorERP-v2.0.3.ps1
├── state\
├── dotnet\
├── production\
│   ├── current\
│   └── releases\
└── test\
    ├── current\
    └── releases\
```

### عیب‌یابی IIS و 500.30 / 503

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

لاگ‌های IIS:

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

فاز چاپ مستقیم Windows Edge روی رایانه متصل به چاپگر اجرا می‌شود. Endpointهای اصلی:

```text
Health             http://127.0.0.1:17891/health
Printer discovery  http://127.0.0.1:17891/api/printers
Direct label print POST http://127.0.0.1:17891/api/labels/print
```

نصب One-Click:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-New-Win-Edge.ps1 | iex"
```

بسته در `%LOCALAPPDATA%\iMonitor\New_Win_Edge\current` نصب می‌شود. انتشار نهایی وابسته به `published: true` در manifest مربوط به New Windows Edge است.
