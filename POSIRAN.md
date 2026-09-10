# Posiran ERP — Release & Installation Guide

این راهنما فقط برای نسخه White-label **Posiran ERP / پوزایران ERP** است. نام، لوگو، تم، شماره پشتیبانی، IIS، دیتابیس و کانال انتشار آن مستقل نگه داشته می‌شود.

## اطلاعات رسمی برند

```text
Product      : Posiran ERP / پوزایران ERP
Website      : https://www.posiran.ir/
Support phone: 0922-962-7005
```

شماره بالا از وب‌سایت رسمی پوزایران گرفته شده است. هیچ اطلاعات تماس متعلق به محصول یا برند دیگری در رابط Posiran ERP استفاده نمی‌شود.

## Channel mapping

| Branch | Release tag | IIS site/app pool | Local port | ApplicationDbContext database |
|---|---|---|---:|---|
| `posiran_test` | `posiran-erp-test-v*` | `PosiranERP-Test` | `8082` | `posiran_test` |
| `posiran_production` | `posiran-erp-production-v*` | `PosiranERP-Production` | `8083` | `posiran` |

Release package هر دو کانال `PosiranERP-win-x64.zip` است. `appsettings.json` عمداً داخل بسته عمومی قرار نمی‌گیرد تا رمزها و تنظیمات محلی در Release منتشر نشوند.

## فایل‌های تنظیمات محلی

```text
C:\Deploy\PosiranERP\Test\appsettings.json
C:\Deploy\PosiranERP\Production\appsettings.json
```

Workflow استقرار و Installer v1.0.2 قبل از Start برنامه، `Database.Type=MySql` را enforce کرده و فقط نام دیتابیس ConnectionString را مطابق کانال نرمال می‌کنند. Host، Port، User و Password موجود حفظ می‌شوند.

## نصب Test — پورت 8082

PowerShell را با **Run as Administrator** باز کنید:

```powershell
$installer = Join-Path $env:TEMP 'Install-PosiranERP-v1.0.2.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.2.ps1?cb=$cb" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Test
```

```text
http://127.0.0.1:8082/
Database: posiran_test
```

## نصب Production — پورت 8083

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $env:TEMP\Install-PosiranERP-v1.0.2.ps1 `
  -Channel Production
```

```text
http://127.0.0.1:8083/
Database: posiran
```

## نصب هر دو کانال

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $env:TEMP\Install-PosiranERP-v1.0.2.ps1 `
  -Channel Both
```

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

> جلوگیری پیشگیرانه از خود force-push فقط با GitHub Branch Protection/Ruleset ممکن است. Guard مکانیزم بازیابی و خودترمیمی است، نه جایگزین Branch Protection.
