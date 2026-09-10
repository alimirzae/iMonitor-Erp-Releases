using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(builder.Configuration["Installer:Url"] ?? "http://127.0.0.1:8099");
builder.Services.AddHttpClient();

var app = builder.Build();
app.UseDefaultFiles();
app.UseStaticFiles();

const string releaseRepoRaw = "https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main";
var defaultInstallRoot = builder.Configuration["Installer:InstallRoot"] ?? @"C:\PosiranERP";
var defaultConfigRoot = builder.Configuration["Installer:ConfigRoot"] ?? @"C:\Deploy\PosiranERP";

app.MapGet("/api/status", () =>
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
        test = new { port = 8082, database = "posiran_test", configured = File.Exists(testConfig) },
        production = new { port = 8083, database = "posiran", configured = File.Exists(productionConfig) },
        prerequisites = new
        {
            iis = Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "inetsrv")),
            dotnet8 = Environment.Version.Major >= 8,
            mysqlServiceDetected = MySqlServiceDetected()
        }
    });
});

app.MapPost("/api/configure", (SetupRequest request) =>
{
    if (!OperatingSystem.IsWindows())
        return Results.BadRequest(new { error = "This MVP currently supports Windows only." });
    if (!IsAdministrator())
        return Results.BadRequest(new { error = "Run the installer service as Administrator." });

    var channel = NormalizeChannel(request.Channel);
    if (channel is null)
        return Results.BadRequest(new { error = "Channel must be Test or Production." });

    var validation = ValidateDatabaseFields(request);
    if (validation is not null)
        return Results.BadRequest(new { error = validation });

    var isTest = channel == "Test";
    var database = isTest ? "posiran_test" : "posiran";
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isTest ? 8082 : 8083);
    var configDirectory = Path.Combine(defaultConfigRoot, channel);
    var configPath = Path.Combine(configDirectory, "appsettings.json");
    Directory.CreateDirectory(configDirectory);

    var connectionString = $"Server={request.DatabaseServer};Port={request.DatabasePort};Database={database};User={request.DatabaseUser};Password={request.DatabasePassword};Charset=utf8mb4;";
    var config = BuildAppSettings(isTest, request, connectionString);
    var json = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
    File.WriteAllText(configPath, json);

    return Results.Ok(new
    {
        channel,
        database,
        appPort,
        configPath,
        message = "Configuration saved. Password is intentionally not returned by the API."
    });
});

app.MapPost("/api/install", async (InstallRequest request, IHttpClientFactory clients) =>
{
    if (!OperatingSystem.IsWindows())
        return Results.BadRequest(new { error = "This MVP currently supports Windows only." });
    if (!IsAdministrator())
        return Results.BadRequest(new { error = "Run the installer service as Administrator." });

    var channel = NormalizeChannel(request.Channel);
    if (channel is null)
        return Results.BadRequest(new { error = "Channel must be Test or Production." });

    var isTest = channel == "Test";
    var appPort = request.AppPort is > 0 and <= 65535 ? request.AppPort.Value : (isTest ? 8082 : 8083);
    var configPath = Path.Combine(defaultConfigRoot, channel, "appsettings.json");
    if (!File.Exists(configPath))
        return Results.BadRequest(new { error = $"Configure {channel} before installation." });

    var scriptDirectory = Path.Combine(defaultInstallRoot, "installer");
    Directory.CreateDirectory(scriptDirectory);
    var scriptPath = Path.Combine(scriptDirectory, "Install-PosiranERP-v1.0.2.ps1");

    if (!File.Exists(scriptPath) || request.RefreshInstaller)
    {
        var http = clients.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);
        var bytes = await http.GetByteArrayAsync($"{releaseRepoRaw}/scripts/Install-PosiranERP-v1.0.2.ps1");
        await File.WriteAllBytesAsync(scriptPath, bytes);
    }

    var psi = new ProcessStartInfo
    {
        FileName = "powershell.exe",
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        CreateNoWindow = true
    };
    psi.ArgumentList.Add("-NoProfile");
    psi.ArgumentList.Add("-ExecutionPolicy");
    psi.ArgumentList.Add("Bypass");
    psi.ArgumentList.Add("-File");
    psi.ArgumentList.Add(scriptPath);
    psi.ArgumentList.Add("-Channel");
    psi.ArgumentList.Add(channel);
    psi.ArgumentList.Add("-Mode");
    psi.ArgumentList.Add("InstallOrUpdate");
    psi.ArgumentList.Add("-InstallRoot");
    psi.ArgumentList.Add(defaultInstallRoot);
    psi.ArgumentList.Add("-ConfigRoot");
    psi.ArgumentList.Add(defaultConfigRoot);
    psi.ArgumentList.Add(isTest ? "-TestPort" : "-ProductionPort");
    psi.ArgumentList.Add(appPort.ToString());
    if (request.Force) psi.ArgumentList.Add("-Force");

    using var process = Process.Start(psi);
    if (process is null)
        return Results.Problem("Could not start Posiran installer process.");

    var outputTask = process.StandardOutput.ReadToEndAsync();
    var errorTask = process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();
    var output = await outputTask;
    var error = await errorTask;

    if (process.ExitCode != 0)
        return Results.Problem(title: "Installation failed", detail: string.IsNullOrWhiteSpace(error) ? output : error, statusCode: 500);

    return Results.Ok(new
    {
        channel,
        exitCode = process.ExitCode,
        localUrl = $"http://127.0.0.1:{appPort}/",
        output
    });
});

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "PosiranERP.Installer.Web" }));
app.MapFallbackToFile("index.html");
app.Run();

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
        Logging = new
        {
            LogLevel = new Dictionary<string, string>
            {
                ["Default"] = "Information",
                ["Microsoft"] = "Warning",
                ["Microsoft.AspNetCore"] = "Warning"
            }
        },
        GoodsSyncSettings = new { Enabled = false, InitialDelaySeconds = 240, IntervalSeconds = 300 },
        ExternalGoodsApi = new { Enabled = false, BaseUrl = "https://api.imonitor.ir" },
        BranchSettings = new
        {
            MasterServer = "",
            CompanyId = 1,
            MasterBranchId = isTest ? 11001 : 12001,
            BranchId = isTest ? 11002 : 12002,
            BranchName = isTest ? "Posiran ERP Test" : "Posiran ERP Production",
            BranchCode = isTest ? "POSIRAN-TEST" : "POSIRAN-PROD",
            IsHeadOffice = true,
            AutoSyncFromMaster = false,
            SyncIntervalSeconds = 15,
            AllowSwagger = isTest,
            SyncTimeoutSeconds = 60
        },
        Environment = new
        {
            Name = isTest ? "Staging" : "Production",
            IsDevelopment = false,
            IsStaging = isTest,
            IsProduction = !isTest,
            EnableSyncDebug = false
        },
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
        if (value.Contains(';') || value.Contains('\r') || value.Contains('\n')) return "Semicolons/newlines are not supported in database fields in this MVP.";
    if (!Regex.IsMatch(request.DatabaseServer, @"^[a-zA-Z0-9._:-]+$")) return "Database server contains unsupported characters.";
    return null;
}

static bool IsAdministrator()
{
    if (!OperatingSystem.IsWindows()) return false;
    try
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }
    catch { return false; }
}

static bool MySqlServiceDetected()
{
    if (!OperatingSystem.IsWindows()) return false;
    try
    {
        var psi = new ProcessStartInfo
        {
            FileName = "sc.exe",
            Arguments = "query type= service state= all",
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var p = Process.Start(psi);
        if (p is null) return false;
        var text = p.StandardOutput.ReadToEnd();
        p.WaitForExit(3000);
        return text.Contains("mysql", StringComparison.OrdinalIgnoreCase) || text.Contains("mariadb", StringComparison.OrdinalIgnoreCase);
    }
    catch { return false; }
}

record SetupRequest(
    string Channel,
    string DatabaseServer,
    int DatabasePort,
    string DatabaseUser,
    string DatabasePassword,
    string? MySqlVersion,
    int? AppPort);

record InstallRequest(string Channel, int? AppPort, bool Force = false, bool RefreshInstaller = true);
