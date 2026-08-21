# iMonitor ERP Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor ERP

Repository:

https://github.com/alimirzae/iMonitor-Erp-Releases

این مخزن شامل نسخه‌های منتشر شده، فایل‌های Release، Docker deployment، اسکریپت‌های نصب و مکانیزم بروزرسانی خودکار است.

کد اصلی در مخزن‌های توسعه نگهداری می‌شود:

- https://github.com/alimirzae/Ecomm

## محصولات و کانال‌های انتشار

### iMonitor ERP

نسخه اصلی پلتفرم iMonitor ERP با runtime مستقل:

```
imonitor-erp
```

### iMonitor Ecom ERP

نسخه ERP مبتنی بر پروژه Ecomm با runtime جداگانه:

```
imonitor-ecom-erp
```

این نسخه با iMonitor ERP تداخل ندارد و دارای Release مستقل است.

## نسخه‌ها و Release

هر تغییر از مخزن Ecomm پس از build موفق به صورت Release منتشر می‌شود:

```
Ecomm/test
      |
      v
imonitor-ecom-erp-test-vX.Y.Z

Ecomm/master
      |
      v
imonitor-ecom-erp-stable-vX.Y.Z
```

هر Release شامل:

- شماره نسخه
- commit source
- Docker image
- manifest بروزرسانی
- اطلاعات کانال انتشار

است.

## نصب Ubuntu / Debian / WSL

پشتیبانی:

- Ubuntu Server
- Debian
- Ubuntu در WSL2

نصب نسخه تست Ecom ERP:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP.sh | sudo bash -s -- --channel test
```

نصب نسخه پایدار Ecom ERP:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP.sh | sudo bash -s -- --channel stable
```

امکانات:

- نصب خودکار Docker
- دریافت آخرین Release عمومی بدون GitHub login یا Token
- نصب و اجرای Container
- نگهداری دائمی Database
- اجرای Migration
- مدیریت سرویس با systemd
- بروزرسانی خودکار
- Rollback در صورت شکست نسخه جدید

## نصب Windows / Windows Server

پشتیبانی:

- Windows Server
- Windows 10/11 Pro
- Windows 11 Enterprise

نسخه Windows از PowerShell Installer استفاده می‌کند و در صورت نیاز WSL2 + Ubuntu را آماده می‌کند.

نمونه نصب:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEcomERP.ps1 -OutFile "$env:TEMP\Install-iMonitorEcomERP.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-iMonitorEcomERP.ps1" -Channel test
```

## مکانیزم بروزرسانی خودکار

سرورهای مشتری نیاز به حساب GitHub یا Token ندارند.

فرآیند:

```
Ecomm Source
      |
      v
GitHub Actions
      |
      v
Docker Build
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

Installer:

1. آخرین Release را بررسی می‌کند.
2. نسخه نصب شده را مقایسه می‌کند.
3. فقط در صورت وجود نسخه جدید Update انجام می‌دهد.
4. قبل از تغییر Backup می‌گیرد.
5. Container جدید را Health Check می‌کند.
6. در صورت خطا به نسخه قبلی برمی‌گردد.

## ساختار Repository

```
releases/
  Ecom ERP versions

server/
  docker compose
  release manifests

scripts/
  Ubuntu installers
  Windows installers
```

## امنیت

هیچ رمز عبور، کلید خصوصی یا اطلاعات حساس در این مخزن قرار نمی‌گیرد.

Installer روی سرور مقصد تنظیمات امن و Secretهای محلی ایجاد می‌کند.
