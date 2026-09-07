# Posiran ERP — Release & Installation Guide

این راهنما فقط برای نسخه White-label **Posiran ERP / پوزایران ERP** است و از کانال‌های محصول اصلی مستقل نگه داشته می‌شود.

## Channel mapping

| Branch | Release tag | IIS site/app pool | Local port |
|---|---|---|---:|
| `posiran_test` | `posiran-erp-test-v*` | `PosiranERP-Test` | `8082` |
| `posiran_production` | `posiran-erp-production-v*` | `PosiranERP-Production` | `8083` |

Release package هر دو کانال `PosiranERP-win-x64.zip` است. `appsettings.json` عمداً داخل بسته عمومی قرار نمی‌گیرد تا تنظیمات، رمزها و دیتابیس پوزایران مستقل بمانند.

## پیش‌نیاز Windows

- Windows + IIS
- ASP.NET Core 8 Hosting Bundle
- PowerShell با Run as Administrator
- دو فایل تنظیمات مستقل در صورت نصب هر دو کانال:

```text
C:\Deploy\PosiranERP\Test\appsettings.json
C:\Deploy\PosiranERP\Production\appsettings.json
```

هیچ تنظیمات iMonitor به‌صورت خودکار کپی یا مصرف نمی‌شود.

## نصب Test — پورت 8082

```powershell
$installer = Join-Path $env:TEMP 'Install-PosiranERP-v1.0.0.ps1'
$cb = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

curl.exe -4 --http1.1 -fL `
  -H "Cache-Control: no-cache" `
  -H "Pragma: no-cache" `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.0.ps1?cb=$cb" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Channel Test
```

آدرس محلی:

```text
http://127.0.0.1:8082/
```

## نصب Production — پورت 8083

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $env:TEMP\Install-PosiranERP-v1.0.0.ps1 `
  -Channel Production
```

آدرس محلی:

```text
http://127.0.0.1:8083/
```

## نصب هر دو کانال

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $env:TEMP\Install-PosiranERP-v1.0.0.ps1 `
  -Channel Both
```

## انتشار خودکار

Push روی `posiran_test` یا `posiran_production` ابتدا روی runner سرور ERP build/test می‌شود. پس از موفقیت، SHA دقیق به این مخزن dispatch می‌شود و Workflow `publish-posiran-erp.yml` بسته Windows را از همان SHA تولید می‌کند.

- Test به شکل prerelease منتشر می‌شود.
- Production یک Release مستقل با prefix مخصوص Posiran دارد.
- Production به عنوان `latest` سراسری مخزن علامت نمی‌خورد تا Releaseهای دیگر مخزن را جابه‌جا نکند.

## White-label durability

نسخه مرجع برند در مسیر `posiran/overlay/` همین مخزن نگهداری می‌شود. Workflow `guard-posiran-branches.yml` آن را روی دو شاخه Ecomm کنترل و در صورت overwrite شدن بازاعمال می‌کند. این مکانیزم از mergeهای بعدی `test` مستقل است و حتی بعد از force-push شاخه، مرجع برند در مخزن Release از بین نمی‌رود.

> برای جلوگیری قطعی از خود force-push، Branch Protection/Ruleset GitHub نیز باید روی دو شاخه Posiran فعال شود. Guard نقش بازیابی/خودترمیمی را دارد.

## اطلاعات برند

وب‌سایت مرجع: `https://www.posiran.ir/`

شماره تلفن یا ایمیل پشتیبانی تا زمان تأیید مستقیم از منبع رسمی در محصول hard-code نمی‌شود؛ به‌خصوص هیچ شماره یا اطلاعات تماس متعلق به برند دیگری نباید در Posiran ERP نمایش داده شود.
