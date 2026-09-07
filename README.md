# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor برای Windows و Linux.

## iMonitor Platform

نصب Ubuntu / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorPlatform-v1.0.3.sh | sudo bash
```

---

## iMonitor ERP / Ecomm ERP

### Windows x64 — Installer رسمی v2.0.12

PowerShell را با **Run as Administrator** باز کنید و وارد پوشه‌ای شوید که می‌خواهید ERP همان‌جا نصب شود. مثال:

```powershell
Set-Location D:\erp_ins

$installer = Join-Path $env:TEMP 'Install-iMonitorERP-v2.0.12.ps1'
$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

curl.exe -4 --http1.1 -fL `
  "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.12.ps1?cb=$cacheBust" `
  -o $installer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

در این حالت فایل‌ها در مسیرهای زیر قرار می‌گیرند:

```text
D:\erp_ins\test\current
D:\erp_ins\production\current
D:\erp_ins\state
D:\erp_ins\installer
```

`v2.0.12` نسخه رسمی فعلی نصب Windows است.

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

| کانال | آدرس | مسیر برنامه در مثال D:\erp_ins |
|---|---|---|
| Production | `http://127.0.0.1:8080` | `D:\erp_ins\production\current` |
| Test | `http://127.0.0.1:8081` | `D:\erp_ins\test\current` |

### مهاجرت خودکار نصب قبلی از C:\ProgramData

اگر قبلاً ERP در مسیر قدیمی نصب شده باشد:

```text
C:\ProgramData\iMonitorERP\test\current
C:\ProgramData\iMonitorERP\production\current
```

و اکنون Installer با `InstallRoot` جدید، مثلاً `D:\erp_ins` اجرا شود، در اولین فعال‌سازی هر Channel در صورتی که مسیر جدید هنوز تنظیمات پایدار نداشته باشد، Installer این موارد را از نصب قبلی منتقل می‌کند:

```text
appsettings.json
App_Data\...
```

هدف این است که Connection String، تنظیمات MySQL و سایر داده‌های محلی نصب قبلی از بین نرود و برنامه با تنظیمات پیش‌فرض Package جایگزین نشود.

قواعد مهاجرت:

1. اگر `current` مسیر جدید دارای `appsettings.json` یا `App_Data` باشد، همان اطلاعات جدید در اولویت است.
2. فقط وقتی مسیر جدید فاقد داده پایدار باشد، Legacy path بررسی می‌شود.
3. نصب قبلی در `C:\ProgramData\iMonitorERP` حذف یا تغییر داده نمی‌شود.
4. پس از Health Check موفق، نسخه جدید فعال می‌شود و از آن پس updater روی `InstallRoot` جدید کار می‌کند.
5. در صورت شکست Health Check، Rollback انجام می‌شود و نسخه قبلی مسیر جدید برگردانده می‌شود.

### IIS Site موجود

اگر روی پورت موردنظر یک IIS Site موجود باشد، Installer تا جای ممکن همان Site را برای کانال مربوطه استفاده و AppPool/PhysicalPath آن را اصلاح می‌کند. در صورت وجود چند Binding متعارض روی یک پورت، نصب متوقف می‌شود تا از خراب شدن سایت‌های دیگر جلوگیری شود.

### انتشار امن و Rollback

ترتیب Activation:

```text
Validate package
→ Stage new release
→ Preserve current persistent data
→ If needed migrate legacy persistent data
→ Stop IIS Site
→ Stop IIS AppPool
→ Atomic swap current
→ Start AppPool
→ Start Site
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

اگر `/health` پس از Activation سالم نشود، Installer قبل از Rollback اطلاعات تشخیصی چاپ می‌کند:

```text
IIS Site state / physical path
Application Pool state
Installed .NET runtimes
ASP.NET Core stdout/stderr captured by ANCM when available
Recent IIS / AspNetCore / .NET Runtime events from Windows Event Log
```

این اطلاعات برای تشخیص خطاهای `500.19`، `500.30`، نبود Hosting Bundle، startup failure و خطاهای runtime/database استفاده می‌شود.

### دانلود و Cache

GitHub Release از طریق IPv4 مرجع تشخیص نسخه است. ZIP دانلودشده با SHA-256 کنترل می‌شود. اگر همان نسخه قبلاً در `PackageCacheDirectory` وجود داشته باشد و checksum صحیح باشد، دانلود مجدد انجام نمی‌شود.

### Scheduled Taskها / Automatic Updater

پس از نصب موفق، نسخه Installer در مسیر زیر کپی می‌شود:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.12.ps1
```

Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر کانال هر ۵ دقیقه مستقل بررسی می‌شود. `InstallRoot` و `PackageCacheDirectory` همان مسیر نصب اولیه حفظ می‌شوند؛ بنابراین اگر نصب با `D:\erp_ins` انجام شده باشد، آپدیت‌های بعدی نیز روی همان مسیر انجام می‌شوند و به `C:\ProgramData\iMonitorERP` برنمی‌گردند.

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
