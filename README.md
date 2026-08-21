# iMonitor ERP Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor ERP

## iMonitor Ecom ERP

این محصول از پروژه `Ecomm` ساخته می‌شود.

```
Ecomm Source
    |
    v
GitHub Actions Build
    |
    v
Ecomm ERP ZIP Release
    |
    v
Customer Linux Server
```

## Ubuntu / Debian / WSL Installer v1.0.4

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.4.sh | sudo bash -s -- --channel test
```

برای نسخه پایدار:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.4.sh | sudo bash -s -- --channel master
```

## امکانات Installer

- نصب dependency های مورد نیاز
- تشخیص Release فقط مربوط به Ecomm ERP
- دانلود ZIP با نمایش progress
- retry در خطای دانلود
- نصب به عنوان Linux systemd service
- restart خودکار بعد از خطا
- backup نسخه قبلی
- بروزرسانی خودکار

## بروزرسانی خودکار

بعد از نصب، یک timer در systemd فعال می‌شود.

سرور هر ۳۰ دقیقه GitHub Release را بررسی می‌کند:

1. نسخه جدید پیدا می‌شود.
2. ZIP دانلود می‌شود.
3. نسخه قبلی backup می‌شود.
4. نسخه جدید فعال می‌شود.
5. سرویس restart می‌شود.

## استاندارد Release

فقط Releaseهای زیر توسط Installer استفاده می‌شوند:

```
imonitor-ecomerp-test-vX.Y.Z
imonitor-ecomerp-master-vX.Y.Z
```

Windows Edge و Android Edge Release جدا هستند و هیچ تداخلی با Ecomm ERP ندارند.

## پورت‌ها

| Channel | Port |
|---|---|
| test | 8080 |
| master | 80 |

## عیب‌یابی

بررسی سرویس:

```bash
systemctl status imonitor-ecom-erp-test.service
```

بررسی update timer:

```bash
systemctl status imonitor-ecom-erp-test-update.timer
```

مشاهده لاگ:

```bash
journalctl -u imonitor-ecom-erp-test.service -f
```

## امنیت

هیچ Secret در Release Center ذخیره نمی‌شود.
