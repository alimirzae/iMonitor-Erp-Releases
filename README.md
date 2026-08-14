# iMonitor ERP Releases

این مخزن **کانال عمومی انتشار** iMonitor ERP و iMonitor Edge است. سورس اصلی ERP در مخزن خصوصی نگهداری می‌شود و این مخزن فقط شامل installerها، manifestها، checksumها و GitHub Releaseهای قابل نصب روی سرور/شعبه است.

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

پیش‌فرض‌ها:

- Windows Service: `iMonitorEdge`
- نصب: `C:\Program Files\iMonitor\Edge`
- API/Swagger: `http://127.0.0.1:9000`
- LAN access: فعال، فقط `Private Network / LocalSubnet`
- POS: غیرفعال تا زمانی که درایور/SDK مربوطه تنظیم شود
- TCP/RAW receipt printing (معمولاً port `9100`): فعال

برای نصب روی پورت دیگر یا بدون LAN ابتدا script را دانلود و با پارامتر اجرا کنید:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorEdge.ps1 -OutFile .\Install-iMonitorEdge.ps1
.\Install-iMonitorEdge.ps1 -Channel preview -Port 9000 -AllowLan $true
```

## نصب/ارتقای ERP محلی شعبه

نسخه Production محلی از `stable` و نسخه Preview محلی از `preview` دریافت می‌شود. Installerهای ERP بعد از انتشار اولین artifact در همین مخزن فعال می‌شوند:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorBranch.ps1 -OutFile .\Install-iMonitorBranch.ps1
.\Install-iMonitorBranch.ps1 -InstallProduction -InstallPreview
```

قرارداد پورت محلی:

- Production: `http://localhost:8080`
- Preview/Test: `http://localhost:8081`

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

Installer یک Scheduled Task سبک ایجاد می‌کند که manifest عمومی را بررسی می‌کند. فقط اگر SHA/version تغییر کرده باشد نسخه جدید دانلود، checksum کنترل، سرویس متوقف، backup گرفته، upgrade انجام و health-check اجرا می‌شود. در صورت شکست، نسخه قبلی حفظ/قابل rollback است.

## امنیت

این repository **هیچ** connection string، رمز دیتابیس، Branch Token، PAT، SDK بانکی یا فایل تنظیمات مشتری را نگهداری نمی‌کند. تنظیمات شعبه هنگام upgrade حفظ می‌شوند. فایل‌های انتشار با SHA-256 بررسی می‌شوند.

## Manifestها

- `manifests/edge-preview.json`
- `manifests/edge-stable.json`
- `manifests/erp-preview.json`
- `manifests/erp-stable.json`

تا قبل از اولین انتشار، manifest ممکن است `published=false` باشد و installer پیام واضحی نمایش می‌دهد.
