# iMonitor ERP Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor ERP

## iMonitor Ecom ERP

این محصول از پروژه `Ecomm` ساخته می‌شود.

```
Ecomm Source
    |
    v
GitHub Actions
    |
    v
Ecomm ERP ZIP Release
    |
    v
Customer Linux Server
```

## Ubuntu / Debian / WSL Installer

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.3.sh | sudo bash -s -- --channel test
```

## مراحل Installer

Installer:

1. dependency ها را بررسی می‌کند.
2. Release فقط مربوط به iMonitor Ecom ERP را پیدا می‌کند.
3. نسخه فعلی را با آخرین نسخه GitHub مقایسه می‌کند.
4. در صورت نیاز فایل ZIP را دانلود می‌کند.
5. progress دانلود، سرعت و وضعیت را نمایش می‌دهد.
6. نسخه جدید را جایگزین می‌کند.
7. سرویس Linux را مدیریت می‌کند.
8. update checker خودکار را فعال می‌کند.

## بروزرسانی خودکار

بعد از نصب، سرور هر ۳۰ دقیقه GitHub Release را بررسی می‌کند.

در صورت انتشار نسخه جدید:

- دانلود خودکار انجام می‌شود.
- نسخه جدید نصب می‌شود.
- سرویس restart می‌شود.

بدون نیاز به login یا token گیتهاب.

## استاندارد Release

فقط Releaseهای زیر توسط Ecomm Installer استفاده می‌شوند:

```
imonitor-ecomerp-test-vX.Y.Z
imonitor-ecomerp-master-vX.Y.Z
```

Windows Edge و Android Edge Release جدا هستند و توسط این Installer خوانده نمی‌شوند.

## پورت‌ها

| Channel | Port |
|---|---|
| test | 8080 |
| master | 80 |

## امنیت

هیچ Secret در Release Center ذخیره نمی‌شود.
