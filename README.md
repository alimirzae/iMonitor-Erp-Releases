# iMonitor ERP Releases

این مخزن **کانال عمومی انتشار** iMonitor ERP و iMonitor Edge است. سورس اصلی ERP در مخزن خصوصی نگهداری می‌شود و این مخزن فقط شامل installerها، manifestها، checksumها و GitHub Releaseهای قابل نصب روی سرور/شعبه است.

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

نمونه اجرای غیرتعاملی:

```powershell
.\Install-iMonitorBranch.ps1 -InstallProduction -InstallPreview -Root 'D:\ERP' -NonInteractive
```

## تست فیش‌پرینتر شبکه

بعد از نصب Edge:

```powershell
Invoke-RestMethod http://127.0.0.1:9000/api/health
```

برای تست مستقیم یک فیش‌پرینتر شبکه‌ای (مثلاً `192.168.1.200:9100`):

```powershell
$body = @{
  host = '192.168.1.200'
  port = 9100
  text = "iMonitor ERP`nPrinter Test`n`n"
} | ConvertTo-Json

Invoke-RestMethod `
  -Uri http://127.0.0.1:9000/api/printers/network/test `
  -Method Post `
  -ContentType 'application/json' `
  -Body $body
```

## Auto Update

Installer یک Scheduled Task سبک ایجاد می‌کند که manifest عمومی را بررسی می‌کند. فقط اگر SHA/version تغییر کرده باشد نسخه جدید دانلود، checksum کنترل، سرویس متوقف، backup گرفته، upgrade انجام و health-check اجرا می‌شود. مسیر ریشه‌ای که در نصب اولیه انتخاب شده حفظ می‌شود. در صورت شکست، نسخه قبلی حفظ/قابل rollback است.

## امنیت

این repository **هیچ** connection string، رمز دیتابیس، Branch Token، PAT، SDK بانکی یا فایل تنظیمات مشتری را نگهداری نمی‌کند. تنظیمات شعبه هنگام upgrade حفظ می‌شوند. فایل‌های انتشار با SHA-256 بررسی می‌شوند.

## Manifestها

- `manifests/edge-preview.json`
- `manifests/edge-stable.json`
- `manifests/erp-preview.json`
- `manifests/erp-stable.json`

تا قبل از اولین انتشار، manifest ممکن است `published=false` باشد و installer پیام واضحی نمایش می‌دهد.
