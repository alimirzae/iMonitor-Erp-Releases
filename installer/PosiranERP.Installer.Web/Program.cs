using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseWindowsService(options => options.ServiceName = "ERP Deployment Manager");
builder.WebHost.UseUrls("http://127.0.0.1:8099");
builder.Services.AddHttpClient();
builder.Services.AddSingleton<OperationLogStore>();
builder.Services.AddHostedService<AutoUpdateWorker>();

var defaultInstallRoot = builder.Configuration["Installer:InstallRoot"] ?? @"C:\PosiranERP";
var defaultConfigRoot = builder.Configuration["Installer:ConfigRoot"] ?? @"C:\Deploy\PosiranERP";
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
        product = "Posiran ERP Installer",
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

app.MapGet("/api/installations", async (OrchestratorService orchestrator, CancellationToken ct) =>
    Results.Ok(await orchestrator.ListInstallationsAsync(ct)));
app.MapGet("/api/releases/{product}/{channel}", async (string product, string channel, OrchestratorService orchestrator, CancellationToken ct) =>
    Results.Ok(await orchestrator.ListReleasesAsync(product, channel, ct)));
app.MapGet("/api/history/{id}", (string id, OrchestratorService orchestrator) =>
    Results.Ok(orchestrator.GetVersionHistory(id)));
app.MapPost("/api/installations/{id}/install-version/{tag}", async (string id, string tag, OrchestratorService orchestrator, CancellationToken ct) =>
{
    try { return Results.Ok(await orchestrator.InstallVersionAsync(id, tag, ct)); }
    catch (Exception ex) { return Results.Problem(ex.Message); }
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

app.MapPost("/api/installations/{id}/upgrade", async (string id, OrchestratorService orchestrator, IHttpClientFactory clients, CancellationToken ct) =>
{
    try
    {
        var manifest = orchestrator.RequireManifest(id);
        var backup = await orchestrator.BackupAsync(id, "pre-upgrade", ct);
        var scriptDirectory = Path.Combine(defaultInstallRoot, "installer");
        Directory.CreateDirectory(scriptDirectory);
        var scriptPath = Path.Combine(scriptDirectory, "Install-PosiranERP-v1.0.5.ps1");
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);
        await DownloadInstallerScriptAsync(http, scriptPath, false, ct);
        var args = new List<string>
        {
            "-NoProfile","-ExecutionPolicy","Bypass","-File",scriptPath,
            "-Channel",manifest.Channel,"-Mode","InstallOrUpdate","-InstallRoot",defaultInstallRoot,"-ConfigRoot",defaultConfigRoot,
            manifest.Channel == "Test" ? "-TestPort" : "-ProductionPort",manifest.Port.ToString(),
            manifest.Channel == "Test" ? "-TestFolderName" : "-ProductionFolderName",manifest.InstallFolderName,
            "-Force"
        };
        if (!manifest.AutoUpdate) args.Add("-DisableAutoUpdate");
        var r = RunPowerShell(args);
        if (r.ExitCode != 0) return Results.Problem($"Upgrade failed. Pre-upgrade backup: {backup.BackupId}. {r.Error}");
        return Results.Ok(new { upgraded = true, preUpgradeBackup = backup.BackupId, output = r.Output });
    }
    catch (Exception ex) { return Results.Problem(ex.Message); }
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

    var connectionString = $"Server={request.DatabaseServer};Port={request.DatabasePort};Database={database};User={request.DatabaseUser};Password={request.DatabasePassword};Charset=utf8mb4;";
    var config = BuildAppSettings(isTest, request, connectionString, isIMonitor);
    File.WriteAllText(configPath, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
    orchestrator.RegisterInstance(request.Product ?? (isIMonitor ? "iMonitor" : "Posiran"), channel, installRoot, appPort, installFolderName, database, request.AutoUpdate, configPath);

    return Results.Ok(new
    {
        channel,
        database,
        appPort,
        installFolderName,
        autoUpdate = request.AutoUpdate,
        configPath,
        installPath = Path.Combine(installRoot, installFolderName, "current"),
        message = "Configuration saved and instance registered. Password is intentionally not returned by the API."
    });
});

app.MapPost("/api/install", async (InstallRequest request, IHttpClientFactory clients, OperationLogStore logs, CancellationToken requestCt) =>
{
    var op = logs.Start($"Install {request.Product} {request.Channel}");
    logs.Add(op.Id,"info","مرحله 1: اعتبارسنجی سیستم و تنظیمات");
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
    var scriptPath = Path.Combine(scriptDirectory, isIMonitor ? "Install-iMonitorERP-v2.1.5.ps1" : "Install-PosiranERP-v1.0.5.ps1");

    if (!File.Exists(scriptPath) || request.RefreshInstaller)
    {
        logs.Add(op.Id,"info",$"مرحله 2: بررسی اسکریپت نصاب در cache: {scriptPath}");
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(45);
        try { await DownloadInstallerScriptAsync(http, scriptPath, isIMonitor, requestCt); logs.Add(op.Id,"ok","اسکریپت نصاب دریافت/تأیید شد."); }
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
    if (!isIMonitor && !request.AutoUpdate) args.Add("-DisableAutoUpdate");
    if (request.Force) args.Add("-Force");
    logs.Add(op.Id,"info","مرحله 3: اجرای PowerShell. timeout کل: 30 دقیقه؛ خروجی پس از پایان/timeout در کنسول ثبت می‌شود.");
    var r = RunPowerShell(args, 30 * 60 * 1000);
    if(!string.IsNullOrWhiteSpace(r.Output)) logs.Add(op.Id,"stdout",r.Output);
    if(!string.IsNullOrWhiteSpace(r.Error) && r.Error != r.Output) logs.Add(op.Id,"stderr",r.Error);
    if (r.ExitCode != 0) { logs.Complete(op.Id,false,$"PowerShell exit code {r.ExitCode}: {r.Error}"); return Results.Problem(title: "Installation failed", detail: $"Operation {op.Id}: {r.Error}", statusCode: 500); }
    logs.Complete(op.Id,true,"نصب با موفقیت پایان یافت.");

    return Results.Ok(new
    {
        channel,
        exitCode = r.ExitCode,
        localUrl = $"http://127.0.0.1:{appPort}/",
        installPath = Path.Combine(installRoot, installFolderName, "current"),
        autoUpdate = request.AutoUpdate,
        operationId = op.Id,
        output = r.Output
    });
});

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "PosiranERP.Installer.Web" }));
app.MapFallbackToFile("index.html");
app.Run();

static async Task DownloadInstallerScriptAsync(HttpClient http, string destination, bool isIMonitor = false, CancellationToken cancellationToken = default)
{
    http.DefaultRequestHeaders.UserAgent.ParseAdd("PosiranERP-Setup/1.0");
    http.DefaultRequestHeaders.CacheControl = new() { NoCache = true, NoStore = true };
    var scriptUrl = isIMonitor ? "https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/imonitor-erp-installer-v2.1.5/Install-iMonitorERP-v2.1.5.ps1" : "https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/posiran-erp-installer-v1.0.5/Install-PosiranERP-v1.0.5.ps1";
    var bytes = await http.GetByteArrayAsync(scriptUrl, cancellationToken);
    var text = System.Text.Encoding.UTF8.GetString(bytes);
    if (!text.Contains("function Stop-ChannelHost", StringComparison.Ordinal) || !text.Contains("Get-WebAppPoolState", StringComparison.Ordinal))
        throw new InvalidOperationException("Downloaded Posiran installer asset failed the version contract.");
    await File.WriteAllBytesAsync(destination, bytes, cancellationToken);
    Console.WriteLine("Installer script downloaded from Posiran ERP installer release v1.0.5.");
}

static InstallerProcessResult RunPowerShell(IEnumerable<string> args, int timeoutMs = 30 * 60 * 1000)
{
    var psi = new ProcessStartInfo { FileName = "powershell.exe", RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
    foreach (var arg in args) psi.ArgumentList.Add(arg);
    using var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start PowerShell.");
    var output = process.StandardOutput.ReadToEnd();
    var error = process.StandardError.ReadToEnd();
    if (!process.WaitForExit(timeoutMs))
    {
        try { process.Kill(true); } catch { }
        return new InstallerProcessResult(124, output, $"PowerShell timed out after {TimeSpan.FromMilliseconds(timeoutMs)}. {error}");
    }
    return new InstallerProcessResult(process.ExitCode, output, string.IsNullOrWhiteSpace(error) ? output : error);
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

record SetupRequest(string? Product, string Channel, string DatabaseServer, int DatabasePort, string DatabaseUser, string DatabasePassword, string DatabaseName, string? MySqlVersion, int? AppPort, string? InstallRoot, string? InstallFolderName, bool AutoUpdate = true);
record InstallRequest(string? Product, string Channel, int? AppPort, string? InstallRoot, string? InstallFolderName, bool AutoUpdate = true, bool Force = false, bool RefreshInstaller = true);
record BackupRequest(string? Reason);
record InstallerProcessResult(int ExitCode, string Output, string Error);
