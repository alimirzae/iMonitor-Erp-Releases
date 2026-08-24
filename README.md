# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform — پایش، رهگیری، Vision، FTP، RFID و IIoT

نسخه Linux کل سامانه iMonitor از مخزن `alimirzae/iTrack` به صورت Release مستقل منتشر می‌شود و شامل Backend، Frontend، FTP، Celery، MySQL، Redis، Nginx، پلاک‌خوان، Face/QR، Demo Lab، Automation و IIoT است.

**صفحه انتشارها:** https://github.com/alimirzae/iMonitor-Erp-Releases/releases

**آخرین انتشار iMonitor Platform:** https://github.com/alimirzae/iMonitor-Erp-Releases/releases/tag/imonitor-platform-v0.1.2

### نصب یک‌مرحله‌ای Ubuntu / Debian — Installer v1.0.2

روی سرور Linux اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.2.sh | sudo bash
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

Updater نسخه‌دار `Update-iMonitorPlatform-v1.0.2.sh` نصب می‌شود. Timer سیستم هر ۳۰ دقیقه manifest و GitHub Releases را بررسی می‌کند و Installer نسخه فعلی را با cache-busting دریافت می‌کند. خود Installer جدیدترین Release با پیشوند `imonitor-platform-v` را نصب می‌کند.

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

### کانال‌های انتشار

| Source branch | Release tag | Port |
| --- | --- | --- |
| `test` | `imonitor-ecomerp-test-vX.Y.Z` | 8080 |
| `master` | `imonitor-ecomerp-master-vX.Y.Z` | 80 |

هر Release استاندارد ERP شامل این فایل‌هاست:

- `iMonitor-EcomERP-linux-x64.tar.gz`
- `iMonitor-EcomERP-linux-x64.tar.gz.sha256`
- `iMonitor-EcomERP-win-x64.zip`
- `iMonitor-EcomERP-win-x64.zip.sha256`
- `manifest.json`

## نصب ERP روی Ubuntu / Debian / WSL — v1.0.6

نسخه 1.0.6 انتشارهای prerelease کانال `test` را نیز شناسایی می‌کند و وقتی ابزارهای پایه از قبل نصب باشند، از اجرای غیرضروری `apt-get update` صرف‌نظر می‌کند.

نسخه تست:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.6.sh | sudo bash -s -- --channel test
```

نسخه پایدار:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.6.sh | sudo bash -s -- --channel master
```

## نصب ERP روی Windows x64 — v1.0.5

PowerShell را با دسترسی Administrator اجرا کنید:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.5.ps1 -OutFile $env:TEMP\Install-iMonitorERP.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\Install-iMonitorERP.ps1 -Channel test
```

برای نسخه پایدار مقدار `-Channel master` را بدهید.

## امنیت و Rollback

- Assetها با SHA-256 اعتبارسنجی می‌شوند.
- تنظیمات و Secretها خارج از Release نگهداری می‌شوند.
- هر نسخه iMonitor Platform در پوشه مستقل نصب می‌شود و symlink `current` به نسخه فعال اشاره می‌کند.
- Docker volumes دیتابیس با تعویض نسخه حذف نمی‌شوند.
- Windows Edge و Android Edge Releaseهای جدا دارند.


---

## نصب یکپارچه iMonitor ERP v2.0.0

Installer نسخه 2 هر دو کانال Test و Production را هم‌زمان نصب و مدیریت می‌کند.

### Linux / Ubuntu — Docker + MySQL + phpMyAdmin

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash
```

پورت‌های پیش‌فرض:

| Service | Port |
| --- | ---: |
| ERP Test | 8080 |
| ERP Production | 8081 |
| phpMyAdmin | 8082 روی 127.0.0.1 |
| MySQL | فقط شبکه داخلی Docker |

برای تغییر پورت‌ها:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh \
  | sudo bash -s -- --test-port 8080 --prod-port 8081 --phpmyadmin-port 8082
```

رمز root و کاربران مستقل MySQL در فایل زیر نگهداری می‌شوند:

```text
/etc/imonitor-erp/credentials.env
```

فایل فقط برای root قابل خواندن است. مشاهده امن اطلاعات:

```bash
sudo imonitor-erpctl credentials
```

ورود phpMyAdmin:

- Server: `mysql`
- User: `root`
- Password: مقدار `MYSQL_ROOT_PASSWORD`

phpMyAdmin به‌صورت پیش‌فرض فقط روی localhost باز است. برای دسترسی امن از کامپیوتر دیگر:

```bash
ssh -L 8082:127.0.0.1:8082 user@SERVER-IP
```

سپس `http://127.0.0.1:8082` را باز کنید. بازکردن مستقیم phpMyAdmin روی اینترنت توصیه نمی‌شود.

فرمان‌های مدیریت:

```bash
sudo imonitor-erpctl status
sudo imonitor-erpctl logs 200
sudo imonitor-erpctl restart erp-test
sudo imonitor-erpctl restart erp-production
sudo imonitor-erpctl update-test
sudo imonitor-erpctl update-production
sudo imonitor-erpctl update-all
sudo imonitor-erpctl mysql
```

زمان‌بندی خودکار:

- Test: هر ۵ دقیقه
- Production: روزانه در بازه ۲:۳۰ تا ۵:۳۰ بامداد
- تمام containerها دارای restart policy هستند.
- تنظیمات، داده MySQL، Data Protection keys و Diagnostics خارج از پوشه Release نگهداری می‌شوند.

### Windows — نصب هم‌زمان Test و Production

PowerShell را با دسترسی Administrator اجرا کنید:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.ps1 -OutFile $env:TEMP\Install-iMonitorERP.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\Install-iMonitorERP.ps1 -Channel Both
```

تنظیمات MySQL را می‌توان هنگام نصب تعیین کرد:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\Install-iMonitorERP.ps1 `
  -Channel Both -MySqlServer 127.0.0.1 -MySqlPort 3306 `
  -TestUser imonitor_test -TestPassword 'TEST_PASSWORD' `
  -ProductionUser imonitor_production -ProductionPassword 'PRODUCTION_PASSWORD'
```

در Windows دو Service و دو Scheduled Task مستقل ساخته می‌شود:

- `iMonitorERP-Test` روی پورت 8080؛ بررسی update هر ۵ دقیقه
- `iMonitorERP-Production` روی پورت 8081؛ بررسی update روزانه ساعت ۲:۳۰

اطلاعات MySQL با ACL محدود به Administrators و SYSTEM در این مسیر ذخیره می‌شود:

```text
C:\ProgramData\iMonitorERP\config\mysql-credentials.json
```


### Windows + Docker Desktop — نصب کامل برنامه و MySQL

PowerShell را با دسترسی Administrator اجرا کنید:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Docker-v2.0.0.ps1 -OutFile $env:TEMP\Install-iMonitorERP-Docker.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\Install-iMonitorERP-Docker.ps1 -Channel Both
```

Installer قابلیت‌های WSL2 و Virtual Machine Platform را فعال و Docker Desktop را با backend مبتنی بر WSL2 نصب می‌کند. اگر Windows نیاز به Restart داشته باشد، Installer با پیام مشخص متوقف می‌شود؛ پس از Restart و اولین اجرای Docker Desktop، همان فرمان را دوباره اجرا کنید.

این روش موارد زیر را هم‌زمان اجرا می‌کند:

- ERP Test روی پورت 8080
- ERP Production روی پورت 8081
- MySQL 8.4 داخل Docker
- phpMyAdmin روی `127.0.0.1:8082`
- volumeهای پایدار MySQL، Data Protection و Diagnostics
- بروزرسانی Test هر پنج دقیقه
- بروزرسانی Production روزانه ساعت 02:30
- checksum و rollback فایل‌های برنامه

رمزهای MySQL در این فایل با ACL محدود به Administrators و SYSTEM ذخیره می‌شوند:

```text
C:\ProgramData\iMonitorERP-Docker\credentials.env
```

نمایش رمز root در PowerShell مدیر:

```powershell
Get-Content C:\ProgramData\iMonitorERP-Docker\credentials.env |
    Select-String '^MYSQL_ROOT_PASSWORD='
```

وضعیت containerها:

```powershell
cd C:\ProgramData\iMonitorERP-Docker
docker compose --env-file .\credentials.env ps
docker compose --env-file .\credentials.env logs --tail 200
```


---

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
