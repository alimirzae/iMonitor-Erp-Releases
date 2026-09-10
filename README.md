# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor / Ecomm / Posiran ERP.

> **فرض نصب ویندوز:** IIS Manager و MySQL از قبل نصب هستند. PowerShell را با **Run as Administrator** باز کنید و دستور مربوط به محصول را Copy/Paste کنید.

---

## 1) Posiran ERP — ساده‌ترین روش نصب و مدیریت

برای نصب، Repair، Upgrade، Backup/Restore و مدیریت Instanceهای Posiran ERP فقط همین دو خط را کامل Copy/Paste کنید:

```powershell
$p="$env:TEMP\Start-PosiranERP-Setup.ps1"; curl.exe -4 --http1.1 -fL "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Start-PosiranERP-Setup.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -o $p
if($LASTEXITCODE -ne 0){throw 'Download failed'}; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

این دستور مستقل است و به متغیر قبلی مثل `$u` وابسته نیست. Setup Host به‌صورت خودکار آخرین Setup منتشرشده را دانلود، SHA256 آن را بررسی و سپس این آدرس را باز می‌کند:

```text
http://127.0.0.1:8099/
```

در Wizard مشخص می‌کنید:

- Test یا Production
- پورت برنامه
- نام پوشه نصب
- اطلاعات MySQL
- Auto Update روشن یا خاموش

مقادیر استاندارد:

```text
Posiran Test       -> port 8082 -> DB posiran_test -> folder test
Posiran Production -> port 8083 -> DB posiran      -> folder production
```

Releaseهای ERP:

```text
posiran_test       -> posiran-erp-test-v*
posiran_production -> posiran-erp-production-v*
```

Setup Manager برای مدیریت نصب‌ها طراحی شده و هسته Orchestrator آن وضعیت Instance، IIS، Health، MySQL، نسخه نصب‌شده/آخرین Release، Backup/Restore و Start/Stop/Restart را پشتیبانی می‌کند.

### نصب مستقیم Posiran Test بدون Wizard

اگر Config کانال قبلاً ساخته شده است:

```powershell
$p="$env:TEMP\Install-PosiranERP.ps1"; curl.exe -4 --http1.1 -fL "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.3.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -o $p
if($LASTEXITCODE -ne 0){throw 'Download failed'}; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Channel Test -TestPort 8082 -TestFolderName test
```

### نصب مستقیم Posiran Production بدون Wizard

```powershell
$p="$env:TEMP\Install-PosiranERP.ps1"; curl.exe -4 --http1.1 -fL "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.3.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -o $p
if($LASTEXITCODE -ne 0){throw 'Download failed'}; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Channel Production -ProductionPort 8083 -ProductionFolderName production
```

برای غیرفعال کردن Auto Update در نصب خط فرمان، `-DisableAutoUpdate` را به خط آخر اضافه کنید.

راهنمای فنی Posiran: `POSIRAN.md`

---

## 2) iMonitor ERP / Ecomm ERP — Windows

Installer رسمی فعلی: `Install-iMonitorERP-v2.0.24.ps1`

### نصب/به‌روزرسانی هر دو کانال

```powershell
$p="$env:TEMP\Install-iMonitorERP.ps1"; curl.exe -4 --http1.1 -fL "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.24.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -o $p
if($LASTEXITCODE -ne 0){throw 'Download failed'}; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Channel Both -Force
```

Mapping:

```text
Test       -> latest imonitor-ecomerp-test-v*   -> DB ecomm_dev -> IIS port 8081
Production -> latest imonitor-ecomerp-master-v* -> DB ecomm     -> IIS port 8080
```

Installer بسته را دانلود، checksum را کنترل، IIS Site/AppPool را Repair/Configure، Config محلی را حفظ و `/health` را بررسی می‌کند.

---

## 3) Linux / Ubuntu ERP

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-v2.0.0.sh | sudo bash -s -- --channel both
```

---

## 4) New Windows Edge

```text
Health             http://127.0.0.1:17891/health
Printer discovery  http://127.0.0.1:17891/api/printers
Direct label print POST http://127.0.0.1:17891/api/labels/print
```

---

## نکات مهم

- تمام اسکریپت‌های Windows از IPv4 و `curl --http1.1` استفاده می‌کنند تا مشکل IPv6/شبکه کاهش پیدا کند.
- بسته‌های عمومی Posiran شامل `appsettings.json` نیستند؛ اطلاعات MySQL فقط روی سرور نصب‌شده نگهداری می‌شود.
- Test و Production دیتابیس، IIS Site، پورت و مسیر مستقل دارند.
- Releaseهای Posiran با White-label مستقل ساخته می‌شوند.
- Bootstrap دیتابیس جدید فقط باید بعد از Validation کامل Schema/Seed وارد نصب Production شود؛ هیچ Dump عملیاتی یا Credential قدیمی نباید مستقیماً در Release قرار بگیرد.
