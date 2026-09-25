# iMonitor Release Center

مرکز عمومی انتشار، نصب و ارتقای محصولات **iMonitor ERP / Ecomm ERP / Posiran ERP**.

> **Windows:** همه عملیات نصب و ارتقا باید از Windows PowerShell با **Run as Administrator** انجام شوند.
>
> پیش‌فرض این راهنما این است که IIS و MySQL/MariaDB روی سیستم موجود هستند.

---

## استاندارد نصب Windows: Unified ERP Setup

مسیر استاندارد نصب و ارتقای ERPها یک **Setup Host وب واحد** است که فقط روی سیستم محلی گوش می‌کند:

```text
http://127.0.0.1:8099/
```

این Setup چهار انتخاب مستقل دارد:

- Posiran Test
- Posiran Production
- iMonitor Test
- iMonitor Production

کاربر می‌تواند یک، چند یا هر چهار مورد را هم‌زمان انتخاب کند. برای هر مورد، Setup اطلاعات دیتابیس، پورت، مسیر نصب و تنظیمات لازم را تولید و سپس آخرین Release همان کانال را نصب می‌کند.

### نگاشت استاندارد کانال‌ها

```text
Posiran Test
  Source branch: posiran_test
  Release: posiran-erp-test-v*
  Port: 8082
  Database: posiran_test
  Root: C:\PosiranERP\test\current

Posiran Production
  Source branch: posiran_production
  Release: posiran-erp-production-v*
  Port: 8083
  Database: posiran
  Root: C:\PosiranERP\production\current

iMonitor Test
  Source branch: test
  Release: imonitor-ecomerp-test-v*
  Port: 8081
  Database: ecomm_dev
  Root: C:\ecomm\test\current

iMonitor Production
  Source branch: master
  Release: imonitor-ecomerp-master-v*
  Port: 8080
  Database: ecomm
  Root: C:\ecomm\production\current
```

### اطلاعاتی که Setup دریافت می‌کند

- انتخاب یک یا چند کانال از چهار کانال بالا
- MySQL Server
- MySQL Port
- Username
- Password
- نسخه MySQL
- پورت ERP هر کانال
- نام پوشه نصب
- فعال/غیرفعال بودن Auto Update در کانال‌هایی که پشتیبانی می‌کنند

Setup پس از ذخیره Config:

1. Release صحیح همان کانال را پیدا می‌کند.
2. package و SHA256 را دریافت می‌کند.
3. cache محلی را در صورت معتبر بودن استفاده می‌کند.
4. فایل‌ها را در stage استخراج می‌کند.
5. Config محلی و credentialها را خارج از package عمومی حفظ می‌کند.
6. IIS Site و AppPool را ایجاد/Repair می‌کند.
7. ACL پوشه نصب را برای IIS تنظیم می‌کند.
8. Migration/Startup configuration را فعال می‌کند.
9. ERP را اجرا می‌کند.
10. `/health` را بررسی می‌کند.
11. در صورت شکست، rollback انجام می‌دهد.

---

## اجرای Setup

### Bootstrap عمومی

PowerShell را با دسترسی Administrator اجرا کنید. Bootstrap باید آخرین Setup Host منتشرشده را دانلود، checksum را بررسی و UI محلی را باز کند.

### Posiran bootstrap

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$p="$env:TEMP\Start-PosiranERP-Setup.ps1"
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Start-PosiranERP-Setup.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

### iMonitor bootstrap

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$p="$env:TEMP\Start-iMonitorERP-Setup.ps1"
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Start-iMonitorERP-Setup.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

هدف نهایی این است که هر دو bootstrap به **همان Unified ERP Setup Host** برسند؛ تفاوت bootstrap فقط برای سازگاری با لینک‌های موجود است.

---


## ERP Deployment Manager — سرویس دائمی 8099

Unified Setup از این پس فقط یک نصب‌کننده موقت نیست؛ معماری هدف آن **ERP Deployment Manager** دائمی روی سرور است.

- فقط روی `http://127.0.0.1:8099` گوش می‌کند و نباید روی LAN/WAN bind شود.
- به‌صورت Windows Service با شروع خودکار پس از Boot اجرا می‌شود.
- چهار کانال `Posiran Test`، `Posiran Production`، `iMonitor Test` و `iMonitor Production` را مستقل مدیریت می‌کند.
- برای هر کانال Root Path مطلق (همراه Drive)، Port، Database و Auto Update مستقل ذخیره می‌شود.
- اگر Root Path وجود نداشته باشد Manager آن را ایجاد می‌کند.
- شکست نصب/Health یک کانال نباید اجرای عملیات کانال‌های دیگر را متوقف کند.
- تاریخچه Releaseها برای هر کانال شامل Tag، SHA256، زمان نصب، نتیجه نصب و نتیجه Health در registry محلی JSON ثبت می‌شود.
- نسخه فقط پس از موفقیت نصب و Health Check به‌عنوان `Healthy` علامت می‌خورد.
- نسخه خراب با `Failed` ثبت می‌شود و برای Auto Update انتخاب نمی‌شود.
- قبل از Upgrade از دیتابیس‌ها و وضعیت نسخه فعلی backup گرفته می‌شود.
- Manager باید امکان نصب یک Release مشخص، Upgrade، Downgrade و Rollback به آخرین نسخه سالم یا نسخه سالم انتخابی را بدهد.
- Rollback نسخه برنامه و backup متناظر دیتابیس را هماهنگ بازیابی می‌کند.
- Auto Update برای هر کانال مستقل است؛ Manager Release جدید را کشف و validate می‌کند، backup می‌گیرد، نصب می‌کند، Health را می‌سنجد و در صورت شکست rollback می‌کند.
- Packageهای دانلودشده با SHA256 نگهداری می‌شوند تا نسخه سالم قبلی بدون دانلود مجدد قابل بازیابی باشد.
- UI روی 8099 باید وضعیت Installed / Latest / Healthy / Failed / Update Available / Auto Update و تاریخچه نسخه‌ها را نمایش دهد.
- هیچ خطای یک نصب نباید باعث توقف Windows Service یا از دسترس خارج شدن UI مدیریت 8099 شود.

State مدیریتی باید خارج از پوشه `current` نگهداری شود تا با Upgrade برنامه ERP از بین نرود. Credentialهای دیتابیس نیز نباید در Release عمومی قرار گیرند.


## معماری استاندارد Installer

منطق نصب باید تا حد ممکن مشترک باشد. تفاوت محصول نباید باعث دو مسیر نصب مستقل شود.

### لایه مشترک

- Web Setup Host روی 8099
- انتخاب کانال‌ها
- دریافت credentialهای MySQL
- تولید Config
- Release discovery
- checksum
- package cache
- staged deployment
- IIS Site/AppPool
- ACL repair
- health check
- rollback
- backup/restore
- start/stop/restart

### تنظیمات متغیر بر اساس کانال

- Product/Brand
- Source branch
- Release tag prefix
- Port
- Database name
- Install root
- Config root
- IIS site/app pool name
- Auto Update policy

هیچ credential دیتابیس، password، token یا داده عملیاتی مشتری نباید در Release عمومی ذخیره شود.

---

## Release Center

### Posiran

```text
posiran_test       -> posiran-erp-test-v*
posiran_production -> posiran-erp-production-v*
```

### iMonitor

```text
test   -> imonitor-ecomerp-test-v*
master -> imonitor-ecomerp-master-v*
```

Releaseها باید فقط بعد از Build/Verify موفق منتشر شوند.

---

## Configهای پایدار

### Posiran

```text
C:\Deploy\PosiranERP\Test\appsettings.json
C:\Deploy\PosiranERP\Production\appsettings.json
```

### iMonitor

```text
C:\ecomm\config\Test\appsettings.json
C:\ecomm\config\Production\appsettings.json
```

در Upgrade، Config و credentialهای محلی باید حفظ شوند.

---

## Package Cache

بسته‌های تأییدشده می‌توانند برای جلوگیری از دانلود مجدد نگهداری شوند.

نمونه:

```text
C:\PosiranERP\packages\<release-tag>\
C:\ecomm\packages\<release-tag>\
```

فایل cache فقط در صورت تطابق SHA256 معتبر است.

---

## IIS و ACL

Installer موظف است دسترسی NTFS لازم را برای پوشه deploy اعمال کند تا خطاهای `401.3 / 0x80070005` رخ ندهند.

حداقل دسترسی:

```text
IIS_IUSRS            -> Read & Execute
IIS AppPool\<pool>   -> Read & Execute
```

ACL باید روی پوشه current و زیرشاخه‌های آن inheritance داشته باشد.

---

## Database / Book Scope

ERPهای چنددفتره نباید قبل از بازیابی دفتر فعال به BookDbContext دسترسی بزنند.

صفحات و سرویس‌ها باید قبل از query، BookScope/UserState را به‌صورت async restore کنند و فقط با `bookId > 0` DbContext بسازند.

---

## Upgrade Policy

- Config محلی حفظ شود.
- credentialها حفظ شوند.
- package جدید ابتدا در stage آماده شود.
- نسخه قبلی تا پایان health-check سالم نگه داشته شود.
- در صورت شکست health-check rollback انجام شود.
- Production نباید بدون Verify موفق Release شود.

---

## مسیرهای فنی مستقیم

اسکریپت‌های زیر برای Repair، CI یا استفاده فنی نگه داشته می‌شوند، اما مسیر پیشنهادی کاربر عادی **Unified Web Setup** است:

```text
scripts/Install-PosiranERP-v1.0.5.ps1
scripts/Install-iMonitorERP-v2.1.5.ps1
```

---

## Linux / Ubuntu ERP

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash -s -- --channel both
```

---

## New Windows Edge

```text
Health             http://127.0.0.1:17891/health
Printer discovery  http://127.0.0.1:17891/api/printers
Direct label print POST http://127.0.0.1:17891/api/labels/print
```

---

## قواعد انتشار

- Test و Production دیتابیس، پورت، مسیر و IIS مستقل دارند.
- Posiran به‌صورت white-label مستقل منتشر می‌شود.
- iMonitor و Posiran باید تا حد ممکن از یک Installer Engine استفاده کنند.
- Release package نباید `appsettings.json` عملیاتی یا credential داشته باشد.
- Bootstrap DB فقط از schema/seed تمیز و versioned استفاده کند.
- dump دیتابیس مشتری نباید وارد Release شود.
- Installer باید با Windows PowerShell 5.1 سازگار باشد.
- دانلود باید fallback مناسب، checksum و cache معتبر داشته باشد.
- Health check و rollback بخش اجباری deployment هستند.

