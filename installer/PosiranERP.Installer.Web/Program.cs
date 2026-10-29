using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseWindowsService(options => options.ServiceName = "iBOS Deployment Manager");
builder.WebHost.UseUrls("http://127.0.0.1:8099");
builder.Services.AddHttpClient();
builder.Services.AddSingleton<OperationLogStore>();
builder.Services.AddHostedService<AutoUpdateWorker>();

var defaultInstallRoot = builder.Configuration["Installer:InstallRoot"] ?? @"C:\PosiranERP";
var defaultConfigRoot = builder.Configuration["Installer:ConfigRoot"] ?? @"C:\Deploy\PosiranERP";
builder.Services.AddSingleton<OrchestratorService>(sp => new OrchestratorService(defaultInstallRoot, defaultConfigRoot, sp.GetRequiredService<IHttpClientFactory>()));

var app = builder.Build();
var orchestrator = app.Services.GetRequiredService<OrchestratorService>();
app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/api/status", (OrchestratorService orchestrator) =>
{
    var isWindows = OperatingSystem.IsWindows();
    var isAdmin = IsAdministrator();
    var testConfig = Path.Combine(defaultConfigRoot, "Test", "appsettings.json");
    var productionConfig = Path.Combine(defaultConfigRoot, "Production", "appsettings.json");

    return Results.Ok(new
    {
        product = "iBOS Deployment Manager",
        url = "http://127.0.0.1:8099",
        isWindows,
        isAdministrator = isAdmin,
        test = new { port = 8082, database = "posiran_test", folder = "test", configured = File.Exists(testConfig) },
        production = new { port = 8083, database = "posiran", folder = "production", configured = File.Exists(productionConfig) },
        prerequisites = new
        {
            iis = Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "inetsrv")),
            dotnet8 = Environment.Version.Major >= 8,
            mysqlServiceDetected = MySqlServiceDetected(),
            mysqlServices = orchestrator.ListMySqlServices()
        }
    });
});

// Shared, optional OCR prerequisite for all ERP instances on this Windows host.
// Install once in ProgramData; no per-tenant OCR processes or additional listening port.
var ocrRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AiBOS", "OCR");
var ocrScript = Path.Combine(ocrRoot, "Install-AiBOS-OCR.ps1");
var ocrGate = new SemaphoreSlim(1, 1);
string? activeOcrOperationId = null;
string? FindOcrExecutable()
{
    var candidates = new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tesseract-OCR", "tesseract.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Tesseract-OCR", "tesseract.exe") };
    return candidates.FirstOrDefault(File.Exists);
}
object OcrStatus()
{
    var exe = FindOcrExecutable();
    var models = Path.Combine(ocrRoot, "tessdata");
    var filesPresent = exe is not null && File.Exists(Path.Combine(models, "fas.traineddata"))
        && File.Exists(Path.Combine(models, "eng.traineddata"));
    var ready = false;
    string? error = null;
    if (filesPresent)
    {
        try
        {
            var psi = new ProcessStartInfo(exe!) { RedirectStandardOutput = true, RedirectStandardError = true,
                UseShellExecute = false, CreateNoWindow = true };
            psi.Environment["TESSDATA_PREFIX"] = models;
            psi.ArgumentList.Add("--list-langs");
            using var proc = Process.Start(psi) ?? throw new InvalidOperationException("OCR process could not start");
            var outputTask = proc.StandardOutput.ReadToEndAsync();
            var errorTask = proc.StandardError.ReadToEndAsync();
            if (!proc.WaitForExit(5000)) { proc.Kill(true); error = "OCR health check timed out"; }
            else
            {
                var languages = outputTask.GetAwaiter().GetResult();
                var stderr = errorTask.GetAwaiter().GetResult();
                var list = languages.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                ready = proc.ExitCode == 0 && list.Contains("fas") && list.Contains("eng");
                if (!ready) error = stderr.Length > 0 ? stderr : "Required OCR languages not reported";
            }
        }
        catch (Exception ex) { error = ex.Message; }
    }
    return new { installed = ready, filesPresent, executable = exe, modelsPath = models,
        languages = new[] { "fas", "eng" }, shared = true, error };
}
app.MapGet("/api/tools/ocr", (OperationLogStore logs) => Results.Ok(new { status = OcrStatus(), activeOperationId = activeOcrOperationId, operation = activeOcrOperationId is null ? null : logs.Get(activeOcrOperationId) }));
app.MapPost("/api/tools/ocr/install", (HttpContext ctx, IHttpClientFactory clients, OperationLogStore logs) =>
{
    if (!IsAdministrator() || ctx.Connection.RemoteIpAddress is null ||
        !System.Net.IPAddress.IsLoopback(ctx.Connection.RemoteIpAddress)) return Results.StatusCode(403);
    if (!ocrGate.Wait(0)) return Results.Accepted(activeOcrOperationId is null ? "/api/tools/ocr" : "/api/operations/" + activeOcrOperationId,
        new { operationId = activeOcrOperationId, alreadyRunning = true });
    var op = logs.Start("Install shared AiBOS OCR");
    activeOcrOperationId = op.Id;
    _ = Task.Run(async () =>
    {
        try
        {
            logs.Progress(op.Id, "دریافت اسکریپت", 5, "در حال دریافت اسکریپت نصب");
            Directory.CreateDirectory(ocrRoot);
            var code = await clients.CreateClient().GetStringAsync(
                "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-AiBOS-OCR.ps1");
            var temp = ocrScript + ".tmp";
            // Windows PowerShell 5.1 requires a UTF-8 BOM to reliably parse Persian text.
            await File.WriteAllTextAsync(temp, code, new System.Text.UTF8Encoding(true));
            File.Move(temp, ocrScript, true);
            // Parse a local PowerShell script by -File; -Command does not reliably bind $args[0].
            var validator = Path.Combine(ocrRoot, "Validate-OcrInstaller.ps1");
            await File.WriteAllTextAsync(validator,
                "param([string]$ScriptPath)\n" +
                "$tokens=$null; $errors=$null\n" +
                "[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)|Out-Null\n" +
                "if($errors.Count -gt 0){$errors|ForEach-Object{[Console]::Error.WriteLine($_.ToString())};exit 21}\n" +
                "Write-Output 'OCR installer syntax OK'\n", new System.Text.UTF8Encoding(true));
            var verify = new ProcessStartInfo("powershell.exe") { RedirectStandardOutput = true,
                RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            foreach(var arg in new[]{"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",validator,"-ScriptPath",ocrScript})
                verify.ArgumentList.Add(arg);
            using (var check = Process.Start(verify) ?? throw new InvalidOperationException("PowerShell syntax checker could not start"))
            {
                var verifyStdout = check.StandardOutput.ReadToEndAsync();
                var verifyStderr = check.StandardError.ReadToEndAsync();
                using var checkTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                try { await check.WaitForExitAsync(checkTimeout.Token); }
                catch (OperationCanceledException) { try { check.Kill(true); } catch { }
                    throw new InvalidOperationException("OCR installer syntax check timed out"); }
                var output = await verifyStdout;
                var validationError = await verifyStderr;
                if (check.ExitCode != 0) throw new InvalidOperationException(
                    "OCR installer syntax validation failed (exit " + check.ExitCode + "): " +
                    (validationError.Length > 0 ? validationError[..Math.Min(2000, validationError.Length)] : output));
            }
            logs.Progress(op.Id, "بررسی صحت اسکریپت", 12, "PowerShell syntax verified");
            var psi = new ProcessStartInfo("powershell.exe") { RedirectStandardOutput = true,
                RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ocrScript })
                psi.ArgumentList.Add(arg);
            using var process = Process.Start(psi) ?? throw new InvalidOperationException("OCR installer failed to start");
            logs.Progress(op.Id, "اجرای نصب", 15, "فرایند PowerShell شروع شد");
            async Task ReadLinesAsync(StreamReader reader, string level)
            {
                string? line;
                while ((line = await reader.ReadLineAsync()) is not null)
                {
                    logs.Add(op.Id, level, line);
                    if (line.StartsWith("OCR_DOWNLOAD:", StringComparison.OrdinalIgnoreCase))
                    {
                        var d = line["OCR_DOWNLOAD:".Length..].Split('|');
                        if (d.Length == 6 && int.TryParse(d[0], out var baseStage)
                            && int.TryParse(d[2], out var downloadPct)
                            && long.TryParse(d[3], out var bytes)
                            && long.TryParse(d[4], out var total))
                        {
                            var globalPct = downloadPct >= 0 ? Math.Clamp(baseStage + (int)Math.Round(downloadPct * 0.20), 15, 95) : baseStage;
                            var totalDisplay = total > 0 ? (total / 1048576.0).ToString("F1") + " MB" : "unknown";
                            var receivedDisplay = (bytes / 1048576.0).ToString("F1") + " MB";
                            logs.Progress(op.Id, "دانلود " + d[1], globalPct,
                                (downloadPct >= 0 ? downloadPct + "%" : "size unknown") + " (" + receivedDisplay + " / " + totalDisplay + ") speed " + d[5] + " MB/s");
                        }
                    }
                    if (line.StartsWith("OCR_STAGE:", StringComparison.OrdinalIgnoreCase))
                    {
                        var data = line["OCR_STAGE:".Length..].Split('|', 3);
                        if (data.Length >= 2 && int.TryParse(data[0], out var pct))
                            logs.Progress(op.Id, data[1], Math.Clamp(pct, 15, 95),
                                data.Length > 2 ? data[2] : null);
                    }
                }
            }
            var stdout = ReadLinesAsync(process.StandardOutput, "info");
            var stderr = ReadLinesAsync(process.StandardError, "error");
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(15));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { try { process.Kill(true); } catch { }
                throw new TimeoutException("OCR installation exceeded 15 minutes"); }
            await Task.WhenAll(stdout, stderr);
            if (process.ExitCode != 0) throw new InvalidOperationException("OCR install failed (exit " + process.ExitCode + "). See operation log.");
            logs.Complete(op.Id, true, "OCR نصب شد. وضعیت موتور را بررسی کنید.");
        }
        catch (Exception ex) { logs.Complete(op.Id, false, ex.Message); }
        finally { activeOcrOperationId = null; ocrGate.Release(); }
    });
    return Results.Accepted("/api/operations/" + op.Id, new { operationId = op.Id });
});
app.MapPost("/api/tools/ocr/test", async (HttpContext ctx) =>
{
    if ((ctx.Connection.RemoteIpAddress is null || !System.Net.IPAddress.IsLoopback(ctx.Connection.RemoteIpAddress))) return Results.StatusCode(403);
    if (!ctx.Request.HasFormContentType) return Results.BadRequest(new { error = "Upload multipart/form-data image" });
    var form = await ctx.Request.ReadFormAsync(ctx.RequestAborted);
    var image = form.Files.GetFile("image");
    if (image is null || image.Length == 0 || image.Length > 8 * 1024 * 1024) return Results.BadRequest(new { error = "Image size must be 1 byte to 8 MB" });
    var exe = FindOcrExecutable();
    if (exe is null || !File.Exists(Path.Combine(ocrRoot, "tessdata", "fas.traineddata"))) return Results.Problem("OCR is not installed", statusCode: 409);
    var file = Path.Combine(Path.GetTempPath(), "aibos-ocr-" + Guid.NewGuid().ToString("N") + ".png");
    try
    {
        await using (var target = File.Create(file)) await image.CopyToAsync(target, ctx.RequestAborted);
        async Task<(string tsv, string error, int exit)> TryMode(int psm)
        {
            var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true,
                UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = System.Text.Encoding.UTF8 };
            psi.Environment["TESSDATA_PREFIX"] = Path.Combine(ocrRoot, "tessdata");
            foreach (var arg in new[] { file, "stdout", "-l", "fas+eng", "--psm", psm.ToString(), "tsv" }) psi.ArgumentList.Add(arg);
            using var process = Process.Start(psi) ?? throw new InvalidOperationException("OCR engine failed to start");
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
            timeout.CancelAfter(TimeSpan.FromSeconds(45));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { try { process.Kill(true); } catch { } throw new TimeoutException("OCR mode " + psm + " timed out"); }
            return (await stdout, await stderr, process.ExitCode);
        }
        // Sparse-text and automatic segmentation modes work better on receipt photos than PSM 6.
        var candidateModes = new[] { 4, 6, 11, 3 };
        string? bestTsv = null;
        var bestScore = -1;
        var bestMode = 0;
        var diagnostics = new List<object>();
        foreach (var mode in candidateModes)
        {
            var result = await TryMode(mode);
            if (result.exit != 0)
            {
                diagnostics.Add(new { psm = mode, error = result.error, exitCode = result.exit });
                continue;
            }
            var rows = result.tsv.Split('\n');
            var words = rows.Skip(1).Count(row =>
            {
                var cols = row.TrimEnd('\r').Split('\t');
                return cols.Length >= 12 && double.TryParse(cols[10],
                    System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var confidence)
                    && confidence >= 15 && !string.IsNullOrWhiteSpace(cols[11]);
            });
            diagnostics.Add(new { psm = mode, detectedWords = words, tsvChars = result.tsv.Length, stderr = result.error[..Math.Min(250, result.error.Length)] });
            if (words > bestScore) { bestScore = words; bestTsv = result.tsv; bestMode = mode; }
            if (bestScore >= 12) break;
        }
        if (bestTsv is null) return Results.Problem("All OCR modes failed. Check language packs and image format.", statusCode: 500);
        return Results.Ok(new { success = true, tsv = bestTsv, format = "tsv",
            coordinates = true, psm = bestMode, detectedWords = bestScore, diagnostics });
    }
    finally { try { File.Delete(file); } catch { } }
});

// Independent host prerequisite management; does not mutate ERP release packages.
var browserCache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AiBOS", "ms-playwright");
string? FindPlaywrightCli()
{
    foreach (var root in new[] { @"C:\ecomm", defaultInstallRoot })
    {
        foreach (var channel in new[] { "test", "production" })
        {
            var current = Path.Combine(root, channel, "current");
            if (!Directory.Exists(current)) continue;
            try
            {
                var path = Directory.EnumerateFiles(current, "playwright.ps1", SearchOption.AllDirectories).FirstOrDefault();
                if (path is not null) return path;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
    return null;
}
object PlaywrightStatus()
{
    var pwsh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
    var browsers = Directory.Exists(browserCache) ?
        Directory.EnumerateDirectories(browserCache, "chromium-*", SearchOption.TopDirectoryOnly).ToArray() : Array.Empty<string>();
    return new { installed = browsers.Length > 0, chromiumDirectories = browsers.Select(Path.GetFileName).ToArray(),
        cachePath = browserCache, powerShell7Installed = File.Exists(pwsh),
        playwrightCli = FindPlaywrightCli(), installationReady = File.Exists(pwsh) && FindPlaywrightCli() is not null,
        message = browsers.Length > 0 ? "Chromium found; functional launch test still required." :
            "Chromium not found in AiBOS managed cache." };
}
app.MapGet("/api/tools/playwright", () => Results.Ok(PlaywrightStatus()));

app.MapPost("/api/tools/playwright/powershell7/install", async (HttpContext context) =>
{
    if (!OperatingSystem.IsWindows() || !IsAdministrator())
        return Results.Problem("Windows Administrator privileges required.", statusCode: 403);
    if (context.Request.Headers.Origin is { Count: > 0 } origin &&
        (!Uri.TryCreate(origin.ToString(), UriKind.Absolute, out var uri) ||
         uri.Host != context.Request.Host.Host || uri.Port != context.Request.Host.Port))
        return Results.StatusCode(403);
    var pwsh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
    if (File.Exists(pwsh)) return Results.Ok(new { installed = true, alreadyPresent = true, path = pwsh });
    var winget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Microsoft", "WindowsApps", "winget.exe");
    if (!File.Exists(winget))
        return Results.Problem("winget unavailable. Install official signed PowerShell 7 MSI from Microsoft manually.", statusCode: 409);
    var psi = new ProcessStartInfo(winget) { UseShellExecute = false, CreateNoWindow = true };
    foreach (var arg in new[] { "install", "--id", "Microsoft.PowerShell", "--exact",
        "--source", "winget", "--scope", "machine", "--silent",
        "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity" })
        psi.ArgumentList.Add(arg);
    using var process = Process.Start(psi);
    if (process is null) return Results.Problem("Could not launch winget.", statusCode: 500);
    using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(8));
    try { await process.WaitForExitAsync(timeout.Token); }
    catch (OperationCanceledException)
    {
        try { process.Kill(entireProcessTree: true); } catch { }
        return Results.Problem("PowerShell 7 installation timed out.", statusCode: 504);
    }
    if (process.ExitCode != 0 || !File.Exists(pwsh))
        return Results.Problem("PowerShell 7 setup failed or executable not found (winget exit " + process.ExitCode + ").", statusCode: 500);
    return Results.Ok(new { installed = true, path = pwsh });
});


var playwrightInstallGate = new SemaphoreSlim(1, 1);
app.MapPost("/api/tools/playwright/install", async (HttpContext context) =>
{
    if (!OperatingSystem.IsWindows() || !IsAdministrator())
        return Results.Problem("Windows Administrator privileges are required.", statusCode: 403);
    if (context.Request.Headers.Origin is { Count: > 0 } origin &&
        (!Uri.TryCreate(origin.ToString(), UriKind.Absolute, out var uri) ||
         uri.Host != context.Request.Host.Host || uri.Port != context.Request.Host.Port))
        return Results.StatusCode(403);
    if (!await playwrightInstallGate.WaitAsync(0)) return Results.Problem("Playwright installation already running.", statusCode: 409);
    try
    {
        var pwsh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (!File.Exists(pwsh)) return Results.Problem(
            "PowerShell 7 is required. Install the signed Microsoft PowerShell 7 MSI, then retry.", statusCode: 409);
        var cli = FindPlaywrightCli();
        if (cli is null) return Results.Problem(
            "playwright.ps1 is absent from the installed ERP package. A compatible Playwright CLI is required; no ERP release is modified.", statusCode: 409);
        Directory.CreateDirectory(browserCache);
        var psi = new ProcessStartInfo(pwsh) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        psi.Environment["PLAYWRIGHT_BROWSERS_PATH"] = browserCache;
        foreach (var part in new[] { "-NoProfile", "-File", cli, "install", "chromium" }) psi.ArgumentList.Add(part);
        using var process = Process.Start(psi);
        if (process is null) return Results.Problem("Playwright installer failed to start.", statusCode: 500);
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(12));
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            return Results.Problem("Playwright installation timed out.", statusCode: 504);
        }
        var output = await stdout;
        var error = await stderr;
        if (process.ExitCode != 0) return Results.Problem(
            "Playwright installation failed (exit " + process.ExitCode + "): " + error[..Math.Min(700, error.Length)], statusCode: 500);
        // Machine-level environment for IIS workers; recycle needed for existing pools.
        Environment.SetEnvironmentVariable("PLAYWRIGHT_BROWSERS_PATH", browserCache, EnvironmentVariableTarget.Machine);
        return Results.Ok(new { success = true, status = PlaywrightStatus(),
            restartIisPoolsRecommended = true, output = output[..Math.Min(1000, output.Length)] });
    }
    finally { playwrightInstallGate.Release(); }
});


var managedBrowserSettings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AiBOS", "BrowserHost", "browser-settings.json");
string SelectedBrowser()
{
    try
    {
        if (File.Exists(managedBrowserSettings))
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(managedBrowserSettings));
            return doc.RootElement.GetProperty("BrowserHost").GetProperty("ExecutablePath").GetString() ?? "";
        }
    }
    catch (Exception ex) { Console.Error.WriteLine("Browser config: " + ex.Message); }
    return "";
}
bool ValidChrome(string path) => Path.IsPathFullyQualified(path) &&
    string.Equals(Path.GetFileName(path), "chrome.exe", StringComparison.OrdinalIgnoreCase) &&
    File.Exists(path);
bool LocalOrigin(HttpContext ctx)
{
    var origin = ctx.Request.Headers.Origin.ToString();
    return string.IsNullOrEmpty(origin) || (Uri.TryCreate(origin, UriKind.Absolute, out var uri) &&
        uri.IsLoopback && uri.Port == ctx.Request.Host.Port);
}
app.MapGet("/api/tools/chromium", () =>
{
    var configured = SelectedBrowser();
    var suggested = Path.Combine(browserCache, "Chromium", "Application", "chrome.exe");
    var candidate = !string.IsNullOrWhiteSpace(configured) ? configured : suggested;
    return Results.Ok(new { executablePath = candidate, configured = !string.IsNullOrWhiteSpace(configured),
        found = ValidChrome(candidate), settingsFile = managedBrowserSettings,
        browserCache, launchTestRequired = true });
});
app.MapPost("/api/tools/chromium/configure", (ChromiumPathRequest request, HttpContext ctx) =>
{
    if (!IsAdministrator() || !LocalOrigin(ctx)) return Results.StatusCode(403);
    var p = request.ExecutablePath?.Trim() ?? "";
    if (!ValidChrome(p)) return Results.BadRequest(new { error = "Select an existing absolute chrome.exe path." });
    // Refuse UNC and remote shares; browser binaries must reside on the server.
    if (p.StartsWith(@"\\", StringComparison.Ordinal)) return Results.BadRequest(new { error = "Network share is not allowed." });
    Directory.CreateDirectory(Path.GetDirectoryName(managedBrowserSettings)!);
    var settings = JsonSerializer.Serialize(new { BrowserHost = new { ExecutablePath = p } });
    var temp = managedBrowserSettings + ".tmp";
    File.WriteAllText(temp, settings);
    File.Move(temp, managedBrowserSettings, true);
    return Results.Ok(new { saved = true, executablePath = p, restartBrowserHostRecommended = true });
});
app.MapPost("/api/tools/chromium/test", async (HttpContext ctx) =>
{
    if (!IsAdministrator() || !LocalOrigin(ctx)) return Results.StatusCode(403);
    var chrome = SelectedBrowser();
    if (!ValidChrome(chrome)) return Results.Problem("Save a valid Chromium path first.", statusCode: 409);
    var work = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AiBOS", "BrowserHost", "Temp", "ChromiumTests", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(work);
    try
    {
        var html = Path.Combine(work, "page.html");
        var shot = Path.Combine(work, "shot.png");
        var stdout = Path.Combine(work, "stdout.txt");
        var stderr = Path.Combine(work, "stderr.txt");
        await File.WriteAllTextAsync(html, "<html><body><h1>AiBOS Chromium Headless OK</h1></body></html>");
        var psi = new ProcessStartInfo(chrome) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true, WorkingDirectory = work };
        foreach (var arg in new[] { "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-extensions", "--user-data-dir=" + Path.Combine(work, "profile"),
            "--screenshot=" + shot, "--window-size=1280,720", new Uri(html).AbsoluteUri }) psi.ArgumentList.Add(arg);
        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Chromium could not start.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
        var outTask = process.StandardOutput.ReadToEndAsync();
        var errTask = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            try { process.Kill(true); } catch { }
            return Results.Problem("Chromium timed out.", statusCode: 504);
        }
        var output = await outTask;
        var error = await errTask;
        await File.WriteAllTextAsync(stdout, output);
        await File.WriteAllTextAsync(stderr, error);
        var ok = process.ExitCode == 0 && File.Exists(shot) && new FileInfo(shot).Length > 100;
        return Results.Ok(new { success = ok, exitCode = process.ExitCode,
            screenshotBytes = File.Exists(shot) ? new FileInfo(shot).Length : 0,
            screenshotBase64 = ok ? Convert.ToBase64String(await File.ReadAllBytesAsync(shot)) : null,
            error = error.Length > 1000 ? error[..1000] : error,
            note = "Local HTML headless test from deployment manager; Playwright BrowserHost startup still requires separate validation." });
    }
    catch (Exception ex) { return Results.Problem(ex.Message, statusCode: 500); }
    finally { try { Directory.Delete(work, true); } catch { } }
});
app.MapPost("/api/tools/chromium/permissions", async (HttpContext ctx) =>
{
    if (!IsAdministrator() || !LocalOrigin(ctx)) return Results.StatusCode(403);
    var chrome = SelectedBrowser();
    if (!ValidChrome(chrome)) return Results.Problem("Configure Chromium first.", statusCode: 409);
    var principals = new[] { "IIS AppPool\\iMonitorERP-Test", "IIS AppPool\\iMonitorERP-Production",
        "IIS AppPool\\PosiranERP-Test", "IIS AppPool\\PosiranERP-Production" };
    var dataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AiBOS", "BrowserHost");
    var changes = new List<string>();
    async Task Grant(string folder, string principal, string rights)
    {
        var psi = new ProcessStartInfo("icacls.exe") { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        psi.ArgumentList.Add(folder); psi.ArgumentList.Add("/grant"); psi.ArgumentList.Add(principal + ":(OI)(CI)(" + rights + ")");
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("Cannot start icacls");
        var output = await p.StandardOutput.ReadToEndAsync();
        var error = await p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        if (p.ExitCode != 0) throw new InvalidOperationException("icacls failed for " + principal + ": " + error);
        changes.Add(principal + " " + rights + " " + folder);
    }
    try
    {
        // Executables read/execute only; writable profile data is separate.
        foreach (var principal in principals) await Grant(browserCache, principal, "RX");
        foreach (var name in new[] { "Sessions", "Profiles", "Logs", "Temp" })
        {
            var dir = Path.Combine(dataRoot, name);
            Directory.CreateDirectory(dir);
            foreach (var principal in principals) await Grant(dir, principal, "M");
        }
        return Results.Ok(new { success = true, changes, note = "Dedicated BrowserHost service identities must be granted separately." });
    }
    catch (Exception ex) { return Results.Problem(ex.Message, statusCode: 500); }
});

// Persist all four installation cards independently of deployment, including runtime URLs.
var installerFormPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
    "AiBOS", "DeploymentManager", "form-settings.json");
app.MapGet("/api/installer-form", () =>
{
    if (!File.Exists(installerFormPath)) return Results.Ok(new Dictionary<string, JsonElement>());
    try { return Results.Text(File.ReadAllText(installerFormPath), "application/json"); }
    catch { return Results.Problem("Could not read saved installer form.", statusCode: 500); }
});
app.MapPost("/api/installer-form", (JsonElement form, HttpContext context) =>
{
    if (!OperatingSystem.IsWindows() || !IsAdministrator()) return Results.StatusCode(403);
    if (context.Request.Headers.Origin is { Count: > 0 } origin &&
        (!Uri.TryCreate(origin.ToString(), UriKind.Absolute, out var source) ||
         !string.Equals(source.Host, context.Request.Host.Host, StringComparison.OrdinalIgnoreCase) ||
         source.Port != context.Request.Host.Port)) return Results.StatusCode(403);
    if (form.ValueKind != JsonValueKind.Object || form.GetRawText().Length > 16384)
        return Results.BadRequest(new { error = "Invalid settings payload." });
    Directory.CreateDirectory(Path.GetDirectoryName(installerFormPath)!);
    var tmp = installerFormPath + ".tmp";
    File.WriteAllText(tmp, form.GetRawText());
    File.Move(tmp, installerFormPath, true);
    return Results.Ok(new { saved = true });
});

app.MapGet("/api/installations", async (OrchestratorService orchestrator, CancellationToken ct) =>
    Results.Ok(await orchestrator.ListInstallationsAsync(ct)));
app.MapGet("/api/releases/{product}/{channel}", async (string product, string channel, OrchestratorService orchestrator, CancellationToken ct) =>
    Results.Ok(await orchestrator.ListReleasesAsync(product, channel, ct)));
app.MapGet("/api/history/{id}", (string id, OrchestratorService orchestrator) =>
    Results.Ok(orchestrator.GetVersionHistory(id)));
app.MapGet("/api/approvals/{id}", (string id, OrchestratorService orchestrator) =>
    Results.Ok(orchestrator.GetVersionApprovals(id)));
app.MapPost("/api/approvals/{id}/{tag}", (string id, string tag, VersionApprovalRequest request, OrchestratorService orchestrator) =>
{
    try
    {
        orchestrator.SetVersionApproval(id, tag, request.Approved);
        return Results.Ok(new { id, tag, approved = request.Approved });
    }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});
app.MapPost("/api/installations/{id}/install-version/{tag}", async (string id, string tag, OrchestratorService orchestrator, OperationLogStore logs, CancellationToken ct) =>
{
    var op = logs.Start($"Install version {id} {tag}");
    try
    {
        var result = await orchestrator.InstallVersionAsync(id, tag, ct,
            (stage, percent, message) => logs.Progress(op.Id, stage, percent, message));
        logs.Complete(op.Id, true, result.Message);
        return Results.Ok(new { result, operationId = op.Id });
    }
    catch (Exception ex)
    {
        logs.Complete(op.Id, false, ex.Message);
        return Results.Problem(title: "Version installation failed", detail: $"Operation {op.Id}: {ex.Message}", statusCode: 500);
    }
});
app.MapPost("/api/installations/{id}/rollback/{tag}", async (string id, string tag, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try { return Results.Ok(await orchestrator.RollbackToVersionAsync(id, tag, ct)); }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});

app.MapGet("/api/operations", (OperationLogStore logs) => Results.Ok(logs.Recent()));
app.MapGet("/api/operations/{id}", (string id, OperationLogStore logs) =>
{
    var state = logs.Get(id);
    return state is null ? Results.NotFound() : Results.Ok(state);
});
app.MapGet("/api/manual-help", () => Results.Ok(new
{
    cache = @"Place downloaded release ZIP and its .sha256 file under <InstallRoot>\packages\<tag>\.",
    powershell = new {
        tls = "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12",
        githubIPv4 = "curl.exe -4 --http1.1 -fL --connect-timeout 15 --max-time 600 <URL> -o <FILE>",
        inspect = "Test-NetConnection github.com -Port 443; Resolve-DnsName github.com; curl.exe -4 -I --connect-timeout 15 https://github.com"
    },
    note = "If GitHub is blocked, download the ZIP and .sha256 in a browser/another machine and copy both files into the cache folder. The deployment manager will use a valid cached package without downloading it again."
}));
app.MapGet("/api/mysql/services", (OrchestratorService orchestrator) => Results.Ok(orchestrator.ListMySqlServices()));

app.MapPost("/api/installations/{id}/backup", async (string id, BackupRequest? request, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try { return Results.Ok(await orchestrator.BackupAsync(id, request?.Reason, ct)); }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});

app.MapPost("/api/installations/{id}/restore/{backupId}", async (string id, string backupId, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try { return Results.Ok(await orchestrator.RestoreAsync(id, backupId, ct)); }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});

app.MapPost("/api/installations/{id}/control/{action}", async (string id, string action, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try { return Results.Ok(await orchestrator.ControlAsync(id, action, ct)); }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});

app.MapPost("/api/installations/{id}/upgrade", async (string id, OrchestratorService orchestrator, IHttpClientFactory clients, OperationLogStore logs, CancellationToken ct) =>
{
    var op = logs.Start($"Upgrade {id}");
    try
    {
        var manifest = orchestrator.RequireManifest(id);
        using var maintenance = orchestrator.AcquireMaintenance(id);
        logs.Add(op.Id, "info", $"Pre-upgrade backup for {manifest.DisplayName}");
        var backup = await orchestrator.BackupAsync(id, "pre-upgrade", ct);
        var scriptDirectory = Path.Combine(manifest.InstallRoot, "installer");
        Directory.CreateDirectory(scriptDirectory);
        var isIMonitor = string.Equals(manifest.Product, "iMonitor", StringComparison.OrdinalIgnoreCase);
        var scriptPath = Path.Combine(scriptDirectory, isIMonitor ? "Install-iMonitorERP-v2.1.6.ps1" : "Install-PosiranERP-v1.0.5.ps1");
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);
        await DownloadInstallerScriptAsync(http, scriptPath, isIMonitor, ct);
        var configRoot = Path.Combine(manifest.InstallRoot, "config");
        var args = new List<string>
        {
            "-NoProfile","-ExecutionPolicy","Bypass","-File",scriptPath,
            "-Channel",manifest.Channel,"-Mode","InstallOrUpdate","-InstallRoot",manifest.InstallRoot,"-ConfigRoot",configRoot,
            manifest.Channel == "Test" ? "-TestPort" : "-ProductionPort",manifest.Port.ToString(),
            manifest.Channel == "Test" ? "-TestFolderName" : "-ProductionFolderName",manifest.InstallFolderName,
            "-Force"
        };
        if (!string.IsNullOrWhiteSpace(manifest.RuntimeUrl)) { args.Add("-RuntimeHealthUrl"); args.Add(manifest.RuntimeUrl); }
        if (!isIMonitor && !manifest.AutoUpdate) args.Add("-DisableAutoUpdate");
        logs.Progress(op.Id, "اجرای ارتقا", 10, $"اجرای ارتقا روی {manifest.RuntimeUrl ?? $"http://127.0.0.1:{manifest.Port}"}");
        var run = await RunPowerShellAsync(args, 30 * 60 * 1000, logs, op.Id, ct);
        if (run.ExitCode != 0)
        {
            logs.Complete(op.Id, false, $"PowerShell exit code {run.ExitCode}. Pre-upgrade backup: {backup.BackupId}. {run.Error}");
            return Results.Problem(title: "Upgrade failed", detail: $"Operation {op.Id}: {run.Error}", statusCode: 500);
        }

        logs.Add(op.Id, "info", $"PowerShell completed. Verifying HTTP health, IIS and database on port {manifest.Port}.");
        var verification = await orchestrator.VerifyInstallationRuntimeAsync(id, ct);
        if (!verification.Ok)
        {
            logs.Complete(op.Id, false, "Upgrade finished but runtime verification failed: " + verification.Message);
            return Results.Problem(title: "Upgrade runtime verification failed", detail: $"Operation {op.Id}: {verification.Message}", statusCode: 500);
        }

        try { orchestrator.PruneOldBackups(id); } catch (Exception ex) { logs.Add(op.Id, "warn", "Backup retention: " + ex.Message); }
        logs.Complete(op.Id, true, "Upgrade and runtime verification succeeded: " + verification.Message);
        return Results.Ok(new { upgraded = true, preUpgradeBackup = backup.BackupId, operationId = op.Id, runtime = verification, output = run.Output });
    }
    catch (Exception ex)
    {
        logs.Complete(op.Id, false, ex.Message);
        return Results.Problem(title: "Upgrade failed", detail: $"Operation {op.Id}: {ex.Message}", statusCode: 500);
    }
});

app.MapPost("/api/configure", (SetupRequest request, OrchestratorService orchestrator) =>
{
    if (!OperatingSystem.IsWindows()) return Results.BadRequest(new { error = "This installer currently supports Windows only." });
    if (!IsAdministrator()) return Results.BadRequest(new { error = "Run the installer service as Administrator." });

    var channel = NormalizeChannel(request.Channel);
    if (channel is null) return Results.BadRequest(new { error = "Channel must be Test or Production." });

    var validation = ValidateDatabaseFields(request);
    if (validation is not null) return Results.BadRequest(new { error = validation });
    var folderValidation = ValidateFolderName(request.InstallFolderName);
    if (folderValidation is not null) return Results.BadRequest(new { error = folderValidation });

    var isTest = channel == "Test";
    var isIMonitor = string.Equals(request.Product, "iMonitor", StringComparison.OrdinalIgnoreCase);
    var installRoot = ResolveInstallRoot(request.InstallRoot, isIMonitor ? @"C:\ecomm" : defaultInstallRoot);
    Directory.CreateDirectory(installRoot);
    var configRoot = Path.Combine(installRoot, "config");
    var database = request.DatabaseName.Trim();
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isIMonitor ? (isTest ? 8081 : 8080) : (isTest ? 8082 : 8083));
    var installFolderName = string.IsNullOrWhiteSpace(request.InstallFolderName) ? (isTest ? "test" : "production") : request.InstallFolderName.Trim();
    var configDirectory = Path.Combine(configRoot, channel);
    var configPath = Path.Combine(configDirectory, "appsettings.json");
    Directory.CreateDirectory(configDirectory);

    // An empty password field means "keep the saved one": re-running install/update from the
    // form must never wipe a working MySQL password (every site then fails with "using password: NO").
    var existingConfig = LoadExistingAppSettings(configPath);
    if (string.IsNullOrEmpty(request.DatabasePassword))
        request = request with { DatabasePassword = ReadSavedMySqlPassword(existingConfig) ?? string.Empty };

    var connectionString = $"Server={request.DatabaseServer};Port={request.DatabasePort};Database={database};User={request.DatabaseUser};Password={request.DatabasePassword};Charset=utf8mb4;";
    var config = MergeWithExistingAppSettings(
        JsonSerializer.SerializeToNode(BuildAppSettings(isTest, request, connectionString, isIMonitor))!.AsObject(),
        existingConfig);
    if (File.Exists(configPath))
        File.Copy(configPath, $"{configPath}.bak-{DateTime.Now:yyyyMMdd-HHmmss}", overwrite: true);
    File.WriteAllText(configPath, config.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    var effectiveAutoUpdate = isTest; // Test is always automatic; Production is always explicit/manual.
    var registered = orchestrator.RegisterInstance(request.Product ?? (isIMonitor ? "iMonitor" : "Posiran"), channel, installRoot, appPort, installFolderName, database, effectiveAutoUpdate, configPath, request.RuntimeUrl);

    return Results.Ok(new
    {
        channel,
        database,
        appPort,
        installFolderName,
        autoUpdate = isTest,
        configPath,
        installPath = Path.Combine(installRoot, installFolderName, "current"),
        runtimeUrl = registered.RuntimeUrl ?? $"http://127.0.0.1:{appPort}",
        message = "Configuration saved and instance registered. Password is intentionally not returned by the API."
    });
});

app.MapPost("/api/install", async (InstallRequest request, IHttpClientFactory clients, OperationLogStore logs, CancellationToken requestCt) =>
{
    var op = logs.Start($"Install {request.Product} {request.Channel}");
    logs.Progress(op.Id,"اعتبارسنجی",2,"بررسی سیستم و تنظیمات");
    if (!OperatingSystem.IsWindows()) return Results.BadRequest(new { error = "This installer currently supports Windows only." });
    if (!IsAdministrator()) return Results.BadRequest(new { error = "Run the installer service as Administrator." });

    var channel = NormalizeChannel(request.Channel);
    if (channel is null) return Results.BadRequest(new { error = "Channel must be Test or Production." });
    var folderValidation = ValidateFolderName(request.InstallFolderName);
    if (folderValidation is not null) return Results.BadRequest(new { error = folderValidation });

    var isTest = channel == "Test";
    var isIMonitor = string.Equals(request.Product, "iMonitor", StringComparison.OrdinalIgnoreCase);
    var installRoot = ResolveInstallRoot(request.InstallRoot, isIMonitor ? @"C:\ecomm" : defaultInstallRoot);
    Directory.CreateDirectory(installRoot);
    var configRoot = Path.Combine(installRoot, "config");
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isIMonitor ? (isTest ? 8081 : 8080) : (isTest ? 8082 : 8083));
    var installFolderName = string.IsNullOrWhiteSpace(request.InstallFolderName) ? (isTest ? "test" : "production") : request.InstallFolderName.Trim();
    var configPath = Path.Combine(configRoot, channel, "appsettings.json");
    if (!File.Exists(configPath)) return Results.BadRequest(new { error = $"Configure {channel} before installation." });

    var scriptDirectory = Path.Combine(installRoot, "installer");
    Directory.CreateDirectory(scriptDirectory);
    var scriptPath = Path.Combine(scriptDirectory, isIMonitor ? "Install-iMonitorERP-v2.1.6.ps1" : "Install-PosiranERP-v1.0.5.ps1");

    if (!File.Exists(scriptPath) || request.RefreshInstaller)
    {
        logs.Progress(op.Id,"اسکریپت نصاب",5,$"بررسی cache: {scriptPath}");
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(45);
        try { await DownloadInstallerScriptAsync(http, scriptPath, isIMonitor, requestCt); logs.Progress(op.Id,"اسکریپت نصاب",8,"اسکریپت دریافت و تأیید شد"); }
        catch(Exception ex) when(File.Exists(scriptPath)) { logs.Add(op.Id,"warn","دریافت اسکریپت ناموفق بود؛ از نسخه cache شده استفاده می‌شود. "+ex.Message); }
        catch(Exception ex) { logs.Complete(op.Id,false,"دریافت اسکریپت ناموفق: "+ex.Message); throw; }
    }

    var args = new List<string>
    {
        "-NoProfile","-ExecutionPolicy","Bypass","-File",scriptPath,
        "-Channel",channel,"-Mode","InstallOrUpdate","-InstallRoot",installRoot,"-ConfigRoot",configRoot,
        isTest ? "-TestPort" : "-ProductionPort",appPort.ToString(),
        isTest ? "-TestFolderName" : "-ProductionFolderName",installFolderName
    };
    var installId = (isIMonitor ? "imonitor-" : "posiran-") + channel.ToLowerInvariant();
    var installManifest = orchestrator.RequireManifest(installId);
    using var maintenance = orchestrator.AcquireMaintenance(installId);
    if (!string.IsNullOrWhiteSpace(installManifest.RuntimeUrl)) { args.Add("-RuntimeHealthUrl"); args.Add(installManifest.RuntimeUrl); }
    if (!isIMonitor && !isTest) args.Add("-DisableAutoUpdate");
    if (request.Force) args.Add("-Force");
    logs.Progress(op.Id,"استقرار",10,"اجرای Installer؛ خروجی به‌صورت زنده نمایش داده می‌شود");
    var r = await RunPowerShellAsync(args, 30 * 60 * 1000, logs, op.Id, requestCt);
    if (r.ExitCode != 0) { logs.Complete(op.Id,false,$"PowerShell exit code {r.ExitCode}: {r.Error}"); return Results.Problem(title: "Installation failed", detail: $"Operation {op.Id}: {r.Error}", statusCode: 500); }

    var productName = isIMonitor ? "iMonitor" : "Posiran";
    var instanceId = $"{productName.ToLowerInvariant()}-{channel.ToLowerInvariant()}";
    var activeManifest = orchestrator.RequireManifest(instanceId);
    logs.Progress(op.Id,"Health Check",92,$"کنترل {activeManifest.RuntimeUrl ?? $"http://127.0.0.1:{appPort}"}/health، IIS و دیتابیس");
    RuntimeVerificationResult verification;
    try
    {
        verification = await orchestrator.VerifyInstallationRuntimeAsync(instanceId, CancellationToken.None);
    }
    catch (Exception ex)
    {
        logs.Complete(op.Id,false,"نصب پایان یافت اما کنترل runtime اجرا نشد: "+ex.Message);
        return Results.Problem(title: "Runtime verification failed", detail: $"Operation {op.Id}: {ex.Message}", statusCode: 500);
    }
    if (!verification.Ok)
    {
        logs.Complete(op.Id,false,"PowerShell موفق بود اما ERP واقعا بالا نیامد: "+verification.Message);
        return Results.Problem(title: "ERP did not become healthy", detail: $"Operation {op.Id}: {verification.Message}", statusCode: 500);
    }

    logs.Progress(op.Id,"تکمیل",100,verification.Message);
    logs.Complete(op.Id,true,"نصب و Health Check واقعی با موفقیت پایان یافت: "+verification.Message);

    return Results.Ok(new
    {
        channel,
        exitCode = r.ExitCode,
        localUrl = (activeManifest.RuntimeUrl ?? $"http://127.0.0.1:{appPort}").TrimEnd('/') + "/",
        installPath = Path.Combine(installRoot, installFolderName, "current"),
        autoUpdate = request.AutoUpdate,
        operationId = op.Id,
        runtime = verification,
        output = r.Output
    });
});


app.MapPost("/api/installations/{id}/runtime-url", async (string id, RuntimeUrlUpdate request, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try
    {
        var check = await orchestrator.TestRuntimeUrlAsync(request.RuntimeUrl, ct);
        if (!check.Ok) return Results.BadRequest(new { error = check.Message, saved = false });
        var updated = orchestrator.UpdateRuntimeUrl(id, request.RuntimeUrl);
        return Results.Ok(new { saved = true, runtimeUrl = updated.RuntimeUrl, health = check.Message });
    }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});
app.MapPost("/api/installations/{id}/test-health-url", async (string id, RuntimeUrlUpdate request, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try
    {
        orchestrator.RequireManifest(id);
        var result = await orchestrator.TestRuntimeUrlAsync(request.RuntimeUrl, ct);
        return Results.Ok(result);
    }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});
app.MapPost("/api/installations/{id}/prune-backups", (string id, OrchestratorService orchestrator) =>
{
    try { return Results.Ok(new { removed = orchestrator.PruneOldBackups(id) }); }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});

app.MapGet("/api/watchdog/task-status", async () =>
{
    if (!OperatingSystem.IsWindows()) return Results.Ok(new { installed = false, details = "Windows only" });
    try
    {
        var psi = new ProcessStartInfo("schtasks.exe") {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
        };
        foreach (var arg in new[] { "/Query", "/TN", "iBOS-ERP-Watchdog", "/FO", "LIST", "/V" })
            psi.ArgumentList.Add(arg);
        using var process = Process.Start(psi) ?? throw new InvalidOperationException("schtasks unavailable");
        var output = await process.StandardOutput.ReadToEndAsync();
        var error = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return Results.Ok(new { installed = process.ExitCode == 0, details = process.ExitCode == 0 ? output : error });
    }
    catch (Exception ex) { return Results.Ok(new { installed = false, details = ex.Message }); }
});
app.MapGet("/api/watchdog/{id}/history", (string id, OrchestratorService orchestrator) =>
{
    try
    {
        if (!Regex.IsMatch(id, @"^[a-zA-Z0-9_-]+$")) return Results.BadRequest();
        orchestrator.RequireManifest(id);
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "iMonitor", "ERPDeploymentManager");
        var path = Path.Combine(root, "watchdog-logs", id + ".jsonl");
        var records = new List<JsonNode?>();
        if (File.Exists(path))
            foreach (var line in File.ReadLines(path).TakeLast(80))
                try { records.Add(JsonNode.Parse(line)); } catch { }
        return Results.Ok(new { records = records.AsEnumerable().Reverse().ToArray(), checkedAtUtc = DateTime.UtcNow });
    }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});
app.MapGet("/api/watchdog/{id}", (string id) =>
{
    if (!Regex.IsMatch(id, @"^[a-zA-Z0-9_-]+$")) return Results.BadRequest();
    var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "iMonitor", "ERPDeploymentManager");
    var path = Path.Combine(root, "watchdog", id + ".json");
    var state = Path.Combine(root, "watchdog-logs", id + ".state.json");
    return Results.Ok(new { settings = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) : null,
        state = File.Exists(state) ? JsonNode.Parse(File.ReadAllText(state)) : null });
});
app.MapPost("/api/watchdog/{id}", async (string id, WatchdogSettings request, OrchestratorService orchestrator) =>
{
    try
    {
        if (!OperatingSystem.IsWindows()) return Results.BadRequest(new { error = "Windows only." });
        if (!Regex.IsMatch(id, @"^[a-zA-Z0-9_-]+$")) return Results.BadRequest(new { error = "Invalid ID" });
        var instance = orchestrator.RequireManifest(id);
        if (request.IntervalMinutes is < 1 or > 1440 || request.AfterRestartDelayMinutes is < 1 or > 60 || request.TimeoutSeconds is < 2 or > 60)
            return Results.BadRequest(new { error = "Invalid watchdog intervals." });
        if (!Uri.TryCreate(request.HealthUrl, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            !string.IsNullOrEmpty(uri.UserInfo) || uri.HostNameType == UriHostNameType.Unknown)
            return Results.BadRequest(new { error = "Enter an absolute HTTP(S) health URL." });
        // Only registered endpoints, with no credentials, fragments or query secrets.
        if (!string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            return Results.BadRequest(new { error = "Health URL must not contain query or fragment." });
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "iMonitor", "ERPDeploymentManager");
        var folder = Path.Combine(root, "watchdog");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, id + ".json");
        var tmp = path + ".tmp";
        await File.WriteAllTextAsync(tmp, JsonSerializer.Serialize(request with { HealthUrl = uri.AbsoluteUri }));
        File.Move(tmp, path, true);
        var script = Path.Combine(AppContext.BaseDirectory, "Invoke-ERPWatchdog.ps1");
        if (!File.Exists(script))
            return Results.Problem("Watchdog script not installed beside Setup Host. Restart with updated installer.", statusCode: 500);
        // Scheduled task outlives the Setup Host and checks persisted config every minute.
        var quoted = "\"" + script.Replace("\"", "\"\"") + "\"";
        var taskCommand = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + quoted;
        var psi = new ProcessStartInfo("schtasks.exe") {
            UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true, CreateNoWindow = true
        };
        foreach (var arg in new[] { "/Create", "/F", "/TN", "iBOS-ERP-Watchdog", "/SC", "MINUTE", "/MO", "1", "/RU", "SYSTEM", "/RL", "HIGHEST", "/TR", taskCommand }) psi.ArgumentList.Add(arg);
        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start schtasks.");
        var stdout = await proc.StandardOutput.ReadToEndAsync();
        var stderr = await proc.StandardError.ReadToEndAsync();
        await proc.WaitForExitAsync();
        if (proc.ExitCode != 0) return Results.Problem("Watchdog task registration failed: " + stderr, statusCode: 500);
        return Results.Ok(new { saved = true, task = "iBOS-ERP-Watchdog", id, healthUrl = uri.AbsoluteUri });
    }
    catch (Exception ex) { return Results.Problem(ex.Message); }
});

app.MapGet("/api/runtime-health", async (OrchestratorService orchestrator, CancellationToken ct) =>
{
    var installations = await orchestrator.ListInstallationsAsync(ct);
    return Results.Ok(new
    {
        checkedAtUtc = DateTime.UtcNow,
        allHealthy = installations.Count > 0 && installations.All(x => x.HealthOk && x.DatabaseReachable
            && (string.Equals(x.IisSiteState, "Unknown", StringComparison.OrdinalIgnoreCase)
                || string.Equals(x.IisSiteState, "Unsupported", StringComparison.OrdinalIgnoreCase)
                || (string.Equals(x.IisSiteState, "Started", StringComparison.OrdinalIgnoreCase) && string.Equals(x.IisPoolState, "Started", StringComparison.OrdinalIgnoreCase)))),
        installations
    });
});
app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "PosiranERP.Installer.Web" }));
app.MapFallbackToFile("index.html");
app.Run();

static async Task DownloadInstallerScriptAsync(HttpClient http, string destination, bool isIMonitor = false, CancellationToken cancellationToken = default)
{
    http.DefaultRequestHeaders.UserAgent.ParseAdd("PosiranERP-Setup/1.0");
    http.DefaultRequestHeaders.CacheControl = new() { NoCache = true, NoStore = true };
    var scriptUrl = isIMonitor ? "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/43d1f2e1c66d82a6f3e98ecef2937ebe773c089c/scripts/Install-iMonitorERP-v2.1.6.ps1" : "https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/posiran-erp-installer-v1.0.5/Install-PosiranERP-v1.0.5.ps1";
    var bytes = await http.GetByteArrayAsync(scriptUrl, cancellationToken);
    var text = System.Text.Encoding.UTF8.GetString(bytes);
    if (!text.Contains("function Stop-ChannelHost", StringComparison.Ordinal) || !text.Contains("Get-WebAppPoolState", StringComparison.Ordinal))
        throw new InvalidOperationException("Downloaded Posiran installer asset failed the version contract.");
    await File.WriteAllBytesAsync(destination, bytes, cancellationToken);
    Console.WriteLine("Installer script downloaded from Posiran ERP installer release v1.0.5.");
}

static async Task<InstallerProcessResult> RunPowerShellAsync(IEnumerable<string> args, int timeoutMs, OperationLogStore logs, string operationId, CancellationToken cancellationToken)
{
    var psi = new ProcessStartInfo { FileName = "powershell.exe", RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
    foreach (var arg in args) psi.ArgumentList.Add(arg);
    using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
    var output = new System.Text.StringBuilder();
    var error = new System.Text.StringBuilder();

    void HandleLine(string level, string? line)
    {
        if (string.IsNullOrWhiteSpace(line)) return;
        lock (output)
        {
            if (level == "stderr") error.AppendLine(line); else output.AppendLine(line);
        }
        var pm = Regex.Match(line, @"^\[PROGRESS\s+(\d{1,3})\]\s*(.*)$", RegexOptions.IgnoreCase);
        if (pm.Success && int.TryParse(pm.Groups[1].Value, out var pct))
        {
            logs.Progress(operationId, "استقرار", pct, pm.Groups[2].Value);
            return;
        }
        var sm = Regex.Match(line, @"^\[STAGE\s+([^\]]+)\]\s*(.*)$", RegexOptions.IgnoreCase);
        if (sm.Success)
        {
            logs.Progress(operationId, sm.Groups[1].Value, Math.Max(1, logs.Get(operationId)?.ProgressPercent ?? 1), sm.Groups[2].Value);
            return;
        }
        logs.Add(operationId, level, line);
    }

    process.OutputDataReceived += (_, e) => HandleLine("stdout", e.Data);
    process.ErrorDataReceived += (_, e) => HandleLine("stderr", e.Data);
    if (!process.Start()) throw new InvalidOperationException("Could not start PowerShell.");
    process.BeginOutputReadLine();
    process.BeginErrorReadLine();

    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(timeoutMs);
    try
    {
        await process.WaitForExitAsync(timeout.Token);
        process.WaitForExit();
        var outText = output.ToString();
        var errText = error.ToString();
        return new InstallerProcessResult(process.ExitCode, outText, string.IsNullOrWhiteSpace(errText) ? outText : errText);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
        try { process.Kill(true); } catch { }
        return new InstallerProcessResult(124, output.ToString(), $"PowerShell timed out after {TimeSpan.FromMilliseconds(timeoutMs)}. {error}");
    }
}

static JsonObject? LoadExistingAppSettings(string configPath)
{
    if (!File.Exists(configPath)) return null;
    try
    {
        return JsonNode.Parse(File.ReadAllText(configPath), documentOptions: new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        }) as JsonObject;
    }
    catch (JsonException) { return null; }
}

static string? ReadSavedMySqlPassword(JsonObject? existing)
{
    var mySql = existing?["Database"]?["MySql"];
    var password = mySql?["Password"]?.GetValue<string>();
    if (!string.IsNullOrEmpty(password)) return password;
    var connectionString = mySql?["ConnectionString"]?.GetValue<string>();
    var match = connectionString is null ? null : Regex.Match(connectionString, @"(?:^|;)\s*(?:Password|Pwd)\s*=\s*([^;]*)", RegexOptions.IgnoreCase);
    return match is { Success: true } ? match.Groups[1].Value : null;
}

// Database and Environment are owned by the installer (provider, migration policy, channel);
// every other section keeps what the operator already configured (sync master, SMS/AI keys, branch identity...).
static JsonObject MergeWithExistingAppSettings(JsonObject generated, JsonObject? existing)
{
    if (existing is null) return generated;
    foreach (var (key, value) in existing)
    {
        if (key is "Database" or "Environment" || value is null) continue;
        generated[key] = value.DeepClone();
    }
    return generated;
}

static object BuildAppSettings(bool isTest, SetupRequest request, string connectionString, bool isIMonitor)
{
    return new
    {
        Database = new
        {
            Type = "MySql",
            AutoMigrate = true,
            MigrateOnStartup = true,
            UseBackgroundMigration = false,
            EnsureCreatedIfNotExists = true,
            DropDatabaseOnStartup = false,
            SeedDataOnMigrate = true,
            CommandTimeout = 60,
            EnableSensitiveDataLogging = false,
            EnableDetailedErrors = false,
            RetryOnFailure = true,
            MaxRetryCount = 5,
            MaxRetryDelaySeconds = 30,
            MySql = new
            {
                Server = request.DatabaseServer,
                Port = request.DatabasePort,
                UserId = request.DatabaseUser,
                Password = request.DatabasePassword,
                Charset = "utf8mb4",
                ConnectionString = connectionString,
                Version = string.IsNullOrWhiteSpace(request.MySqlVersion) ? "8.0.0" : request.MySqlVersion,
                ConnectionIdleTimeout = 60
            }
        },
        Logging = new { LogLevel = new Dictionary<string, string> { ["Default"] = "Information", ["Microsoft"] = "Warning", ["Microsoft.AspNetCore"] = "Warning" } },
        GoodsSyncSettings = new { Enabled = false, InitialDelaySeconds = 240, IntervalSeconds = 300 },
        ExternalGoodsApi = new { Enabled = false, BaseUrl = "https://api.imonitor.ir" },
        BranchSettings = new { MasterServer = "", CompanyId = 1, MasterBranchId = isTest ? 11001 : 12001, BranchId = isTest ? 11002 : 12002, BranchName = isIMonitor ? (isTest ? "iMonitor ERP Test" : "iMonitor ERP Production") : (isTest ? "Posiran ERP Test" : "Posiran ERP Production"), BranchCode = isIMonitor ? (isTest ? "IMONITOR-TEST" : "IMONITOR-PROD") : (isTest ? "POSIRAN-TEST" : "POSIRAN-PROD"), IsHeadOffice = true, AutoSyncFromMaster = false, SyncIntervalSeconds = 15, AllowSwagger = isTest, SyncTimeoutSeconds = 60 },
        Environment = new { Name = isTest ? "Staging" : "Production", IsDevelopment = false, IsStaging = isTest, IsProduction = !isTest, EnableSyncDebug = false },
        SyncSettings = new { RetryCount = 10, RetryDelaySeconds = 30, BatchSize = 100, HealthCheckIntervalSeconds = 120, EnableDebugLog = false },
        AutoSync = new { Enabled = false, InitialDelaySeconds = 60, IdleIntervalSeconds = 60, ActiveIntervalSeconds = 120, ErrorRetrySeconds = 120, MaxRowsPerPull = 100, SyncDirection = "both", ShowToast = false },
        AI = new { Enabled = false, ApiKey = "", Model = "", MaxTokens = 1000, Temperature = 0.7, ApiUrl = "" },
        SMS = new { DefaultProvider = "ParsGreen", ParsGreen = new { ApiKey = "" } },
        Branding = isIMonitor ? new { ProductName = "iMonitor ERP", DisplayName = "iMonitor ERP", Website = "https://imonitor.ir/", SupportPhone = "", SupportEmail = "" } : new { ProductName = "Posiran ERP", DisplayName = "پوزایران ERP", Website = "https://www.posiran.ir/", SupportPhone = "0922-962-7005", SupportEmail = "" },
        TestDiagnostics = new { Enabled = false, AllowedHost = "", RootPath = "" },
        AllowedHosts = "*"
    };
}

static string? NormalizeChannel(string? channel)
{
    if (string.Equals(channel, "test", StringComparison.OrdinalIgnoreCase)) return "Test";
    if (string.Equals(channel, "production", StringComparison.OrdinalIgnoreCase)) return "Production";
    return null;
}

static string? ValidateDatabaseFields(SetupRequest request)
{
    if (string.IsNullOrWhiteSpace(request.DatabaseServer)) return "Database server is required.";
    if (request.DatabasePort is <= 0 or > 65535) return "Database port is invalid.";
    if (string.IsNullOrWhiteSpace(request.DatabaseUser)) return "Database user is required.";
    if (request.DatabasePassword is null) return "Database password is required.";
    if (string.IsNullOrWhiteSpace(request.DatabaseName)) return "Database name is required.";
    if (request.DatabaseName.Length > 64 || !Regex.IsMatch(request.DatabaseName, @"^[a-zA-Z0-9_]+$")) return "Database name may contain only letters, numbers, and underscore.";
    foreach (var value in new[] { request.DatabaseServer, request.DatabaseUser, request.DatabasePassword })
        if (value.Contains(';') || value.Contains('\r') || value.Contains('\n')) return "Semicolons/newlines are not supported in database fields.";
    if (!Regex.IsMatch(request.DatabaseServer, @"^[a-zA-Z0-9._:-]+$")) return "Database server contains unsupported characters.";
    return null;
}

static string ResolveInstallRoot(string? requested, string fallback)
{
    var value = string.IsNullOrWhiteSpace(requested) ? fallback : requested.Trim();
    if (!Path.IsPathRooted(value)) throw new InvalidOperationException("Install root must be an absolute path including drive letter.");
    var full = Path.GetFullPath(value);
    var root = Path.GetPathRoot(full);
    if (string.IsNullOrWhiteSpace(root) || root.Length < 3) throw new InvalidOperationException("Install root must include a valid Windows drive.");
    return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}

static string? ValidateFolderName(string? folderName)
{
    if (string.IsNullOrWhiteSpace(folderName)) return null;
    var value = folderName.Trim();
    if (value.Length > 80) return "Install folder name is too long.";
    if (value.Contains("..", StringComparison.Ordinal) || Regex.IsMatch(value, "[\\\\/:*?\"<>|]")) return "Install folder name contains unsupported characters.";
    return null;
}

static bool IsAdministrator()
{
    if (!OperatingSystem.IsWindows()) return false;
    try { using var identity = WindowsIdentity.GetCurrent(); return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator); }
    catch { return false; }
}

static bool MySqlServiceDetected()
{
    if (!OperatingSystem.IsWindows()) return false;
    try
    {
        var psi = new ProcessStartInfo { FileName = "sc.exe", Arguments = "query type= service state= all", RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
        using var p = Process.Start(psi);
        if (p is null) return false;
        var text = p.StandardOutput.ReadToEnd();
        p.WaitForExit(3000);
        return text.Contains("mysql", StringComparison.OrdinalIgnoreCase) || text.Contains("mariadb", StringComparison.OrdinalIgnoreCase);
    }
    catch { return false; }
}

record SetupRequest(string? Product, string Channel, string DatabaseServer, int DatabasePort, string DatabaseUser, string DatabasePassword, string DatabaseName, string? MySqlVersion, int? AppPort, string? InstallRoot, string? InstallFolderName, string? RuntimeUrl = null, bool AutoUpdate = true);
record InstallRequest(string? Product, string Channel, int? AppPort, string? InstallRoot, string? InstallFolderName, bool AutoUpdate = true, bool Force = false, bool RefreshInstaller = true);
record BackupRequest(string? Reason);
record VersionApprovalRequest(bool Approved);
record InstallerProcessResult(int ExitCode, string Output, string Error);

record WatchdogSettings(bool Enabled, string HealthUrl, int IntervalMinutes = 2, int AfterRestartDelayMinutes = 4, int TimeoutSeconds = 10, bool RestartOnFailure = true);

record RuntimeUrlUpdate(string RuntimeUrl);

record ChromiumPathRequest(string ExecutablePath);
