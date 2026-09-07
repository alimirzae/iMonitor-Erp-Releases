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
  -Force `
  -PackageCacheDirectory (Get-Location).Path
```

در این حالت `InstallRoot` به‌صورت پیش‌فرض همان پوشه جاری است. برای مثال اگر دستور از `D:\erp_ins` اجرا شود:

```text
D:\erp_ins\test\current
D:\erp_ins\production\current
D:\erp_ins\state
D:\erp_ins\installer
```

در صورت نیاز می‌توان مسیر نصب را صریح مشخص کرد:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $installer `
  -Channel Both `
  -InstallRoot 'D:\erp_ins' `
  -PackageCacheDirectory 'D:\erp_ins' `
  -Force
```

`v2.0.12` نسخه رسمی فعلی نصب Windows است.

### نصب خودکار پیش‌نیازها در v2.0.12

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

اگر روی پورت موردنظر یک IIS Site موجود باشد، Installer تا جای ممکن همان Site را برای کانال مربوطه استفاده و AppPool/PhysicalPath آن را اصلاح می‌کند. در صورت وجود چند Binding متعارض روی یک پورت، نصب متوقف می‌شود تا از خراب شدن سایت‌های دیگر جلوگیری شود.

### انتشار امن و Rollback

ترتیب Activation:

```text
Validate package
→ Stage new release
→ Stop IIS Site
→ Stop IIS AppPool
→ Wait/retry for file handles
→ Atomic swap current
→ Start AppPool
→ Start Site
→ Health check
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

از v2.0.12 اگر `/health` پس از Activation سالم نشود، Installer قبل از Rollback اطلاعات تشخیصی چاپ می‌کند:

```text
IIS Site state / physical path
Application Pool state
Installed .NET runtimes
ASP.NET Core stdout logs (در صورت وجود)
Recent IIS / AspNetCore / .NET Runtime events from Windows Event Log
```

این اطلاعات برای تشخیص خطاهای `500.19`، `500.30`، نبود Hosting Bundle، startup failure و خطاهای runtime استفاده می‌شود.

### دانلود و Cache

GitHub Release از طریق IPv4 مرجع تشخیص نسخه است. ZIP دانلودشده با SHA-256 کنترل می‌شود. اگر همان نسخه قبلاً در `PackageCacheDirectory` وجود داشته باشد و checksum صحیح باشد، دانلود مجدد انجام نمی‌شود.

### Scheduled Taskها

پس از نصب موفق، نسخه Installer در مسیر زیر کپی می‌شود:

```text
<InstallRoot>\installer\Install-iMonitorERP-v2.0.12.ps1
```

Taskها:

```text
iMonitorERP-Update-Test
iMonitorERP-Update-Production
```

هر کانال هر ۵ دقیقه مستقل بررسی می‌شود و مسیر `InstallRoot` و `PackageCacheDirectory` همان نصب اولیه را حفظ می‌کند.

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
