# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform — پایش، رهگیری، Vision، FTP، RFID و IIoT

نسخه Linux کل سامانه iMonitor از مخزن `alimirzae/iTrack` به صورت Release مستقل منتشر می‌شود و شامل Backend، Frontend، FTP، Celery، MySQL، Redis، Nginx، پلاک‌خوان، Face/QR، Demo Lab، Automation و IIoT است.

**صفحه انتشارها:** https://github.com/alimirzae/iMonitor-Erp-Releases/releases

**آخرین انتشار iMonitor Platform:** https://github.com/alimirzae/iMonitor-Erp-Releases/releases/tag/imonitor-platform-v0.1.2

### نصب یک‌مرحله‌ای Ubuntu / Debian — Installer v1.0.3

روی سرور Linux اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

Installer موارد زیر را خودکار انجام می‌دهد:

- نصب وابستگی‌های پایه و Docker/Compose در صورت نیاز
- پیدا کردن جدیدترین Release با پیشوند `imonitor-platform-v`
- دانلود بسته Source و Docker imageهای از پیش ساخته‌شده
- کنترل SHA-256 قبل از نصب
- نگهداری تنظیمات و Secretها در `/etc/imonitor-platform/imonitor.env`
- نصب نسخه‌ها در `/opt/imonitor-platform/releases/<version>` و سوییچ اتمیک `current`
- اجرای کل Stack با Docker Compose
- Bind سرویس‌های عمومی روی `0.0.0.0` و باز کردن پورت‌های لازم در UFW در صورت فعال بودن آن
- بررسی واقعی Backend و Frontend بعد از `docker compose up`
- اگر Container از کار افتاده، Restart loop داشته باشد یا سرویس در مهلت مقرر بالا نیاید، چاپ خودکار `docker compose ps -a` و ۲۰۰ خط آخر log تمام سرویس‌ها در همان Terminal
- ایجاد سرویس startup و Timer بروزرسانی خودکار

پس از نصب:

- Web UI: `http://SERVER-IP:3000`
- Gateway/Nginx: `http://SERVER-IP:80`
- API: `http://SERVER-IP:8000`
- FTP: `SERVER-IP:21`
- FTP Passive: `30000-30010/tcp`

### بروزرسانی خودکار

Updater نسخه‌دار `Update-iMonitorPlatform-v1.0.3.sh` نصب می‌شود. Timer سیستم هر ۳۰ دقیقه manifest و GitHub Releases را بررسی می‌کند و Installer نسخه فعلی را با cache-busting دریافت می‌کند. خود Installer جدیدترین Release با پیشوند `imonitor-platform-v` را نصب می‌کند.

بررسی وضعیت:

```bash
systemctl status imonitor-platform.service
systemctl status imonitor-platform-update.timer
docker compose -f /opt/imonitor-platform/current/docker-compose.yml ps
```

مشاهده Logها در صورت نیاز:

```bash
cd /opt/imonitor-platform/current
docker compose ps -a
docker compose logs --tail=200
```

اجرای دستی Update:

```bash
sudo /usr/local/sbin/imonitor-platform-update
```

هر بار Installer یا Updater تغییر اساسی کند با نام نسخه جدید منتشر می‌شود (`v1.0.0`, `v1.0.1`, ...)، بنابراین URL قدیمی cache نمی‌شود. فایل `manifests/imonitor-platform-release.json` همیشه نام Installer فعلی را مشخص می‌کند و Updater برای دریافت manifest و script از cache-busting استفاده می‌کند.

---

## iMonitor ERP / Ecomm ERP

### نصب پیشنهادی Windows x64 — IIS و MySQL

PowerShell را با **Run as Administrator** باز کنید و فقط این دستور را اجرا کنید:

```powershell
$installer = Join-Path $env:TEMP 'Install-iMonitorERP.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Invoke-WebRequest `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.ps1?cb=$cacheBust" `
  -UseBasicParsing `
  -OutFile $installer

powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both
```

اگر فایل `iMonitor-EcomERP-win-x64.zip` را با مرورگر دانلود کرده‌اید، آن را در همان پوشه‌ای قرار دهید که PowerShell از آن اجرا می‌شود. مثلاً:

```text
D:\erp_ins\iMonitor-EcomERP-win-x64.zip
```

سپس نصب را از همان مسیر اجرا کنید یا مسیر Cache را صریح تعیین کنید:

```powershell
Set-Location D:\erp_ins
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -Channel Both `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

Installer ابتدا SHA-256 فایل محلی را با checksum آخرین Release مقایسه می‌کند. اگر یکسان باشد دانلود ZIP کاملاً رد می‌شود؛ در غیر این صورت فایل محلی دست‌نخورده می‌ماند و نسخه صحیح در زیرپوشه نام Release دانلود می‌شود.

خروجی نصب:

| کانال | آدرس | IIS Site / App Pool | مسیر برنامه |
|---|---|---|---|
| Production | http://localhost:8080 | `iMonitorERP-Production` | `C:\ProgramData\iMonitorERP\production\current` |
| Test | http://localhost:8081 | `iMonitorERP-Test` | `C:\ProgramData\iMonitorERP\test\current` |

Installer در اولین نصب این کارها را انجام می‌دهد:

- نصب و فعال‌سازی IIS Manager و ASP.NET Core Hosting Bundle 8
- دریافت آخرین Releaseهای `master` و `test` و کنترل SHA-256
- ایجاد Database، User و Grant مستقل MySQL برای هر کانال
- تست واقعی ورود هر User به Database مربوط به خودش
- merge کردن تنظیمات دیتابیس داخل `appsettings.json`؛ تنظیمات SMS، AI، Sync و Logging حذف نمی‌شوند
- ایجاد Site و Application Pool مستقل در IIS Manager
- نصب Test و Production به‌صورت مستقل؛ خطای یک کانال مانع تلاش برای نصب کانال دیگر نمی‌شود
- Health Check واقعی هر دو سایت و ثبت Auto Update

اگر Userهای MySQL هنوز وجود نداشته باشند، Installer رمز مدیر MySQL (پیش‌فرض: `root`) را به‌صورت امن درخواست می‌کند. این رمز ذخیره نمی‌شود. رمزهای سرویس ERP در مسیر زیر نگهداری می‌شوند و فقط Administrators و SYSTEM به آن دسترسی دارند:

```text
C:\ProgramData\iMonitorERP\config\mysql-credentials.json
```

برای نام متفاوت مدیر MySQL:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
  -Channel Both `
  -MySqlAdminUser root
```

### ساختار نصب Windows

```text
C:\ProgramData\iMonitorERP\
├── config\mysql-credentials.json
├── installer\Install-iMonitorERP.ps1
├── state\
├── dotnet\
├── production\
│   ├── current\
│   └── releases\
└── test\
    ├── current\
    └── releases\
```

### نصب یا بروزرسانی یک کانال

```powershell
# نصب/ترمیم Production
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Production -Force

# نصب/ترمیم Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Test -Force

# بروزرسانی فقط روی نصب موجود
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Both -UpdateOnly
```

`-UpdateOnly` نصب اولیه انجام نمی‌دهد و اگر کانالی قبلاً نصب نشده باشد، خطای روشن برمی‌گرداند.

### عیب‌یابی IIS و خطاهای 500.30 / 503

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

لاگ‌های اجرای IIS:

```text
C:\ProgramData\iMonitorERP\production\current\logs
C:\ProgramData\iMonitorERP\test\current\logs
```

### Linux / Ubuntu

نصب Linux همچنان با Installer نسخه‌دار انجام می‌شود:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash -s -- --channel both
```

در Windows، مرجع رسمی پورت‌ها همیشه Production روی `8080` و Test روی `8081` است.

## New_Win_Edge — فاز یک چاپ مستقیم بارکد

این برنامه روی همان رایانه Windows که پرینتر به آن متصل است نصب می‌شود و API محلی زیر را بدون نمایش فرم اجرا می‌کند:

- Health: `http://127.0.0.1:17891/health`
- Printer discovery: `http://127.0.0.1:17891/api/printers`
- Direct barcode print: `POST http://127.0.0.1:17891/api/labels/print`

### نصب One-Click روی Windows

PowerShell معمولی را باز و این فرمان را اجرا کنید:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-New-Win-Edge.ps1 | iex"
```

Installer بسته را از `manifests/new-win-edge-preview.json` دریافت، SHA-256 را بررسی و در مسیر زیر نصب می‌کند:

```text
%LOCALAPPDATA%\iMonitor\New_Win_Edge\current
```

برنامه در Startup کاربر ثبت می‌شود، Headless اجرا می‌شود و چاپ مستقیم از پنجره «چاپ برچسب کالا» در Ecomm انجام می‌گیرد. برای نمایش رابط نگهداری می‌توان فایل اجرایی را با `--show-ui` اجرا کرد.

> تا وقتی manifest مقدار `published: true` نداشته باشد، installer عمداً نصب را متوقف می‌کند. workflow مخزن `New_Windows_Edge` پس از build موفق بسته و manifest را منتشر می‌کند.
