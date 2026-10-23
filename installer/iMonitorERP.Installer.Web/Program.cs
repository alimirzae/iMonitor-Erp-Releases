using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(builder.Configuration["Installer:Url"] ?? "http://127.0.0.1:8099");
builder.Services.AddHttpClient();
builder.Services.AddSingleton<OperationLogStore>();

var defaultInstallRoot = builder.Configuration["Installer:InstallRoot"] ?? @"C:\iMonitorERP";
var defaultConfigRoot = builder.Configuration["Installer:ConfigRoot"] ?? @"C:\Deploy\iMonitorERP";
builder.Services.AddSingleton<OrchestratorService>(sp => new OrchestratorService(defaultInstallRoot, defaultConfigRoot, sp.GetRequiredService<IHttpClientFactory>()));

var app = builder.Build();
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
        product = "iMonitor ERP Installer",
        url = "http://127.0.0.1:8099",
        isWindows,
        isAdministrator = isAdmin,
        test = new { port = 8081, database = "ecomm_dev", folder = "test", configured = File.Exists(testConfig) },
        production = new { port = 8080, database = "ecomm", folder = "production", configured = File.Exists(productionConfig) },
        prerequisites = new
        {
            iis = Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "inetsrv")),
            dotnet8 = Environment.Version.Major >= 8,
            mysqlServiceDetected = MySqlServiceDetected(),
            mysqlServices = orchestrator.ListMySqlServices()
        }
    });
});

// Optional audio codec setup for Piper TTS; WAV fallback works without this tool.
app.MapGet("/api/tools/ffmpeg", () =>
{
    var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "AiBOS", "Tools", "FFmpeg", "ffmpeg.exe");
    return Results.Ok(new { installed = File.Exists(executable), path = executable });
});

app.MapPost("/api/tools/ffmpeg/install", async (HttpContext context) =>
{
    if (!OperatingSystem.IsWindows() || !IsAdministrator())
        return Results.BadRequest(new { error = "Windows Administrator privileges are required." });
    if (context.Request.Headers.Origin is { Count: > 0 } origin &&
        (!Uri.TryCreate(origin.ToString(), UriKind.Absolute, out var uri) ||
         uri.Host != context.Request.Host.Host || uri.Port != context.Request.Host.Port))
        return Results.StatusCode(403);

    var destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "AiBOS", "Tools", "FFmpeg", "ffmpeg.exe");
    if (File.Exists(destination)) return Results.Ok(new { installed = true, path = destination });

    // winget is the controlled installer provider; arbitrary client URLs or commands are forbidden.
    // Windows Server without winget must use a manually provisioned vetted FFmpeg executable.
    var winget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Microsoft", "WindowsApps", "winget.exe");
    if (!File.Exists(winget))
        return Results.Problem("Windows Package Manager (winget) is not installed. Use the managed FFmpeg provisioning option.",
            statusCode: 409);
    var psi = new ProcessStartInfo(winget)
    {
        UseShellExecute = false, CreateNoWindow = true,
        RedirectStandardOutput = false, RedirectStandardError = false
    };
    foreach (var arg in new[] { "install", "--id", "Gyan.FFmpeg", "--exact",
                                "--accept-source-agreements", "--accept-package-agreements",
                                "--silent", "--disable-interactivity" })
        psi.ArgumentList.Add(arg);
    using var process = Process.Start(psi);
    if (process is null) return Results.Problem("Could not start winget.", statusCode: 500);
    using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
    try { await process.WaitForExitAsync(timeout.Token); }
    catch (OperationCanceledException)
    {
        try { process.Kill(entireProcessTree: true); } catch { }
        return Results.Problem("FFmpeg installation timed out.", statusCode: 504);
    }
    if (process.ExitCode != 0)
        return Results.Problem("FFmpeg package installation failed with code " + process.ExitCode, statusCode: 500);

    // Winget normally installs a versioned folder; copy the executable to the stable AiBOS path.
    var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Microsoft", "WinGet", "Packages");
    var candidate = Directory.Exists(packages)
        ? Directory.EnumerateFiles(packages, "ffmpeg.exe", SearchOption.AllDirectories)
            .FirstOrDefault(p => p.Contains("Gyan.FFmpeg", StringComparison.OrdinalIgnoreCase))
        : null;
    if (candidate is null)
        return Results.Problem("FFmpeg installed but its executable was not located. Configure Tts:FfmpegPath.", statusCode: 409);
    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
    File.Copy(candidate, destination, overwrite: true);
    return Results.Ok(new { installed = true, path = destination, restartRecommended = true });
});

app.MapGet("/api/installations", async (OrchestratorService orchestrator, CancellationToken ct) =>
    Results.Ok(await orchestrator.ListInstallationsAsync(ct)));

app.MapGet("/api/operations", (OperationLogStore logs) => Results.Ok(logs.Recent()));
app.MapGet("/api/operations/{id}", (string id, OperationLogStore logs) =>
{
    var state = logs.Get(id);
    return state is null ? Results.NotFound() : Results.Ok(state);
});

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

app.MapPost("/api/installations/{id}/upgrade", (string id, OrchestratorService orchestrator, IHttpClientFactory clients, OperationLogStore logs) =>
{
    var existing = logs.Recent().FirstOrDefault(x =>
        string.Equals(x.Status, "Running", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(x.Title, $"Upgrade {id}", StringComparison.OrdinalIgnoreCase));
    if (existing is not null)
        return Results.Accepted($"/api/operations/{existing.Id}", new
        {
            operationId = existing.Id,
            status = existing.Status,
            stage = existing.Stage,
            progressPercent = existing.ProgressPercent,
            message = "ارتقای این نصب از قبل در حال اجرا است."
        });

    InstallationManifest manifest;
    try
    {
        manifest = orchestrator.RequireManifest(id);
    }
    catch (Exception ex)
    {
        return Results.Problem(title: "Upgrade request rejected", detail: ex.Message, statusCode: 404);
    }

    var op = logs.Start($"Upgrade {id}");
    logs.Progress(op.Id, "آماده‌سازی", 1, $"درخواست ارتقای {manifest.DisplayName} پذیرفته شد.");

    _ = Task.Run(async () =>
    {
        try
        {
            logs.Progress(op.Id, "پشتیبان‌گیری", 4, "ایجاد Backup قبل از ارتقا");
            var backup = await orchestrator.BackupAsync(id, "pre-upgrade", CancellationToken.None);
            logs.Progress(op.Id, "پشتیبان‌گیری", 10, $"Backup آماده شد: {backup.BackupId}");

            var scriptDirectory = Path.Combine(defaultInstallRoot, "installer");
            Directory.CreateDirectory(scriptDirectory);
            var scriptPath = Path.Combine(scriptDirectory, "Install-iMonitorERP-v2.1.6.ps1");
            logs.Progress(op.Id, "نصاب", 12, "بررسی و دریافت آخرین اسکریپت نصب");
            var http = clients.CreateClient();
            http.Timeout = TimeSpan.FromSeconds(60);
            await DownloadInstallerScriptAsync(http, scriptPath, CancellationToken.None);
            logs.Progress(op.Id, "نصاب", 16, "اسکریپت نصب آماده است");

            var args = new List<string>
            {
                "-NoProfile","-ExecutionPolicy","Bypass","-File",scriptPath,
                "-Channel",manifest.Channel,"-Mode","InstallOrUpdate","-InstallRoot",defaultInstallRoot,"-ConfigRoot",defaultConfigRoot,
                manifest.Channel == "Test" ? "-TestPort" : "-ProductionPort",manifest.Port.ToString(),
                manifest.Channel == "Test" ? "-TestFolderName" : "-ProductionFolderName",manifest.InstallFolderName,
                "-Force"
            };

            logs.Progress(op.Id, "استقرار", 20, "اجرای Installer؛ خروجی و مراحل به‌صورت زنده ثبت می‌شوند");
            var run = await RunPowerShellAsync(args, 30 * 60 * 1000, logs, op.Id, CancellationToken.None);
            if (run.ExitCode != 0)
            {
                logs.Complete(op.Id, false, $"PowerShell exit code {run.ExitCode}. Backup: {backup.BackupId}. {run.Error}");
                return;
            }

            logs.Progress(op.Id, "Health Check", 95, $"کنترل وضعیت HTTP، IIS و دیتابیس روی پورت {manifest.Port}");
            var statuses = await orchestrator.ListInstallationsAsync(CancellationToken.None);
            var active = statuses.FirstOrDefault(x => string.Equals(x.Id, id, StringComparison.OrdinalIgnoreCase));
            if (active is null)
            {
                logs.Complete(op.Id, false, "ارتقا اجرا شد اما وضعیت نصب در Deployment Manager پیدا نشد.");
                return;
            }

            if (!active.HealthOk || !active.DatabaseReachable)
            {
                logs.Complete(op.Id, false,
                    $"ارتقا پایان یافت اما Health Check موفق نبود. HTTP: {active.HealthMessage}; DB: {active.DatabaseMessage}");
                return;
            }

            logs.Progress(op.Id, "تکمیل", 100, $"نسخه {active.InstalledVersion ?? "جدید"} سالم و در دسترس است.");
            logs.Complete(op.Id, true,
                $"ارتقا با موفقیت انجام شد. Backup: {backup.BackupId}. HTTP و دیتابیس سالم هستند.");
        }
        catch (Exception ex)
        {
            logs.Complete(op.Id, false, ex.Message);
        }
    });

    return Results.Accepted($"/api/operations/{op.Id}", new
    {
        operationId = op.Id,
        status = "Running",
        stage = "آماده‌سازی",
        progressPercent = 1,
        message = "عملیات ارتقا در سرویس 8099 شروع شد."
    });
});

// Load persisted per-channel form values after service restarts; never return database credentials.
// Installer-only, non-secret UI preferences, including external health URLs.
var preferencesPath = Path.Combine(defaultConfigRoot, "installer-preferences.json");
app.MapGet("/api/preferences", () =>
{
    if (!File.Exists(preferencesPath)) return Results.Ok(new InstallerPreferences("", "", ""));
    try { return Results.Ok(JsonSerializer.Deserialize<InstallerPreferences>(File.ReadAllText(preferencesPath)) ?? new("", "", "")); }
    catch { return Results.Problem("Saved installer preferences could not be read.", statusCode: 500); }
});
app.MapPost("/api/preferences", (InstallerPreferences preferences, HttpContext context) =>
{
    if (!OperatingSystem.IsWindows() || !IsAdministrator()) return Results.StatusCode(403);
    if (context.Request.Headers.Origin is { Count: > 0 } origin &&
        (!Uri.TryCreate(origin.ToString(), UriKind.Absolute, out var source) ||
         !string.Equals(source.Host, context.Request.Host.Host, StringComparison.OrdinalIgnoreCase) ||
         source.Port != context.Request.Host.Port)) return Results.StatusCode(403);
    foreach (var url in new[] { preferences.TestUrl, preferences.ProductionUrl })
        if (!string.IsNullOrWhiteSpace(url) && (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) ||
            (parsed.Scheme != "http" && parsed.Scheme != "https") || !string.IsNullOrEmpty(parsed.UserInfo)))
            return Results.BadRequest(new { error = "URL must be a valid HTTP or HTTPS address." });
    Directory.CreateDirectory(defaultConfigRoot);
    var temp = preferencesPath + ".tmp";
    File.WriteAllText(temp, JsonSerializer.Serialize(preferences));
    File.Move(temp, preferencesPath, overwrite: true);
    return Results.Ok(new { saved = true });
});

app.MapGet("/api/configuration", (OrchestratorService orchestrator) =>
{
    var result = new Dictionary<string, object>();
    foreach (var channel in new[] { "Test", "Production" })
    {
        var path = Path.Combine(defaultConfigRoot, channel, "appsettings.json");
        if (!File.Exists(path)) continue;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            var mysql = root.GetProperty("Database").GetProperty("MySql");
            var manifest = orchestrator.RequireManifest(channel.ToLowerInvariant());
            result[channel] = new
            {
                appPort = manifest.Port,
                installFolderName = manifest.InstallFolderName,
                databaseName = manifest.DatabaseName,
                autoUpdate = manifest.AutoUpdate,
                databaseServer = mysql.GetProperty("Server").GetString(),
                databasePort = mysql.GetProperty("Port").GetInt32(),
                databaseUser = mysql.GetProperty("UserId").GetString(),
                mysqlVersion = mysql.GetProperty("Version").GetString(),
                hasSavedPassword = !string.IsNullOrEmpty(mysql.GetProperty("Password").GetString())
            };
        }
        catch (Exception ex) { Console.Error.WriteLine($"Cannot restore {channel} installer settings: {ex.Message}"); }
    }
    return Results.Ok(result);
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
    var database = request.DatabaseName.Trim();
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isTest ? 8081 : 8080);
    var installFolderName = string.IsNullOrWhiteSpace(request.InstallFolderName) ? (isTest ? "test" : "production") : request.InstallFolderName.Trim();
    var configDirectory = Path.Combine(defaultConfigRoot, channel);
    var configPath = Path.Combine(configDirectory, "appsettings.json");
    Directory.CreateDirectory(configDirectory);

    // Blank password means keep the existing secret when editing previously saved settings.
    var databasePassword = request.DatabasePassword;
    if (string.IsNullOrEmpty(databasePassword) && File.Exists(configPath))
    {
        try
        {
            using var previous = JsonDocument.Parse(File.ReadAllText(configPath));
            databasePassword = previous.RootElement.GetProperty("Database").GetProperty("MySql")
                .GetProperty("Password").GetString() ?? "";
        }
        catch (Exception ex) { return Results.BadRequest(new { error = "Cannot read saved database credentials: " + ex.Message }); }
    }
    request = request with { DatabasePassword = databasePassword };
    var connectionString = $"Server={request.DatabaseServer};Port={request.DatabasePort};Database={database};User={request.DatabaseUser};Password={request.DatabasePassword};Charset=utf8mb4;";
    var config = BuildAppSettings(isTest, request, connectionString);
    File.WriteAllText(configPath, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
    orchestrator.RegisterInstance(channel, appPort, installFolderName, database, request.AutoUpdate, configPath);

    return Results.Ok(new
    {
        channel,
        database,
        appPort,
        installFolderName,
        autoUpdate = request.AutoUpdate,
        configPath,
        installPath = Path.Combine(defaultInstallRoot, installFolderName, "current"),
        message = "Configuration saved and instance registered. Password is intentionally not returned by the API."
    });
});

app.MapPost("/api/install", async (InstallRequest request, IHttpClientFactory clients) =>
{
    if (!OperatingSystem.IsWindows()) return Results.BadRequest(new { error = "This installer currently supports Windows only." });
    if (!IsAdministrator()) return Results.BadRequest(new { error = "Run the installer service as Administrator." });

    var channel = NormalizeChannel(request.Channel);
    if (channel is null) return Results.BadRequest(new { error = "Channel must be Test or Production." });
    var folderValidation = ValidateFolderName(request.InstallFolderName);
    if (folderValidation is not null) return Results.BadRequest(new { error = folderValidation });

    var isTest = channel == "Test";
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isTest ? 8081 : 8080);
    var installFolderName = string.IsNullOrWhiteSpace(request.InstallFolderName) ? (isTest ? "test" : "production") : request.InstallFolderName.Trim();
    var configPath = Path.Combine(defaultConfigRoot, channel, "appsettings.json");
    if (!File.Exists(configPath)) return Results.BadRequest(new { error = $"Configure {channel} before installation." });

    var scriptDirectory = Path.Combine(defaultInstallRoot, "installer");
    Directory.CreateDirectory(scriptDirectory);
    var scriptPath = Path.Combine(scriptDirectory, "Install-iMonitorERP-v2.1.6.ps1");

    if (!File.Exists(scriptPath) || request.RefreshInstaller)
    {
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);
        await DownloadInstallerScriptAsync(http, scriptPath);
    }

    var args = new List<string>
    {
        "-NoProfile","-ExecutionPolicy","Bypass","-File",scriptPath,
        "-Channel",channel,"-Mode","InstallOrUpdate","-InstallRoot",defaultInstallRoot,"-ConfigRoot",defaultConfigRoot,
        isTest ? "-TestPort" : "-ProductionPort",appPort.ToString(),
        isTest ? "-TestFolderName" : "-ProductionFolderName",installFolderName
    };
    if (!request.AutoUpdate) args.Add("-DisableAutoUpdate");
    if (request.Force) args.Add("-Force");
    var r = RunPowerShell(args);
    if (r.ExitCode != 0) return Results.Problem(title: "Installation failed", detail: r.Error, statusCode: 500);

    return Results.Ok(new
    {
        channel,
        exitCode = r.ExitCode,
        localUrl = $"http://127.0.0.1:{appPort}/",
        installPath = Path.Combine(defaultInstallRoot, installFolderName, "current"),
        autoUpdate = request.AutoUpdate,
        output = r.Output
    });
});

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "iMonitorERP.Installer.Web" }));
app.MapFallbackToFile("index.html");
app.Run();

static async Task DownloadInstallerScriptAsync(HttpClient http, string destination, CancellationToken cancellationToken = default)
{
    http.DefaultRequestHeaders.UserAgent.ParseAdd("iMonitorERP-Setup/1.0");
    http.DefaultRequestHeaders.CacheControl = new() { NoCache = true, NoStore = true };
    var scriptUrl = "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/43d1f2e1c66d82a6f3e98ecef2937ebe773c089c/scripts/Install-iMonitorERP-v2.1.6.ps1";
    var bytes = await http.GetByteArrayAsync(scriptUrl, cancellationToken);
    var text = System.Text.Encoding.UTF8.GetString(bytes);
    if (!text.Contains("function Stop-ChannelHost", StringComparison.Ordinal) || !text.Contains("Get-WebAppPoolState", StringComparison.Ordinal))
        throw new InvalidOperationException("Downloaded Posiran installer asset failed the version contract.");
    await File.WriteAllBytesAsync(destination, bytes, cancellationToken);
    Console.WriteLine("Installer script downloaded from iMonitor ERP installer release v2.1.6.");
}

static InstallerProcessResult RunPowerShell(IEnumerable<string> args)
{
    var psi = new ProcessStartInfo { FileName = "powershell.exe", RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
    foreach (var arg in args) psi.ArgumentList.Add(arg);
    using var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start PowerShell.");
    var output = process.StandardOutput.ReadToEnd();
    var error = process.StandardError.ReadToEnd();
    process.WaitForExit();
    return new InstallerProcessResult(process.ExitCode, output, string.IsNullOrWhiteSpace(error) ? output : error);
}

static async Task<InstallerProcessResult> RunPowerShellAsync(
    IEnumerable<string> args,
    int timeoutMs,
    OperationLogStore logs,
    string operationId,
    CancellationToken cancellationToken)
{
    var psi = new ProcessStartInfo
    {
        FileName = "powershell.exe",
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        CreateNoWindow = true
    };
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

        var progress = Regex.Match(line, @"^\[PROGRESS\s+(\d{1,3})\]\s*(.*)$", RegexOptions.IgnoreCase);
        if (progress.Success && int.TryParse(progress.Groups[1].Value, out var pct))
        {
            logs.Progress(operationId, "استقرار", pct, progress.Groups[2].Value);
            return;
        }

        var stage = Regex.Match(line, @"^\[STAGE\s+([^\]]+)\]\s*(.*)$", RegexOptions.IgnoreCase);
        if (stage.Success)
        {
            logs.Progress(operationId, stage.Groups[1].Value,
                Math.Max(1, logs.Get(operationId)?.ProgressPercent ?? 1),
                stage.Groups[2].Value);
            return;
        }

        logs.Add(operationId, level, line);
    }

    process.OutputDataReceived += (_, e) => HandleLine("stdout", e.Data);
    process.ErrorDataReceived += (_, e) => HandleLine("stderr", e.Data);

    if (!process.Start())
        throw new InvalidOperationException("Could not start PowerShell.");

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
        return new InstallerProcessResult(process.ExitCode, outText,
            string.IsNullOrWhiteSpace(errText) ? outText : errText);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
        try { process.Kill(true); } catch { }
        return new InstallerProcessResult(124, output.ToString(),
            $"PowerShell timed out after {TimeSpan.FromMilliseconds(timeoutMs)}. {error}");
    }
}

static object BuildAppSettings(bool isTest, SetupRequest request, string connectionString)
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
        BranchSettings = new { MasterServer = "", CompanyId = 1, MasterBranchId = isTest ? 11001 : 12001, BranchId = isTest ? 11002 : 12002, BranchName = isTest ? "iMonitor ERP Test" : "iMonitor ERP Production", BranchCode = isTest ? "IMONITOR-TEST" : "IMONITOR-PROD", IsHeadOffice = true, AutoSyncFromMaster = false, SyncIntervalSeconds = 15, AllowSwagger = isTest, SyncTimeoutSeconds = 60 },
        Environment = new { Name = isTest ? "Staging" : "Production", IsDevelopment = false, IsStaging = isTest, IsProduction = !isTest, EnableSyncDebug = false },
        SyncSettings = new { RetryCount = 10, RetryDelaySeconds = 30, BatchSize = 100, HealthCheckIntervalSeconds = 120, EnableDebugLog = false },
        AutoSync = new { Enabled = false, InitialDelaySeconds = 60, IdleIntervalSeconds = 60, ActiveIntervalSeconds = 120, ErrorRetrySeconds = 120, MaxRowsPerPull = 100, SyncDirection = "both", ShowToast = false },
        AI = new { Enabled = false, ApiKey = "", Model = "", MaxTokens = 1000, Temperature = 0.7, ApiUrl = "" },
        SMS = new { DefaultProvider = "ParsGreen", ParsGreen = new { ApiKey = "" } },
        Branding = new { ProductName = "iMonitor ERP", DisplayName = "پوزایران ERP", Website = "https://www.ecomm.ir/", SupportPhone = "", SupportEmail = "" },
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

record SetupRequest(string Channel, string DatabaseServer, int DatabasePort, string DatabaseUser, string DatabasePassword, string DatabaseName, string? MySqlVersion, int? AppPort, string? InstallFolderName, bool AutoUpdate = true);
record InstallRequest(string Channel, int? AppPort, string? InstallFolderName, bool AutoUpdate = true, bool Force = false, bool RefreshInstaller = true);
record BackupRequest(string? Reason);
record InstallerProcessResult(int ExitCode, string Output, string Error);

record InstallerPreferences(string TestUrl, string ProductionUrl, string LanIp);
