# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform — پایش، رهگیری، Vision، FTP، RFID و IIoT

نسخه Linux کل سامانه iMonitor از مخزن `alimirzae/iTrack` به صورت Release مستقل منتشر می‌شود و شامل Backend، Frontend، FTP، Celery، MySQL، Redis، Nginx، پلاک‌خوان، Face/QR، Demo Lab، Automation و IIoT است.

**صفحه انتشارها:** https://github.com/alimirzae/iMonitor-Erp-Releases/releases

**آخرین انتشار iMonitor Platform:** https://github.com/alimirzae/iMonitor-Erp-Releases/releases/tag/imonitor-platform-v0.1.1

### نصب یک‌مرحله‌ای Ubuntu / Debian — Installer v1.0.1

روی سرور Linux اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.1.sh | sudo bash
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

Updater نسخه‌دار `Update-iMonitorPlatform-v1.0.1.sh` نصب می‌شود. Timer سیستم هر ۳۰ دقیقه manifest و GitHub Releases را بررسی می‌کند و Installer نسخه فعلی را با cache-busting دریافت می‌کند. خود Installer جدیدترین Release با پیشوند `imonitor-platform-v` را نصب می‌کند.

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

## نصب ERP روی Ubuntu / Debian / WSL — v1.0.5

نسخه تست:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.5.sh | sudo bash -s -- --channel test
```

نسخه پایدار:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.5.sh | sudo bash -s -- --channel master
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
