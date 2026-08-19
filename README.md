# iMonitor Release Center

این مخزن **کانال عمومی انتشار خانواده iMonitor** است. سورس اصلی ERP، iMonitor Edge و iMonitor Track در مخزن‌های توسعه نگهداری می‌شود و این مخزن فقط شامل installerها، manifestها، checksumها و GitHub Releaseهای قابل نصب است.

## Current releases

| Product | Channel | Current published version | Manifest |
|---|---|---:|---|
| Windows Edge | stable | **0.2.0** | `manifests/edge-stable.json` |
| Windows Edge | preview | **2026.08.15.120** | `manifests/edge-preview.json` |
| Android Edge | preview | **0.3.2 (versionCode 6)** | `manifests/android-edge-preview.json` |

> این جدول نسخه‌های **واقعاً منتشرشده** را نشان می‌دهد، نه نسخه سورس. در سورس Ecomm، Android Edge اکنون `0.4.1 / versionCode 9` است اما تا زمان انتشار APK امضاشده و به‌روزرسانی manifest، نسخه عمومی همچنان `0.3.2` محسوب می‌شود.

## iMonitor Track Android

iMonitor Track اپ نیتیو Android برای Guard Vision، Security Camera، ثبت موقعیت، QR/BLE و عملیات میدانی iMonitor است. سورس آن در مخزن `alimirzae/iTrack` و پوشه `AndroidEdge/` نگهداری می‌شود.

کانال‌های انتشار:

- `android-track-dev` — build توسعه؛ package برابر `ir.imonitor.track.debug` و قابل نصب کنار نسخه اصلی.
- `android-track-preview` — تست میدانی با signing key دائمی.
- `android-track-stable` — نسخه پایدار سازمانی با همان signing key دائمی.

دانلود ثابت آخرین نسخه توسعه بعد از اولین انتشار موفق:

`https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/android-track-dev-latest/iMonitor-Track-Android-dev.apk`

Manifestها:

- `manifests/android-track-dev.json`
- `manifests/android-track-preview.json`
- `manifests/android-track-stable.json`

پس از موفق شدن CI اصلی iTrack، workflow انتشار APK توسعه را روی self-hosted runner می‌سازد، SHA-256 را محاسبه می‌کند، یک Release آرشیوی و یک Release ثابت `android-track-dev-latest` می‌سازد و manifest را به‌روزرسانی می‌کند. Preview/Stable بعد از تنظیم signing key دائمی فعال می‌شوند.

## ساختار نصب ویندوز

نصب تعاملی به‌صورت پیش‌فرض پیشنهاد می‌دهد همه اجزای محلی داخل `C:\ERP` قرار بگیرند. اگر کاربر این مسیر را نخواهد، Installer مسیر کامل دیگری مانند `D:\ERP` را می‌پرسد. پیام‌ها، سؤال‌ها و خطاهای تمام اسکریپت‌های PowerShell انگلیسی هستند تا در کنسول Windows به‌صورت چپ‌به‌راست و خوانا نمایش داده شوند.

ساختار استاندارد:

```text
C:\ERP\
  Edge\
  Production\
  Preview\
  Config\
  Backup\
  Logs\
```

در اجرای غیرتعاملی می‌توان مسیر را صریحاً با `-Root` داد. Updaterها همان مسیر انتخاب‌شده در نصب اولیه را حفظ می‌کنند.

## کانال‌ها

- `preview` ← خروجی branch `test`
- `stable` ← خروجی branch `master`
- `edge-preview` ← آخرین iMonitor Edge ساخته‌شده از `test`
- `edge-stable` ← نسخه پایدار Edge
- `android-edge-preview` ← نسخه آزمایشی Android Edge برای ERP
- `android-track-dev` ← نسخه توسعه iMonitor Track
- `android-track-preview` ← نسخه تست میدانی Track
- `android-track-stable` ← نسخه پایدار Track

## نصب iMonitor Android Edge — Preview

Android Edge برای بارکدخوان Native شناور، Voice/STT، مرورگر داخلی ERP، اطلاعات دستگاه و سرویس‌های محلی روی `127.0.0.1:9000` استفاده می‌شود.

**[دانلود مستقیم آخرین Android Edge Preview](https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/android-edge-preview-latest/iMonitor-Android-Edge-preview.apk)**

این URL **ثابت** است و با انتشار نسخه‌های بعدی تغییر نمی‌کند. GitHub Actions فایل APK این Release را جایگزین و `manifests/android-edge-preview.json` را با `versionName`، `versionCode`، URL و SHA-256 واقعی همان build به‌روزرسانی می‌کند.

Android Edge از نسخه 0.3.1 به بعد manifest رسمی را دوره‌ای بررسی می‌کند. اگر نسخه جدیدتری وجود داشته باشد، به کاربر پیشنهاد ارتقا می‌دهد، APK را دانلود می‌کند، SHA-256 را کنترل می‌کند و سپس Package Installer رسمی Android را برای تأیید نصب باز می‌کند. صفحه «تنظیمات شعبه و Edge» در ERP نیز همین manifest را با نسخه نصب‌شده روی دستگاه مقایسه می‌کند و در صورت قدیمی بودن نسخه هشدار می‌دهد.

> نصب کاملاً silent در Android عمومی مجاز نیست و تأیید Package Installer لازم است، مگر دستگاه بعداً در حالت سازمانی Device Owner/MDM مدیریت شود. برای update-in-place قابل اتکا، همه APKهای یک کانال باید با signing key ثابت امضا شوند؛ signing key هرگز داخل repository قرار نمی‌گیرد.

## نصب سریع iMonitor Edge روی Windows

PowerShell را با **Run as Administrator** باز کنید و اجرا کنید:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEdge.ps1 | iex
```

Installer ابتدا پیشنهاد می‌کند `C:\ERP` را بسازد. اگر پاسخ `n` بدهید مسیر دلخواه را می‌پرسد.

پیش‌فرض‌ها:

- Windows Service: `iMonitorEdge`
- نصب Edge: `C:\ERP\Edge`
- تنظیمات مشترک: `C:\ERP\Config`
- Backup: `C:\ERP\Backup\Edge`
- Logs: `C:\ERP\Logs\Edge`
- API/Swagger: `http://127.0.0.1:9000`
- LAN access: فعال، فقط `Private Network / LocalSubnet`
- POS: غیرفعال تا زمانی که درایور/SDK مربوطه تنظیم شود
- TCP/RAW receipt printing (معمولاً port `9100`): فعال

برای نصب غیرتعاملی در مسیر مشخص:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEdge.ps1 -OutFile .\Install-iMonitorEdge.ps1
.\Install-iMonitorEdge.ps1 -Channel preview -Root 'C:\ERP' -Port 9000 -AllowLan $true -NonInteractive
```

## نصب/ارتقای ERP محلی شعبه

نسخه Production محلی از `stable` و نسخه Preview محلی از `preview` دریافت می‌شود. Installerهای ERP بعد از انتشار اولین artifact در همین مخزن فعال می‌شوند:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorBranch.ps1 -OutFile .\Install-iMonitorBranch.ps1
.\Install-iMonitorBranch.ps1 -InstallProduction -InstallPreview
```

در اجرای تعاملی مسیر نصب پرسیده می‌شود. ساختار پیش‌فرض ERP محلی:

- Production: `C:\ERP\Production` → `http://localhost:8080`
- Preview/Test: `C:\ERP\Preview` → `http://localhost:8081`
- Config: `C:\ERP\Config`
- Backup: `C:\ERP\Backup`
- Logs: `C:\ERP\Logs`

## Auto Update

Windows installer یک Scheduled Task سبک ایجاد می‌کند که manifest عمومی را بررسی می‌کند. فقط اگر SHA/version تغییر کرده باشد نسخه جدید دانلود، checksum کنترل، سرویس متوقف، backup گرفته، upgrade انجام و health-check اجرا می‌شود. مسیر ریشه‌ای که در نصب اولیه انتخاب شده حفظ می‌شود. در صورت شکست، نسخه قبلی حفظ/قابل rollback است.

Android Edge و در آینده iMonitor Track نیز manifest مخصوص خود را بررسی می‌کنند و در صورت وجود نسخه جدید، جریان امن دانلود، کنترل SHA-256 و درخواست نصب Android را اجرا می‌کنند.

## امنیت

این repository **هیچ** connection string، رمز دیتابیس، Branch Token، PAT، SDK بانکی، signing key یا فایل تنظیمات مشتری را نگهداری نمی‌کند. تنظیمات شعبه هنگام upgrade حفظ می‌شوند. فایل‌های انتشار با SHA-256 بررسی می‌شوند.

## Manifestها

- `manifests/edge-preview.json`
- `manifests/edge-stable.json`
- `manifests/erp-preview.json`
- `manifests/erp-stable.json`
- `manifests/android-edge-preview.json`
- `manifests/android-track-dev.json`
- `manifests/android-track-preview.json`
- `manifests/android-track-stable.json`
