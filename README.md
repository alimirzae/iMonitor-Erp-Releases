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

### Windows x64 — Installer رسمی v2.0.5

برای جلوگیری از مشکل cache همیشه Installer نسخه‌دار جدید را دریافت کنید. PowerShell را با **Run as Administrator** باز کنید:

```powershell
$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.5.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Invoke-WebRequest `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.5.ps1?cb=$cacheBust" `
  -UseBasicParsing `
  -OutFile $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

> v2.0.5 علاوه بر حفظ تنظیمات پایدار MySQL، خودش را در `C:\ProgramData\iMonitorERP\installer` تازه‌سازی می‌کند و Scheduled Task هر دو کانال Test و Production را روی بازه ۵ دقیقه بازسازی می‌کند.

### Mirror داخلی ایران و Fallback خودکار

برای کاهش وابستگی به اینترنت بین‌الملل و جلوگیری از مشکل IPv6، نسخه‌های ERP علاوه بر GitHub روی سرور داخلی `testerp.imonitor.ir` نیز Mirror می‌شوند. Installer/Updater مسیرهای موجود را با timeout کوتاه بررسی می‌کند، منبع سالم و سریع‌تر را انتخاب می‌کند و در صورت خرابی منبع انتخاب‌شده به منبع دوم برمی‌گردد. دسترسی GitHub در مسیرهای مبتنی بر `curl.exe` با IPv4 (`-4`) انجام می‌شود.

مسیرهای اصلی Mirror داخلی:

```text
https://testerp.imonitor.ir/downloads/erp/test/latest.json
https://testerp.imonitor.ir/downloads/erp/test/iMonitor-EcomERP-win-x64.zip
https://testerp.imonitor.ir/downloads/erp/master/latest.json
https://testerp.imonitor.ir/downloads/erp/master/iMonitor-EcomERP-win-x64.zip
https://testerp.imonitor.ir/downloads/erp/reports/official-reports.zip
https://testerp.imonitor.ir/downloads/erp/install/Install-iMonitorERP-v2.0.5.ps1.txt
```

فایل `latest.json` هر کانال شامل version/tag، SHA-256، commit مبدا و زمان انتشار است. بسته دانلودشده قبل از نصب با SHA-256 اعتبارسنجی می‌شود؛ بنابراین Mirror داخلی فقط یک cache ساده نیست و همان کنترل صحت Release را حفظ می‌کند.

منبع ترجیحی انتخاب‌شده در این فایل ذخیره می‌شود:

```text
C:\ProgramData\iMonitorERP\state\download-source.txt
```

منطق انتخاب منبع:

```text
Mirror داخلی سالم + GitHub سالم  -> سریع‌ترین منبع سالم
Mirror داخلی سالم + GitHub خراب  -> Mirror داخلی
Mirror داخلی خراب + GitHub سالم  -> GitHub با IPv4
اینترنت بین‌الملل قطع + Mirror سالم -> ادامه Update از داخل ایران
```

برای bootstrap روی سروری که دسترسی GitHub آن مشکل دارد می‌توان Installer را مستقیماً از Mirror داخلی دریافت کرد. پسوند `.txt` عمداً برای سرو ساده و بدون وابستگی به MIME خاص استفاده شده است:

```powershell
$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.5.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-WebRequest "https://testerp.imonitor.ir/downloads/erp/install/Install-iMonitorERP-v2.0.5.ps1.txt?cb=$cb" -UseBasicParsing -OutFile $installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

اگر Mirror داخلی در دسترس نباشد، bootstrap GitHub همچنان قابل استفاده است و برای دانلودهای GitHub داخل updater مسیر IPv4 ترجیح داده می‌شود.

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

در v2.0.5 این فایل منبع پایدار تنظیمات اتصال برای بروزرسانی‌های خودکار است و این موارد را نگه می‌دارد:

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

اولویت انتخاب تنظیمات در v2.0.5:

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

در v2.0.5، مانند v2.0.2، `Database:MigrateOnStartup` عمداً خاموش است. بنابراین خرابی Migration نباید IIS Worker را قبل از بالا آمدن رابط بازیابی متوقف کند. Migration در حالت خرابی از مسیر نگهداری انجام می‌شود:

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

پس از Migration، برای نصب خام به `/Account/Setup` بروید تا مدیر، شرکت، شعبه و دفتر اصلی ایجاد شوند.

### نصب و بروزرسانی مستقل کانال‌ها

```powershell
# Production
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Production -Force

# Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Test -Force

# فقط بروزرسانی نصب موجود + ارتقای خود updater و زمان‌بندی‌ها
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

Test و Production مستقل نصب می‌شوند. در v2.0.5، Scheduled Task مربوط به هر دو کانال Test و Production هر ۵ دقیقه اجرا می‌شود. هر بار اجرای v2.0.5 ابتدا منطق نصب/بروزرسانی را اجرا می‌کند، سپس آخرین نسخه خود `v2.0.5` را با cache-busting در `C:\ProgramData\iMonitorERP\installer` تازه می‌کند و هر دو Scheduled Task را دوباره به همین updater اشاره می‌دهد. Scheduled Task فقط `Channel` و `UpdateOnly` را می‌فرستد و تنظیمات کامل اتصال از فایل امن credentials بازیابی می‌شود.

### ساختار نصب Windows

```text
C:\ProgramData\iMonitorERP\
├── config\mysql-credentials.json
├── installer\Install-iMonitorERP-v2.0.5.ps1
├── state\
│   └── download-source.txt
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
