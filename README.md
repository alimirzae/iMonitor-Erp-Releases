# iMonitor ERP Release Center

مرکز عمومی انتشار و نصب خودکار iMonitor ERP برای Windows و Linux.

## کانال‌های انتشار

| Source branch | Release tag | Port |
| --- | --- | --- |
| `test` | `imonitor-ecomerp-test-vX.Y.Z` | 8080 |
| `master` | `imonitor-ecomerp-master-vX.Y.Z` | 80 |

هر Release استاندارد شامل این فایل‌هاست:

- `iMonitor-EcomERP-linux-x64.tar.gz`
- `iMonitor-EcomERP-linux-x64.tar.gz.sha256`
- `iMonitor-EcomERP-win-x64.zip`
- `iMonitor-EcomERP-win-x64.zip.sha256`
- `manifest.json`

بسته‌ها از یک SHA واحد پروژه Ecomm ساخته می‌شوند و Asset براساس سیستم‌عامل صریح انتخاب می‌شود.

## نصب Ubuntu / Debian / WSL — v1.0.5

نسخه تست:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.5.sh | sudo bash -s -- --channel test
```

نسخه پایدار:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.5.sh | sudo bash -s -- --channel master
```

Installer وابستگی‌های پایه و ASP.NET Core Runtime 8 را در صورت نیاز نصب می‌کند، SHA-256 را کنترل می‌کند، نسخه قبلی را نگه می‌دارد و Timer بروزرسانی ۳۰ دقیقه‌ای می‌سازد.

## نصب Windows x64 — v1.0.5

PowerShell را با دسترسی Administrator اجرا کنید:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.5.ps1 -OutFile $env:TEMP\Install-iMonitorERP.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\Install-iMonitorERP.ps1 -Channel test
```

برای نسخه پایدار مقدار `-Channel master` را بدهید.

## بررسی Linux

```bash
systemctl status imonitor-ecom-erp-test.service
systemctl status imonitor-ecom-erp-test-update.timer
journalctl -u imonitor-ecom-erp-test.service -f
```

## امنیت و Rollback

- Assetها با SHA-256 اعتبارسنجی می‌شوند.
- نسخه جدید ابتدا در staging استخراج می‌شود.
- نسخه قبلی در پوشه `previous` باقی می‌ماند.
- هیچ Token یا Secret در Release Center ذخیره نمی‌شود.
- Windows Edge و Android Edge Releaseهای جدا دارند.
