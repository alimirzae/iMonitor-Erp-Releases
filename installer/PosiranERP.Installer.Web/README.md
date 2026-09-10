# Posiran ERP Installer Web

این پروژه Bootstrap/Setup Host مستقل پوزایران ERP است و به‌صورت پیش‌فرض فقط روی `127.0.0.1:8099` گوش می‌کند.

## مسئولیت MVP

1. بررسی Windows / Administrator / IIS / .NET / وجود سرویس MySQL یا MariaDB.
2. انتخاب کانال Test یا Production.
3. دریافت Host، Port، User و Password دیتابیس و Port برنامه.
4. تثبیت نام دیتابیس `ApplicationDbContext`:
   - Test: `posiran_test`
   - Production: `posiran`
5. تولید تنظیمات مستقل کانال زیر `C:\Deploy\PosiranERP`.
6. دریافت Installer رسمی `Install-PosiranERP-v1.0.2.ps1` از Release Center.
7. نصب/به‌روزرسانی آخرین Release، ساخت IIS Site و Health Check.

## معماری نهایی پیشنهادی

Setup Host باید به‌صورت self-contained Windows executable منتشر شود تا برای اجرای خودش نیاز به نصب قبلی .NET نداشته باشد. رابط وب فقط در زمان نصب/تعمیر فعال شود. پس از پایان نصب، ERP روی پورت اختصاصی خودش اجرا می‌شود و Setup Host باید بسته شود.

نصب پیش‌نیازهای سطح سیستم مانند IIS، ASP.NET Core Hosting Bundle و MySQL باید فقط در Setup Host و با تأیید صریح کاربر انجام شود؛ این منطق نباید وارد startup اصلی ERP شود.

برای MySQL دو حالت در Wizard در نظر گرفته می‌شود:

- **Use existing MySQL**: اتصال به سرور موجود، تست دسترسی، ساخت/بررسی دیتابیس و کاربر اختصاصی.
- **Install local MySQL**: دانلود بسته رسمی، اعتبارسنجی checksum، نصب سرویس، ایجاد کاربر کم‌دسترسی مخصوص ERP و سپس ساخت دیتابیس.

Credentialهای مدیریتی MySQL نباید در لاگ ذخیره شوند و فقط برای provisioning اولیه استفاده می‌شوند. ERP باید در حالت عادی با user اختصاصی و حداقل سطح دسترسی اجرا شود.

## مرزبندی با خود ERP

داخل Ecomm/Posiran فقط Wizard سطح برنامه باقی می‌ماند: ایجاد مدیر اولیه، شرکت، دفتر، تنظیمات کسب‌وکار و داده‌های شروع. نصب Windows/IIS/MySQL، دانلود Release، rollback و update در Setup Host مستقل انجام می‌شود.
