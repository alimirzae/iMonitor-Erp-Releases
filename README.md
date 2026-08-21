# iMonitor ERP Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor ERP

Repository:

https://github.com/alimirzae/iMonitor-Erp-Releases

## iMonitor Ecom ERP

نسخه مبتنی بر پروژه Ecomm:

```
imonitor-ecom-erp
```

این نسخه مستقل از `imonitor-erp` منتشر می‌شود و برای نصب روی سرورهای مشتری طراحی شده است.

## نصب Ubuntu / Debian / WSL

### Ecom ERP Installer v1.0.2

نسخه تست:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.2.sh | sudo bash -s -- --channel test
```

نسخه پایدار:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.2.sh | sudo bash -s -- --channel master
```

## مراحل نصب

Installer مراحل زیر را با پیام وضعیت نمایش می‌دهد:

1. بررسی و نصب dependency ها
2. بررسی .NET 8 Runtime
3. پیدا کردن Release صحیح فقط برای iMonitor Ecom ERP
4. نمایش نسخه انتخاب شده
5. دانلود فایل Release با progress bar
6. استخراج فایل‌ها
7. نگهداری backup نسخه قبلی
8. ساخت و راه‌اندازی systemd service
9. بررسی سلامت سرویس

در زمان دانلود، نوار پیشرفت curl نمایش داده می‌شود تا مشخص باشد:

- چه مقدار از فایل دریافت شده است
- سرعت دانلود چقدر است
- زمان تقریبی باقی‌مانده چقدر است

در صورت خطا:

- دانلود تا ۵ بار با فاصله زمانی مجدد تلاش می‌شود.
- فایل ناقص یا خالی نصب نمی‌شود.
- خطاهای Release، Extract و Service واضح نمایش داده می‌شوند.

## امکانات Installer

- بدون Docker
- نصب خودکار dependency ها
- نصب خودکار .NET 8 Runtime در صورت نبودن
- دریافت نسخه از GitHub Release
- انتخاب امن Release مربوط به Ecom ERP
- نمایش وضعیت نصب
- دانلود قابل مشاهده با progress
- Backup نسخه قبلی
- مدیریت سرویس با systemd

پورت‌ها:

| نسخه | پورت |
|---|---|
| test | 8080 |
| master | 80 |

## نسخه‌بندی

Releaseها باید با نام مشخص iMonitor Ecom ERP منتشر شوند:

```
imonitor-ecomerp-test-vX.Y.Z
imonitor-ecomerp-master-vX.Y.Z
```

## بروزرسانی خودکار

سرور مشتری نیاز به GitHub login یا Token ندارد:

```
Ecomm Source
      |
      v
GitHub Actions
      |
      v
GitHub Release
      |
      v
Release API
      |
      v
Customer Server
```

## Windows / Windows Server

Installer مخصوص Windows نیز در همین مخزن منتشر می‌شود.

## امنیت

هیچ Secret یا اطلاعات حساس در این مخزن نگهداری نمی‌شود.
