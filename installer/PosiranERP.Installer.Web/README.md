# Posiran ERP Installer Web

این پروژه Bootstrap/Setup Host مستقل پوزایران ERP است و به‌صورت پیش‌فرض فقط روی `127.0.0.1:8099` گوش می‌کند.

## مسئولیت Installer

1. بررسی Windows / Administrator / IIS / .NET / وجود سرویس MySQL یا MariaDB.
2. انتخاب کانال `Test` یا `Production`.
3. انتخاب پورت ERP.
4. انتخاب نام پوشه نصب زیر `C:\PosiranERP`.
5. انتخاب فعال یا غیرفعال بودن Auto Update.
6. دریافت Host، Port، User و Password دیتابیس.
7. تثبیت نام دیتابیس `ApplicationDbContext`:
   - Test: `posiran_test`
   - Production: `posiran`
8. تولید تنظیمات مستقل کانال زیر `C:\Deploy\PosiranERP`.
9. دریافت Installer رسمی `Install-PosiranERP-v1.0.3.ps1` از Release Center.
10. نصب/به‌روزرسانی آخرین Release، ساخت IIS Site و Health Check.

## مسیرها و مقادیر پیش‌فرض

- Setup Host: `http://127.0.0.1:8099`
- Test: port `8082`, folder `test`, database `posiran_test`
- Production: port `8083`, folder `production`, database `posiran`
- مسیر نهایی نمونه Test: `C:\PosiranERP\test\current`
- مسیر نهایی نمونه Production: `C:\PosiranERP\production\current`

نام پوشه قابل تغییر است ولی نام دیتابیس Posiran بر اساس کانال ثابت نگه داشته می‌شود تا Test و Production به اشتباه روی یک دیتابیس اجرا نشوند.

## Auto Update

کاربر در Wizard مشخص می‌کند Auto Update فعال باشد یا نه. در حالت فعال Scheduled Task کانال ثبت می‌شود. در حالت غیرفعال Task مربوط به همان کانال حذف/ثبت نمی‌شود. نصب دستی و Repair همچنان قابل اجرا است.

## معماری نهایی پیشنهادی

Setup Host باید به‌صورت self-contained Windows executable منتشر شود تا برای اجرای خودش نیاز به نصب قبلی .NET نداشته باشد. رابط وب فقط در زمان نصب/تعمیر فعال شود. پس از پایان نصب، ERP روی پورت اختصاصی خودش اجرا می‌شود و Setup Host باید بسته شود.

نصب پیش‌نیازهای سطح سیستم مانند IIS، ASP.NET Core Hosting Bundle و MySQL باید فقط در Setup Host و با تأیید صریح کاربر انجام شود؛ این منطق نباید وارد startup اصلی ERP شود.

برای MySQL دو حالت در Wizard در نظر گرفته می‌شود:

- **Use existing MySQL**: اتصال به سرور موجود، تست دسترسی، ساخت/بررسی دیتابیس و کاربر اختصاصی.
- **Install local MySQL**: دانلود بسته رسمی، اعتبارسنجی checksum، نصب سرویس، ایجاد کاربر کم‌دسترسی مخصوص ERP و سپس ساخت دیتابیس.

Credentialهای مدیریتی MySQL نباید در لاگ ذخیره شوند و فقط برای provisioning اولیه استفاده می‌شوند. ERP باید در حالت عادی با user اختصاصی و حداقل سطح دسترسی اجرا شود.

## Bootstrap دیتابیس پیشنهادی

برای نصب صفر تا صد، مسیر مطلوب این است که Release علاوه بر فایل برنامه دو Bootstrap دیتابیس versioned داشته باشد:

- `bootstrap/application.sql` برای دیتابیس اصلی `ApplicationDbContext`.
- `bootstrap/book-initial.sql` برای ایجاد دفتر/Book اولیه و حداقل داده لازم برای اولین اجرا.

قواعد Import:

1. ابتدا اتصال MySQL و دسترسی CREATE DATABASE بررسی شود.
2. اگر دیتابیس مقصد وجود ندارد یا کاملاً خالی است، Bootstrap همان Release import شود.
3. روی دیتابیس دارای داده هیچ Import مخربی انجام نشود.
4. پس از Bootstrap، Migration فقط برای ارتقای اختلاف نسخه Release اجرا شود؛ نصب اولیه نباید وابسته به اجرای زنجیره طولانی Migrationهای تاریخی باشد.
5. نسخه Bootstrap و schema version در جدول/metadata اختصاصی ثبت شود.
6. پس از Import، ERP بالا آورده شود و `/health` بررسی گردد.
7. در صورت شکست Import یا Health Check، نصب ناقص علامت‌گذاری شود و نسخه قبلی سالم دست‌نخورده بماند.

فایل‌های SQL واقعی باید از دیتابیس تمیز و تاییدشده همان نسخه Release تولید شوند؛ نباید dump یک محیط عملیاتی با داده مشتری، credential یا اطلاعات شخصی وارد Release شود.

## مرزبندی با خود ERP

داخل Ecomm/Posiran فقط Wizard سطح برنامه باقی می‌ماند: ایجاد مدیر اولیه، شرکت، دفتر، تنظیمات کسب‌وکار و داده‌های شروع. نصب Windows/IIS/MySQL، دانلود Release، Bootstrap دیتابیس، rollback و update در Setup Host مستقل انجام می‌شود.
