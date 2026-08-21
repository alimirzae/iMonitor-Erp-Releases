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

آخرین Installer نسخه‌دار استفاده شود:

### Ecom ERP Installer v1.0.1

نسخه تست:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.1.sh | sudo bash -s -- --channel test
```

نسخه پایدار:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP-v1.0.1.sh | sudo bash -s -- --channel master
```

امکانات Installer:

- بدون Docker
- نصب خودکار dependency ها
- نصب خودکار .NET 8 Runtime در صورت نبودن
- دریافت نسخه از GitHub Release
- مقایسه نسخه نصب شده با Release جدید
- Update فقط در صورت وجود نسخه جدید
- Backup نسخه قبلی
- Rollback در صورت خطای اجرا
- مدیریت سرویس با systemd

پورت‌ها:

| نسخه | پورت |
|---|---|
| test | 8080 |
| master | 80 |

## نسخه‌بندی

هر Release شامل شماره نسخه و اطلاعات commit منبع است:

```
Ecomm/test
    -> imonitor-ecom-erp-test-vX.Y.Z

Ecomm/master
    -> imonitor-ecom-erp-master-vX.Y.Z
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

Installer مخصوص Windows نیز در همین مخزن منتشر می‌شود و dependency های لازم را به صورت خودکار آماده می‌کند.

## امنیت

هیچ Secret یا اطلاعات حساس در این مخزن نگهداری نمی‌شود.
