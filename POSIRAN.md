# Posiran ERP — Release & Installation Guide

این راهنما فقط برای نسخه White-label **Posiran ERP / پوزایران ERP** است. نام، لوگو، تم، شماره پشتیبانی، IIS، دیتابیس و کانال انتشار آن مستقل نگه داشته می‌شود.

## اطلاعات رسمی برند

```text
Product      : Posiran ERP / پوزایران ERP
Website      : https://www.posiran.ir/
Support phone: 0922-962-7005
```

## Channel mapping

| Branch | Release tag | IIS site/app pool | Local port | ApplicationDbContext database | Default install folder |
|---|---|---|---:|---|---|
| `posiran_test` | `posiran-erp-test-v*` | `PosiranERP-Test` | `8082` | `posiran_test` | `C:\PosiranERP\test\current` |
| `posiran_production` | `posiran-erp-production-v*` | `PosiranERP-Production` | `8083` | `posiran` | `C:\PosiranERP\production\current` |

Release package هر دو کانال `PosiranERP-win-x64.zip` است. `appsettings.json` عمداً داخل بسته عمومی قرار نمی‌گیرد تا رمزها و تنظیمات محلی در Release منتشر نشوند.

## Setup Host پیشنهادی

روش پیشنهادی نصب، اجرای بسته self-contained **Posiran ERP Setup** است. Setup Host به‌صورت محلی روی آدرس زیر اجرا می‌شود:

```text
http://127.0.0.1:8099/
```

Wizard موارد زیر را از کاربر می‌گیرد:

- کانال `Test` یا `Production`
- پورت ERP
- نام پوشه نصب
- فعال یا غیرفعال بودن Auto Update
- Host/Port/User/Password مربوط به MySQL

نام دیتابیس در نسخه Posiran بر اساس کانال ثابت است:

```text
Test       -> posiran_test
Production -> posiran
```

## فایل‌های تنظیمات محلی

```text
C:\Deploy\PosiranERP\Test\appsettings.json
C:\Deploy\PosiranERP\Production\appsettings.json
```

Workflow استقرار و Installer v1.0.3 قبل از Start برنامه، `Database.Type=MySql` را enforce کرده و فقط نام دیتابیس ConnectionString را مطابق کانال نرمال می‌کنند. Host، Port، User و Password موجود حفظ می‌شوند.

## نصب Test — پیش‌فرض 8082

PowerShell را با **Run as Administrator** باز کنید:

```powershell
$installer = Join-Path $env:TEMP 'Install-PosiranERP-v1.0.3.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.3.ps1?cb=$cb" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Test `
  -TestPort 8082 `
  -TestFolderName test
```

برای غیرفعال کردن به‌روزرسانی خودکار، پارامتر زیر را اضافه کنید:

```powershell
-DisableAutoUpdate
```

## نصب Production — پیش‌فرض 8083

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $env:TEMP\Install-PosiranERP-v1.0.3.ps1 `
  -Channel Production `
  -ProductionPort 8083 `
  -ProductionFolderName production
```

## نصب هر دو کانال

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $env:TEMP\Install-PosiranERP-v1.0.3.ps1 `
  -Channel Both `
  -TestFolderName test `
  -ProductionFolderName production
```

## Bootstrap دیتابیس در نصب جدید

هدف معماری Installer این است که در نصب کاملاً جدید، به‌جای وابستگی به اجرای تمام Migrationهای تاریخی، فایل‌های Bootstrap versioned مربوط به همان Release را وارد کند:

```text
bootstrap/application.sql
bootstrap/book-initial.sql
```

قواعد موردنظر:

1. فقط اگر دیتابیس مقصد وجود ندارد یا خالی است Bootstrap انجام شود.
2. هیچ دیتابیس دارای داده overwrite نشود.
3. `application.sql` دیتابیس اصلی را آماده کند.
4. `book-initial.sql` یک دفتر اولیه و داده حداقلی موردنیاز برای اولین اجرا را ایجاد کند.
5. بعد از Bootstrap، Migration فقط برای اختلاف schema همان Release/نسخه اجرا شود.
6. در پایان ERP اجرا و `/health` بررسی شود.
7. فایل SQL باید از دیتابیس تمیز بدون credential یا داده مشتری تولید و همراه همان Release version شود.

تا زمانی که فایل SQL تاییدشده تولید نشده باشد، Installer از مسیر migration فعلی استفاده می‌کند و نباید یک dump نامعتبر یا عملیاتی را وارد کند.

## انتشار خودکار

Push روی `posiran_test` یا `posiran_production` ابتدا روی runner سرور ERP Build/Test می‌شود. فقط SHA‌ای که این مرحله را با موفقیت رد کند با event اختصاصی `posiran-erp-release` به Release Center ارسال می‌شود.

Workflow `publish-posiran-erp.yml` سپس دقیقاً همان SHA را Checkout، White-label canonical را اعمال و بسته Windows را تولید می‌کند:

```text
posiran_test       -> posiran-erp-test-v1.0.*       -> prerelease
posiran_production -> posiran-erp-production-v1.0.* -> production release
```

Production به عنوان `latest` سراسری مخزن علامت نمی‌خورد تا Releaseهای سایر محصولات این مخزن تحت تأثیر قرار نگیرند.

## White-label durability

منبع حقیقت White-label داخل شاخه‌های Posiran نیست؛ نسخه مرجع در این مخزن و مسیر زیر نگهداری می‌شود:

```text
posiran/overlay/
```

`guard-posiran-branches.yml` به‌صورت دوره‌ای هر دو شاخه را بررسی می‌کند. `Apply-PosiranWhiteLabel.ps1` در صورت overwrite شدن، موارد زیر را دوباره اعمال می‌کند:

- لوگو و favicon پوزایران
- نام `Posiran ERP / پوزایران ERP`
- تم اختصاصی پوزایران
- وب‌سایت و شماره پشتیبانی رسمی
- App shell و MainLayout
- Workflow انتشار اختصاصی
- Workflow IIS اختصاصی
- قرارداد White-label

بنابراین mergeهای بعدی از `test` منبع کد را به‌روز می‌کنند، اما منبع حقیقت برند همچنان Overlay مستقل است. حتی اگر شاخه با force-push overwrite شود، Guard می‌تواند قرارداد White-label را از مخزن Release دوباره اعمال کند.
