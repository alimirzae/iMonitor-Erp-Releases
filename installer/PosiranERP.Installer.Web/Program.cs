using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(builder.Configuration["Installer:Url"] ?? "http://127.0.0.1:8099");
builder.Services.AddHttpClient();

var defaultInstallRoot = builder.Configuration["Installer:InstallRoot"] ?? @"C:\PosiranERP";
var defaultConfigRoot = builder.Configuration["Installer:ConfigRoot"] ?? @"C:\Deploy\PosiranERP";
builder.Services.AddSingleton<OrchestratorService>(sp => new OrchestratorService(defaultInstallRoot, defaultConfigRoot, sp.GetRequiredService<IHttpClientFactory>()));

var app = builder.Build();
app.UseDefaultFiles();
app.UseStaticFiles();

const string releaseRepoRaw = "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main";

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
        var scriptPath = Path.Combine(scriptDirectory, "Install-PosiranERP-v1.0.3.ps1");
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);
        var bytes = await http.GetByteArrayAsync($"{releaseRepoRaw}/scripts/Install-PosiranERP-v1.0.3.ps1?cb={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}", ct);
        await File.WriteAllBytesAsync(scriptPath, bytes, ct);
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
    var database = isTest ? "posiran_test" : "posiran";
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isTest ? 8082 : 8083);
    var installFolderName = string.IsNullOrWhiteSpace(request.InstallFolderName) ? (isTest ? "test" : "production") : request.InstallFolderName.Trim();
    var configDirectory = Path.Combine(defaultConfigRoot, channel);
    var configPath = Path.Combine(configDirectory, "appsettings.json");
    Directory.CreateDirectory(configDirectory);

    var connectionString = $"Server={request.DatabaseServer};Port={request.DatabasePort};Database={database};User={request.DatabaseUser};Password={request.DatabasePassword};Charset=utf8mb4;";
    var config = BuildAppSettings(isTest, request, connectionString);
    File.WriteAllText(configPath, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
    orchestrator.RegisterInstance(channel, appPort, installFolderName, request.AutoUpdate, configPath);

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
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isTest ? 8082 : 8083);
    var installFolderName = string.IsNullOrWhiteSpace(request.InstallFolderName) ? (isTest ? "test" : "production") : request.InstallFolderName.Trim();
    var configPath = Path.Combine(defaultConfigRoot, channel, "appsettings.json");
    if (!File.Exists(configPath)) return Results.BadRequest(new { error = $"Configure {channel} before installation." });

    var scriptDirectory = Path.Combine(defaultInstallRoot, "installer");
    Directory.CreateDirectory(scriptDirectory);
    var scriptPath = Path.Combine(scriptDirectory, "Install-PosiranERP-v1.0.3.ps1");

    if (!File.Exists(scriptPath) || request.RefreshInstaller)
    {
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);
        var bytes = await http.GetByteArrayAsync($"{releaseRepoRaw}/scripts/Install-PosiranERP-v1.0.3.ps1?cb={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
        await File.WriteAllBytesAsync(scriptPath, bytes);
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

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "PosiranERP.Installer.Web" }));
app.MapFallbackToFile("index.html");
app.Run();

static ProcessResult RunPowerShell(IEnumerable<string> args)
{
    var psi = new ProcessStartInfo { FileName = "powershell.exe", RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
    foreach (var arg in args) psi.ArgumentList.Add(arg);
    using var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start PowerShell.");
    var output = process.StandardOutput.ReadToEnd();
    var error = process.StandardError.ReadToEnd();
    process.WaitForExit();
    return new ProcessResult(process.ExitCode, output, string.IsNullOrWhiteSpace(error) ? output : error);
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
        BranchSettings = new { MasterServer = "", CompanyId = 1, MasterBranchId = isTest ? 11001 : 12001, BranchId = isTest ? 11002 : 12002, BranchName = isTest ? "Posiran ERP Test" : "Posiran ERP Production", BranchCode = isTest ? "POSIRAN-TEST" : "POSIRAN-PROD", IsHeadOffice = true, AutoSyncFromMaster = false, SyncIntervalSeconds = 15, AllowSwagger = isTest, SyncTimeoutSeconds = 60 },
        Environment = new { Name = isTest ? "Staging" : "Production", IsDevelopment = false, IsStaging = isTest, IsProduction = !isTest, EnableSyncDebug = false },
        SyncSettings = new { RetryCount = 10, RetryDelaySeconds = 30, BatchSize = 100, HealthCheckIntervalSeconds = 120, EnableDebugLog = false },
        AutoSync = new { Enabled = false, InitialDelaySeconds = 60, IdleIntervalSeconds = 60, ActiveIntervalSeconds = 120, ErrorRetrySeconds = 120, MaxRowsPerPull = 100, SyncDirection = "both", ShowToast = false },
        AI = new { Enabled = false, ApiKey = "", Model = "", MaxTokens = 1000, Temperature = 0.7, ApiUrl = "" },
        SMS = new { DefaultProvider = "ParsGreen", ParsGreen = new { ApiKey = "" } },
        Branding = new { ProductName = "Posiran ERP", DisplayName = "پوزایران ERP", Website = "https://www.posiran.ir/", SupportPhone = "0922-962-7005", SupportEmail = "" },
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

record SetupRequest(string Channel, string DatabaseServer, int DatabasePort, string DatabaseUser, string DatabasePassword, string? MySqlVersion, int? AppPort, string? InstallFolderName, bool AutoUpdate = true);
record InstallRequest(string Channel, int? AppPort, string? InstallFolderName, bool AutoUpdate = true, bool Force = false, bool RefreshInstaller = true);
record BackupRequest(string? Reason);
record ProcessResult(int ExitCode, string Output, string Error);
