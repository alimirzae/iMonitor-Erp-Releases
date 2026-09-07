# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.13

PowerShell را با **Run as Administrator** باز کنید و وارد پوشه‌ای شوید که می‌خواهید ERP همان‌جا نصب شود. مثال:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.13.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

curl.exe -4 --http1.1 -fL `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.13.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

مسیرهای نمونه:

```text
D:\erp_ins\test\current
D:\erp_ins\production\current
D:\erp_ins\state
D:\erp_ins\installer
```

`v2.0.13` نسخه رسمی فعلی نصب Windows است.

### تغییرات v2.0.13

این نسخه برای اجرای چندباره و Recovery سخت‌گیرانه‌تر شده است:

```text
State-aware Stop/Start برای IIS Site
State-aware Stop/Start برای IIS AppPool
عدم شکست نصب وقتی Site/AppPool از قبل Stopped یا Started است
حفظ مهاجرت تنظیمات نصب قبلی از C:\ProgramData\iMonitorERP
حفظ appsettings.json و App_Data
Health Check قبل از ثبت Version state
Rollback خودکار در Activation ناموفق
انتقال Scheduled Taskها به Installer v2.0.13
حفظ InstallRoot و PackageCacheDirectory در Automatic Updater
```

### نصب خودکار پیش‌نیازها

Installer قبل از نصب/به‌روزرسانی برنامه این موارد را بررسی و در صورت نیاز ایجاد یا نصب می‌کند:

```text
IIS Web Server
IIS Management Tools
IIS WebSockets
.NET 8 ASP.NET Core Runtime
ASP.NET Core Hosting Bundle / AspNetCoreModuleV2
IIS Application Pool برای Test و Production
IIS Site و Binding برای Test و Production
مجوزهای فایل برای ApplicationPoolIdentity
Scheduled Tasks برای بررسی خودکار نسخه‌ها
```

پورت‌های پیش‌فرض:

| کانال | آدرس | مسیر نمونه |
|---|---|---|
| Production | `http://127.0.0.1:8080` | `D:\erp_ins\production\current` |
| Test | `http://127.0.0.1:8081` | `D:\erp_ins\test\current` |

### مهاجرت خودکار نصب قبلی

اگر قبلاً ERP در مسیرهای زیر نصب شده باشد:

```text
C:\ProgramData\iMonitorERP\test\current
C:\ProgramData\iMonitorERP\production\current
```

و اکنون Installer با `InstallRoot` جدید، مثلاً `D:\erp_ins` اجرا شود، در اولین فعال‌سازی هر Channel و در صورت نبود داده پایدار در مسیر جدید، این موارد از نصب قبلی منتقل می‌شوند:

```text
appsettings.json
App_Data\...
```

این کار برای حفظ Connection String، تنظیمات MySQL و داده‌های محلی انجام می‌شود. مسیر قدیمی حذف یا تغییر داده نمی‌شود.

### IIS Site موجود

اگر روی پورت موردنظر یک IIS Site موجود باشد، Installer تا جای ممکن همان Site را استفاده و AppPool/PhysicalPath را تنظیم می‌کند. اگر چند Binding متعارض روی یک پورت وجود داشته باشد، نصب متوقف می‌شود تا سایت دیگری آسیب نبیند.

### انتشار امن و Rollback

ترتیب Activation:

```text
Validate package
→ Stage new release
→ Preserve current persistent data
→ Migrate legacy persistent data when needed
→ Stop IIS Site only if running
→ Stop IIS AppPool only if running
→ Atomic swap current
→ Start AppPool only if stopped
→ Start Site only if stopped
→ Health check
→ Write installed version only after success
→ Rollback automatically if health fails
```

قبل از فعال‌سازی وجود این موارد اجباری است:

```text
Ecomm.dll
web.config
wwwroot
Reports
Reports\Invoice.mrt
Reports\Label.mrt
```

Package ناقص فعال نمی‌شود.

### تشخیص خطای IIS / HTTP 500

اگر `/health` پس از Activation سالم نشود، Installer اطلاعات تشخیصی زیر را چاپ می‌کند:

```text
IIS Site state / physical path
Application Pool state
Installed .NET runtimes
ASP.NET Core stdout/stderr captured by ANCM when available
Recent IIS / AspNetCore / .NET Runtime events from Windows Event Log
```

این خروجی برای تشخیص خطاهای `500.19`، `500.30`، Hosting Bundle، startup failure و خطاهای runtime/database استفاده می‌شود.

### دانلود و Cache

GitHub Release از طریق IPv4 مرجع تشخیص نسخه است. ZIP با SHA-256 کنترل می‌شود. اگر همان نسخه قبلاً در `PackageCacheDirectory` موجود و checksum صحیح باشد، دانلود مجدد انجام نمی‌شود.

### Scheduled Taskها / Automatic Updater

پس از نصب موفق، Installer رسمی در مسیر زیر ذخیره می‌شود:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.13.ps1
```

Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر کانال هر ۵ دقیقه مستقل بررسی می‌شود. `InstallRoot` و `PackageCacheDirectory` همان مسیر نصب اولیه حفظ می‌شوند؛ بنابراین نصب روی `D:\erp_ins` در آپدیت‌های بعدی به `C:\ProgramData\iMonitorERP` برنمی‌گردد.

### Linux / Ubuntu ERP

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash -s -- --channel both
```

---

## New_Win_Edge

Endpointهای اصلی:

```text
Health             http://127.0.0.1:17891/health
Printer discovery  http://127.0.0.1:17891/api/printers
Direct label print POST http://127.0.0.1:17891/api/labels/print
```

نصب One-Click:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-New-Win-Edge.ps1 | iex"
```
