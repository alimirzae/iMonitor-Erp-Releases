# Posiran ERP Bootstrap Database

این پوشه منبع Seed تمیز و قابل انتشار برای نصب اولیه Posiran ERP است. Schema دیتابیس از dump محیط عملیاتی کپی نمی‌شود؛ در هر Release، schema از Migrationهای دقیق همان SHA سورس Ecomm تولید می‌شود و سپس Seedهای این پوشه به آن افزوده می‌شوند.

## بررسی dump مرجع `emp.dev.sql`

Dump مرجع ارسال‌شده در 2026-09-10 مربوط به `ecomm_dev` روی MySQL 8.4.9 بود. بررسی نشان داد:

- داده چند شرکت، چند شعبه، چند دفتر و چند کاربر در آن وجود داشت و برای Bootstrap مناسب نبود.
- Claimها و RoleAssignmentهای کاربر به شرکت/شعبه/دفترهای قدیمی اشاره می‌کردند.
- PasswordHash و SecurityStamp محیط قبلی وجود داشت؛ این مقادیر به Release منتقل نمی‌شوند.
- `ApplicationDbContext` فعلی جدول `aicache` دارد ولی dump ارسالی آن را نداشت.
- Migration فعلی Support علاوه بر `SupportTickets` جدول `SupportTicketMessages` را می‌سازد، در حالی که dump مرجع فقط `supporttickets` را داشت.
- چند جدول متعلق به `BookDbContext` مانند `calendarbases`, `calendarcustoms`, `financialyear`, `financialperiod`, `invoicetypes`, `paymenttypes`, `saletypes`, `transactiontypes`, `units`, `warehouses` داخل dump دیتابیس اصلی قرار گرفته بودند. این جدول‌ها در Bootstrap اصلی نگهداری نمی‌شوند و schema دفتر از `BookDbContext` تولید می‌شود.
- ConnectionStringهای دفتر در dump از `root` و نام‌های قدیمی دیتابیس استفاده می‌کردند؛ در Bootstrap به placeholder امن تبدیل شده‌اند و Setup Host در زمان نصب آن‌ها را با اتصال واقعی همان نصب جایگزین می‌کند.
- داده‌های عملیاتی، سفارش‌های آنلاین، cartها، ticketها، لاگ AI و اطلاعات نمونه قبلی به Seed جدید منتقل نمی‌شوند.

## داده پایه مجاز

`application-seed.sql` فقط داده پایه زیر را ایجاد می‌کند:

- CompanyId `1`: `شرکت اصلی`
- BranchId `10001`: `شعبه اصلی`
- BookId `1000001`: `دفتر اصلی`
- کاربر `علی میرزایی` با کد ملی تعیین‌شده برای Bootstrap
- دسترسی Identity و Application به‌عنوان `SuperAdmin` و `CompanyAdmin`
- Roleها/Permissionهای پایه و SystemSettings پایه

Credential قدیمی کاربر در فایل عمومی وجود ندارد. Setup Host باید رمز مدیر اولیه را از کاربر بگیرد، با ASP.NET Identity PasswordHasher هش کند و placeholderهای امنیتی را فقط روی نسخه موقت SQL قبل از Import جایگزین کند.

`book-seed.sql` فقط lookupهای عمومی و حداقلی مثل انواع فاکتور/پرداخت/فروش/تراکنش، واحدها و `انبار اصلی` را برای دفتر اولیه می‌سازد. هیچ سند مالی، فاکتور، مشتری، کالا، مانده، چک یا تراکنش عملیاتی از dump مرجع منتقل نمی‌شود.

## قرارداد Release

Release Center باید در هر انتشار دو فایل تولید کند:

- `PosiranERP-application-bootstrap.sql` = current ApplicationDb migration script + `application-seed.sql`
- `PosiranERP-book-bootstrap.sql` = current BookDb migration script + `book-seed.sql`

هر فایل باید SHA256 جداگانه داشته باشد. Installer فقط روی دیتابیس جدید/خالی Bootstrap را import می‌کند. روی دیتابیس موجود ابتدا backup اجباری گرفته می‌شود و مسیر upgrade معمول اجرا می‌شود؛ Bootstrap هرگز دیتابیس دارای داده را overwrite نمی‌کند.
