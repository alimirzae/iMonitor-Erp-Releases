# iMonitor Release Center

مرکز عمومی انتشار و نصب خودکار محصولات iMonitor / Ecomm / Posiran ERP.

> ⚠️ **مهم برای تمام نصب‌های Windows:** ابتدا منوی Start را باز کنید، `Windows PowerShell` را جستجو کنید، روی آن راست‌کلیک کرده و **Run as Administrator** را بزنید. همه دستورهای زیر باید داخل PowerShell با دسترسی Administrator اجرا شوند.
>
> فرض این راهنما این است که **IIS Manager و MySQL از قبل نصب هستند**.

---

## 1) Posiran ERP — ساده‌ترین روش نصب و مدیریت

PowerShell را حتماً با **Run as Administrator** اجرا کنید، سپس فقط همین دو خط را کامل Copy/Paste کنید. این روش برای Windows به `curl` وابسته نیست:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $p="$env:TEMP\Start-PosiranERP-Setup.ps1"; Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Start-PosiranERP-Setup.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

Setup Host به‌صورت خودکار آخرین Setup منتشرشده را دانلود، SHA256 آن را بررسی و سپس این آدرس را باز می‌کند:

```text
http://127.0.0.1:8099/
```

برای دانلود فایل‌های Release، Posiran ERP دیگر به `curl` متکی نیست. ترتیب دانلود به این صورت است:

1. GitHub Release Assets API با .NET `HttpClient`
2. Windows BITS در صورت شکست مسیر اول
3. `Invoke-WebRequest` به‌عنوان fallback بعدی
4. استفاده از Package Cache محلی در صورت موجود بودن نسخه صحیح

بسته‌های دانلودشده بعد از تأیید SHA256 در مسیر زیر Cache می‌شوند تا نصب/ارتقای بعدی بی‌دلیل دوباره دانلود نشود:

```text
C:\PosiranERP\packages\<release-tag>\
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

PowerShell باید Administrator باشد. اگر Config کانال قبلاً ساخته شده است:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $p="$env:TEMP\Install-PosiranERP.ps1"; Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.3.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Channel Test -TestPort 8082 -TestFolderName test
```

### نصب مستقیم Posiran Production بدون Wizard

PowerShell باید Administrator باشد:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $p="$env:TEMP\Install-PosiranERP.ps1"; Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-PosiranERP-v1.0.3.ps1?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -OutFile $p
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Channel Production -ProductionPort 8083 -ProductionFolderName production
```

برای غیرفعال کردن Auto Update در نصب خط فرمان، `-DisableAutoUpdate` را به خط آخر اضافه کنید.

راهنمای فنی Posiran: `POSIRAN.md`

---

## 2) iMonitor ERP / Ecomm ERP — Windows

PowerShell را با **Run as Administrator** اجرا کنید.

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

- تمام اسکریپت‌های Windows باید از PowerShell با دسترسی Administrator اجرا شوند.
- نصب Posiran ERP در Windows برای Releaseها از GitHub API/.NET HttpClient، BITS و Invoke-WebRequest استفاده می‌کند و به curl وابسته نیست.
- خطای `curl -4` به معنی این است که مشکل گزارش‌شده از انتخاب IPv6 توسط curl نبوده؛ در برخی شبکه‌ها دسترسی به مسیر عادی GitHub Release Asset یا CDN آن می‌تواند متفاوت از `raw.githubusercontent.com` یا `api.github.com` باشد.
- بسته‌های عمومی Posiran شامل `appsettings.json` نیستند؛ اطلاعات MySQL فقط روی سرور نصب‌شده نگهداری می‌شود.
- Test و Production دیتابیس، IIS Site، پورت و مسیر مستقل دارند.
- Releaseهای Posiran با White-label مستقل ساخته می‌شوند.
- Bootstrap دیتابیس جدید فقط باید بعد از Validation کامل Schema/Seed وارد نصب Production شود؛ هیچ Dump عملیاتی یا Credential قدیمی نباید مستقیماً در Release قرار بگیرد.
