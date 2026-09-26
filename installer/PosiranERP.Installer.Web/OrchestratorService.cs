using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

public sealed class OrchestratorService
{
    private readonly string _installRoot;
    private readonly string _configRoot;
    private readonly string _registryRoot;
    private readonly string _stateRoot;
    private readonly IHttpClientFactory _clients;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private const string ReleaseRepoApi = "https://api.github.com/repos/alimirzae/iMonitor-Erp-Releases/releases?per_page=100";

    public OrchestratorService(string installRoot, string configRoot, IHttpClientFactory clients)
    {
        _installRoot = installRoot;
        _configRoot = configRoot;
        _clients = clients;
        _stateRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "iMonitor", "ERPDeploymentManager");
        _registryRoot = Path.Combine(_stateRoot, "instances");
        Directory.CreateDirectory(_registryRoot);
    }

    public async Task<IReadOnlyList<InstallationStatus>> ListInstallationsAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var manifests = LoadManifests().ToDictionary(x => x.Id, StringComparer.OrdinalIgnoreCase);
            DiscoverLegacyInstances(manifests);
            var latest = await GetLatestReleasesAsync(cancellationToken);
            var result = new List<InstallationStatus>();
            foreach (var m in manifests.Values.OrderBy(x => x.Product).ThenBy(x => x.Channel).ThenBy(x => x.DisplayName))
            {
                var installed = ReadInstalledRelease(m);
                var health = await CheckHealthAsync(m.Port, cancellationToken);
                var iis = GetIisState(m.IisSite, m.AppPool);
                var db = CheckDatabase(m.ConfigPath);
                var latestTag = latest.TryGetValue($"{m.Product}:{m.Channel}", out var tag) ? tag : null;
                result.Add(new InstallationStatus(
                    m.Id, m.DisplayName, m.Product, m.Channel, m.InstallRoot, m.Port, m.InstallFolderName, m.InstallPath,
                    m.ConfigPath, m.DatabaseName, installed, latestTag,
                    !string.IsNullOrWhiteSpace(latestTag) && !string.Equals(installed, latestTag, StringComparison.OrdinalIgnoreCase),
                    m.AutoUpdate, Directory.Exists(m.InstallPath), File.Exists(m.ConfigPath),
                    iis.SiteState, iis.PoolState, health.Ok, health.Message,
                    db.Reachable, db.Message, GetBackupSummaries(m.Id)));
            }
            return result;
        }
        finally { _gate.Release(); }
    }

    public async Task<IReadOnlyList<ReleaseInfo>> ListReleasesAsync(string product, string channel, CancellationToken cancellationToken = default)
    {
        var normalizedProduct = NormalizeProduct(product);
        var normalizedChannel = NormalizeChannel(channel) ?? throw new InvalidOperationException("Invalid channel.");
        var prefix = normalizedProduct == "Posiran"
            ? (normalizedChannel == "Test" ? "posiran-erp-test-v" : "posiran-erp-production-v")
            : (normalizedChannel == "Test" ? "imonitor-ecomerp-test-v" : "imonitor-ecomerp-master-v");
        var http = _clients.CreateClient();
        http.DefaultRequestHeaders.UserAgent.ParseAdd("ERPDeploymentManager/1.0");
        http.Timeout = TimeSpan.FromSeconds(20);
        HttpResponseMessage? response = null;
        try { response = await http.GetAsync(ReleaseRepoApi + "&cb=" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), cancellationToken); }
        catch { }
        if (response is null || !response.IsSuccessStatusCode)
        {
            response?.Dispose();
            var latest = await GetStaticLatestAsync(normalizedProduct, normalizedChannel, cancellationToken);
            return latest is null ? Array.Empty<ReleaseInfo>() : new[] { new ReleaseInfo(latest, DateTime.UtcNow, Array.Empty<string>(), !IsFailedRelease(normalizedProduct, normalizedChannel, latest)) };
        }
        using var ownedResponse = response;
        using var doc = JsonDocument.Parse(await ownedResponse.Content.ReadAsStringAsync(cancellationToken));
        var result = new List<ReleaseInfo>();
        foreach (var e in doc.RootElement.EnumerateArray())
        {
            var tag = e.GetProperty("tag_name").GetString();
            if (string.IsNullOrWhiteSpace(tag) || !tag.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            var published = e.TryGetProperty("published_at", out var p) && p.ValueKind == JsonValueKind.String
                ? p.GetDateTimeOffset().UtcDateTime
                : DateTime.MinValue;
            var assets = e.TryGetProperty("assets", out var a) && a.ValueKind == JsonValueKind.Array
                ? a.EnumerateArray().Select(x => x.GetProperty("name").GetString() ?? "").Where(x => x.Length > 0).ToArray()
                : Array.Empty<string>();
            result.Add(new ReleaseInfo(tag, published, assets, !IsFailedRelease(normalizedProduct, normalizedChannel, tag)));
        }
        return result.OrderByDescending(x => x.PublishedAtUtc).ToArray();
    }

    public IReadOnlyList<VersionHealthRecord> GetVersionHistory(string id)
    {
        ValidateInstanceId(id);
        var path = HistoryPath(id);
        if (!File.Exists(path)) return Array.Empty<VersionHealthRecord>();
        try { return JsonSerializer.Deserialize<List<VersionHealthRecord>>(File.ReadAllText(path), JsonOptions) ?? new List<VersionHealthRecord>(); }
        catch { return Array.Empty<VersionHealthRecord>(); }
    }

    public async Task<VersionOperationResult> InstallVersionAsync(string id, string tag, CancellationToken cancellationToken = default)
    {
        var m = RequireManifest(id);
        ValidateReleaseTagForManifest(m, tag);
        var backup = Directory.Exists(m.InstallPath) && File.Exists(m.ConfigPath)
            ? await BackupAsync(id, $"pre-version:{tag}", cancellationToken)
            : null;
        try
        {
            var assetName = m.Product == "Posiran" ? "PosiranERP-win-x64.zip" : "iMonitor-EcomERP-win-x64.zip";
            var releaseUrl = $"https://github.com/alimirzae/iMonitor-Erp-Releases/releases/download/{tag}/{assetName}";
            var shaUrl = releaseUrl + ".sha256";
            var packageDir = Path.Combine(m.InstallRoot, "packages", tag);
            Directory.CreateDirectory(packageDir);
            var zip = Path.Combine(packageDir, assetName);
            var shaFile = zip + ".sha256";
            var http = _clients.CreateClient();
            http.DefaultRequestHeaders.UserAgent.ParseAdd("ERPDeploymentManager/1.1");
            http.Timeout = TimeSpan.FromMinutes(3);

            // Offline-first: a manually copied/cached package is authoritative when its checksum is present and valid.
            string? expected = null;
            if (File.Exists(shaFile))
            {
                expected = File.ReadAllText(shaFile).Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant();
                if (!string.IsNullOrWhiteSpace(expected) && File.Exists(zip) && string.Equals(Hash(zip), expected, StringComparison.OrdinalIgnoreCase))
                {
                    // Valid local cache: do not touch the network.
                }
                else expected = null;
            }
            if (expected is null)
            {
                await DownloadWithFallbackAsync(http, shaUrl, shaFile, cancellationToken);
                expected = File.ReadAllText(shaFile).Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)[0].ToLowerInvariant();
            }
            if (!File.Exists(zip) || !string.Equals(Hash(zip), expected, StringComparison.OrdinalIgnoreCase))
                await DownloadWithFallbackAsync(http, releaseUrl, zip, cancellationToken);
            var actual = Hash(zip);
            if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Package checksum mismatch.");

            var stage = Path.Combine(m.InstallRoot, m.InstallFolderName, "stage", tag);
            if (Directory.Exists(stage)) Directory.Delete(stage, true);
            Directory.CreateDirectory(stage);
            System.IO.Compression.ZipFile.ExtractToDirectory(zip, stage, true);

            StopInstance(m);
            var current = m.InstallPath;
            var rollbackDir = Path.Combine(m.InstallRoot, m.InstallFolderName, "rollback-current");
            if (Directory.Exists(rollbackDir)) Directory.Delete(rollbackDir, true);
            if (Directory.Exists(current)) Directory.Move(current, rollbackDir);
            try
            {
                Directory.Move(stage, current);
                StartInstance(m);
                var health = await WaitForHealthAsync(m.Port, cancellationToken);
                if (!health.Ok) throw new InvalidOperationException("Health check failed after version activation: " + health.Message);
                File.WriteAllText(Path.Combine(m.InstallRoot, m.InstallFolderName, "installed-release.txt"), tag);
                AppendHistory(m.Id, new VersionHealthRecord(tag, DateTime.UtcNow, "Healthy", health.Message, backup?.BackupId, actual));
                if (Directory.Exists(rollbackDir)) Directory.Delete(rollbackDir, true);
                return new VersionOperationResult(tag, true, "Healthy", health.Message, backup?.BackupId);
            }
            catch
            {
                try { StopInstance(m); } catch { }
                try { if (Directory.Exists(current)) Directory.Delete(current, true); } catch { }
                if (Directory.Exists(rollbackDir)) Directory.Move(rollbackDir, current);
                try { StartInstance(m); } catch { }
                throw;
            }
        }
        catch (Exception ex)
        {
            AppendHistory(m.Id, new VersionHealthRecord(tag, DateTime.UtcNow, "Failed", ex.Message, backup?.BackupId, null));
            throw;
        }
    }

    public async Task<VersionOperationResult> RollbackToVersionAsync(string id, string tag, CancellationToken cancellationToken = default)
    {
        var m = RequireManifest(id);
        var record = GetVersionHistory(id)
            .Where(x => string.Equals(x.Tag, tag, StringComparison.OrdinalIgnoreCase) && x.Status == "Healthy")
            .OrderByDescending(x => x.CheckedAtUtc).FirstOrDefault();
        if (record is null) throw new InvalidOperationException("Requested version is not recorded as Healthy.");
        var result = await InstallVersionAsync(id, tag, cancellationToken);
        if (!string.IsNullOrWhiteSpace(record.BackupId))
            await RestoreAsync(id, record.BackupId, cancellationToken);
        return result with { Message = "Rollback completed to previously healthy version." };
    }

    public async Task RunAutoUpdateCycleAsync(CancellationToken cancellationToken)
    {
        foreach (var m in LoadManifests().Where(x => x.AutoUpdate))
        {
            try
            {
                var releases = await ListReleasesAsync(m.Product, m.Channel, cancellationToken);
                var latest = releases.FirstOrDefault(x => x.Eligible);
                if (latest is null) continue;
                var installed = ReadInstalledRelease(m);
                if (string.Equals(installed, latest.Tag, StringComparison.OrdinalIgnoreCase)) continue;
                await InstallVersionAsync(m.Id, latest.Tag, cancellationToken);
            }
            catch { }
        }
    }

    private string HistoryPath(string id)
    {
        var dir = Path.Combine(_stateRoot, "history");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, id + ".json");
    }

    private void AppendHistory(string id, VersionHealthRecord record)
    {
        var list = GetVersionHistory(id).ToList();
        list.Insert(0, record);
        if (list.Count > 100) list = list.Take(100).ToList();
        File.WriteAllText(HistoryPath(id), JsonSerializer.Serialize(list, JsonOptions));
    }

    private bool IsFailedRelease(string product, string channel, string tag)
        => LoadManifests().Where(x => x.Product == product && x.Channel == channel)
            .SelectMany(x => GetVersionHistory(x.Id))
            .Any(x => string.Equals(x.Tag, tag, StringComparison.OrdinalIgnoreCase) && x.Status == "Failed");

    private static void ValidateReleaseTagForManifest(InstallationManifest m, string tag)
    {
        var prefix = m.Product == "Posiran"
            ? (m.Channel == "Test" ? "posiran-erp-test-v" : "posiran-erp-production-v")
            : (m.Channel == "Test" ? "imonitor-ecomerp-test-v" : "imonitor-ecomerp-master-v");
        if (!tag.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Release tag does not belong to this product/channel.");
    }

    private static async Task DownloadWithFallbackAsync(HttpClient http, string url, string destination, CancellationToken ct)
    {
        var errors = new List<string>();
        // Route 1: .NET HTTPS. Each attempt has a hard bound; no server may hang the manager for hours.
        for (var attempt=1; attempt<=2; attempt++)
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(TimeSpan.FromMinutes(3));
                using var r = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                r.EnsureSuccessStatusCode();
                var temp = destination + ".part";
                await using (var src = await r.Content.ReadAsStreamAsync(timeout.Token))
                await using (var dst = File.Create(temp))
                    await src.CopyToAsync(dst, timeout.Token);
                File.Move(temp, destination, true);
                return;
            }
            catch(Exception ex) { errors.Add($"HTTP attempt {attempt}: {ex.Message}"); }
        }

        // Route 2: Windows curl forced to IPv4 + HTTP/1.1, useful on hosts with broken IPv6/TLS routing.
        if (OperatingSystem.IsWindows())
        {
            try
            {
                var temp = destination + ".part";
                var r = RunProcess("curl.exe", new[] { "-4","--http1.1","--tlsv1.2","-fL","--retry","2","--retry-delay","2","--connect-timeout","15","--max-time","600",url,"-o",temp }, 11 * 60 * 1000);
                if (r.ExitCode == 0 && File.Exists(temp)) { File.Move(temp,destination,true); return; }
                errors.Add("curl IPv4: " + (string.IsNullOrWhiteSpace(r.StdErr) ? r.StdOut : r.StdErr));
            }
            catch(Exception ex) { errors.Add("curl IPv4: " + ex.Message); }
        }
        throw new InvalidOperationException("All download routes failed. You can manually copy the release file into the package cache. " + string.Join(" | ", errors));
    }

    private static string Hash(string path)
        => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();

    public IReadOnlyList<MySqlServiceStatus> ListMySqlServices()
    {
        if (!OperatingSystem.IsWindows()) return Array.Empty<MySqlServiceStatus>();
        try
        {
            var script = "Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'mysql|mariadb' -or $_.DisplayName -match 'mysql|mariadb' } | Select-Object Name,DisplayName,State,StartMode,PathName | ConvertTo-Json -Compress";
            var r = RunProcess("powershell.exe", new[] { "-NoProfile", "-Command", script }, 15000);
            if (r.ExitCode != 0 || string.IsNullOrWhiteSpace(r.StdOut)) return Array.Empty<MySqlServiceStatus>();
            using var doc = JsonDocument.Parse(r.StdOut);
            var list = new List<MySqlServiceStatus>();
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var e in doc.RootElement.EnumerateArray()) list.Add(ParseMySqlService(e));
            }
            else if (doc.RootElement.ValueKind == JsonValueKind.Object) list.Add(ParseMySqlService(doc.RootElement));
            return list;
        }
        catch { return Array.Empty<MySqlServiceStatus>(); }
    }

    public InstallationManifest RegisterInstance(string product, string channel, string installRoot, int port, string folderName, string database, bool autoUpdate, string configPath)
    {
        channel = NormalizeChannel(channel) ?? throw new InvalidOperationException("Invalid channel.");
        var normalizedProduct = NormalizeProduct(product);
        var id = $"{normalizedProduct.ToLowerInvariant()}-{channel.ToLowerInvariant()}";
        var now = DateTime.UtcNow;
        var existing = LoadManifest(id);
        var isPosiran = normalizedProduct == "Posiran";
        var site = isPosiran
            ? (channel == "Test" ? "PosiranERP-Test" : "PosiranERP-Production")
            : (channel == "Test" ? "iMonitorERP-Test" : "iMonitorERP-Production");
        var manifest = new InstallationManifest(
            id,
            $"{normalizedProduct} ERP {channel}",
            normalizedProduct,
            channel,
            Path.GetFullPath(installRoot),
            port,
            folderName,
            Path.Combine(Path.GetFullPath(installRoot), folderName, "current"),
            configPath,
            database,
            site,
            site,
            autoUpdate,
            existing?.CreatedAtUtc ?? now,
            now);
        SaveManifest(manifest);
        return manifest;
    }

    public async Task<BackupResult> BackupAsync(string id, string? reason = null, CancellationToken cancellationToken = default)
    {
        var m = RequireManifest(id);
        var cfg = ReadDbConfig(m.ConfigPath);
        var dumpExe = FindMySqlTool("mysqldump.exe", "mysqldump");
        if (dumpExe is null) throw new InvalidOperationException("mysqldump was not found. Install MySQL client tools or configure MySQL correctly.");
        var mysqlExe = FindMySqlTool("mysql.exe", "mysql");
        if (mysqlExe is null) throw new InvalidOperationException("mysql client was not found.");

        var stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
        var backupId = $"{stamp}-{Guid.NewGuid():N}"[..24];
        var dir = Path.Combine(m.InstallRoot, m.InstallFolderName, "backups", backupId);
        Directory.CreateDirectory(dir);
        var databases = new List<DatabaseTarget> { new(cfg.Server, cfg.Port, cfg.User, cfg.Password, m.DatabaseName, "application") };
        databases.AddRange(DiscoverBookDatabases(mysqlExe, cfg, m.DatabaseName));
        databases = databases.GroupBy(x => $"{x.Server}:{x.Port}/{x.Database}", StringComparer.OrdinalIgnoreCase).Select(x => x.First()).ToList();

        var files = new List<BackupFile>();
        try
        {
            foreach (var db in databases)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var safeName = Regex.Replace(db.Database, "[^a-zA-Z0-9_.-]", "_");
                var outFile = Path.Combine(dir, $"{db.Kind}-{safeName}.sql");
                using var defaults = TemporaryMySqlDefaults(db);
                var args = new List<string>
                {
                    $"--defaults-extra-file={defaults.Path}", "--single-transaction", "--routines", "--triggers", "--events",
                    "--hex-blob", "--set-gtid-purged=OFF", "--default-character-set=utf8mb4", "--databases", db.Database
                };
                var r = RunProcessToFile(dumpExe, args, outFile, 15 * 60 * 1000);
                if (r.ExitCode != 0) throw new InvalidOperationException($"Backup failed for database {db.Database}: {SanitizeProcessError(r.StdErr)}");
                var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(outFile))).ToLowerInvariant();
                files.Add(new BackupFile(db.Kind, db.Database, Path.GetFileName(outFile), hash, new FileInfo(outFile).Length));
            }
            var meta = new BackupMetadata(backupId, m.Id, DateTime.UtcNow, reason ?? "manual", files);
            File.WriteAllText(Path.Combine(dir, "backup.json"), JsonSerializer.Serialize(meta, JsonOptions));
            return new BackupResult(backupId, dir, files.Count, files.Sum(x => x.SizeBytes));
        }
        catch
        {
            try { File.WriteAllText(Path.Combine(dir, "FAILED.txt"), $"Backup failed at {DateTime.UtcNow:O}"); } catch { }
            throw;
        }
    }

    public async Task<RestoreResult> RestoreAsync(string id, string backupId, CancellationToken cancellationToken = default)
    {
        var m = RequireManifest(id);
        ValidateBackupId(backupId);
        var dir = Path.Combine(m.InstallRoot, m.InstallFolderName, "backups", backupId);
        var metaPath = Path.Combine(dir, "backup.json");
        if (!File.Exists(metaPath)) throw new FileNotFoundException("Managed backup metadata was not found.");
        var meta = JsonSerializer.Deserialize<BackupMetadata>(File.ReadAllText(metaPath), JsonOptions) ?? throw new InvalidOperationException("Backup metadata is invalid.");
        if (!string.Equals(meta.InstanceId, m.Id, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Backup belongs to another instance.");

        var preRestore = await BackupAsync(id, $"pre-restore:{backupId}", cancellationToken);
        StopInstance(m);
        try
        {
            var cfg = ReadDbConfig(m.ConfigPath);
            var mysqlExe = FindMySqlTool("mysql.exe", "mysql") ?? throw new InvalidOperationException("mysql client was not found.");
            foreach (var f in meta.Files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var file = Path.GetFullPath(Path.Combine(dir, f.FileName));
                if (!file.StartsWith(Path.GetFullPath(dir) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(file))
                    throw new InvalidOperationException("Backup file path is invalid.");
                var actual = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(file))).ToLowerInvariant();
                if (!string.Equals(actual, f.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException($"Checksum mismatch for {f.FileName}.");
                var target = f.Kind == "application"
                    ? new DatabaseTarget(cfg.Server, cfg.Port, cfg.User, cfg.Password, f.Database, f.Kind)
                    : ResolveBookTarget(mysqlExe, cfg, m.DatabaseName, f.Database) ?? new DatabaseTarget(cfg.Server, cfg.Port, cfg.User, cfg.Password, f.Database, f.Kind);
                using var defaults = TemporaryMySqlDefaults(target);
                var r = RunProcessWithInput(mysqlExe, new[] { $"--defaults-extra-file={defaults.Path}", "--default-character-set=utf8mb4" }, file, 15 * 60 * 1000);
                if (r.ExitCode != 0) throw new InvalidOperationException($"Restore failed for {f.Database}: {SanitizeProcessError(r.StdErr)}");
            }
        }
        finally { StartInstance(m); }

        var health = await WaitForHealthAsync(m.Port, cancellationToken);
        if (!health.Ok) throw new InvalidOperationException($"Restore completed but ERP health failed. Pre-restore backup: {preRestore.BackupId}. {health.Message}");
        return new RestoreResult(backupId, preRestore.BackupId, true, health.Message);
    }

    public async Task<OperationResult> ControlAsync(string id, string action, CancellationToken cancellationToken = default)
    {
        var m = RequireManifest(id);
        action = action.ToLowerInvariant();
        if (action == "stop") StopInstance(m);
        else if (action == "start") StartInstance(m);
        else if (action == "restart") { StopInstance(m); await Task.Delay(1000, cancellationToken); StartInstance(m); }
        else throw new InvalidOperationException("Action must be start, stop or restart.");
        var health = action == "stop" ? new HealthResult(false, "Stopped by administrator") : await WaitForHealthAsync(m.Port, cancellationToken);
        return new OperationResult(action, health.Ok, health.Message);
    }

    public InstallationManifest RequireManifest(string id) => LoadManifest(id) ?? throw new KeyNotFoundException("Installation was not found in the local registry.");

    public IReadOnlyList<BackupSummary> GetBackupSummaries(string id)
    {
        var m = LoadManifest(id);
        if (m is null) return Array.Empty<BackupSummary>();
        var root = Path.Combine(m.InstallRoot, m.InstallFolderName, "backups");
        if (!Directory.Exists(root)) return Array.Empty<BackupSummary>();
        var result = new List<BackupSummary>();
        foreach (var dir in Directory.EnumerateDirectories(root).OrderByDescending(x => x).Take(20))
        {
            try
            {
                var p = Path.Combine(dir, "backup.json");
                if (!File.Exists(p)) continue;
                var x = JsonSerializer.Deserialize<BackupMetadata>(File.ReadAllText(p), JsonOptions);
                if (x is not null) result.Add(new BackupSummary(x.BackupId, x.CreatedAtUtc, x.Reason, x.Files.Count, x.Files.Sum(f => f.SizeBytes)));
            }
            catch { }
        }
        return result;
    }

    private IEnumerable<InstallationManifest> LoadManifests()
    {
        if (!Directory.Exists(_registryRoot)) yield break;
        foreach (var f in Directory.EnumerateFiles(_registryRoot, "*.json"))
        {
            InstallationManifest? m = null;
            try { m = JsonSerializer.Deserialize<InstallationManifest>(File.ReadAllText(f), JsonOptions); } catch { }
            if (m is not null) yield return m;
        }
    }

    private InstallationManifest? LoadManifest(string id)
    {
        ValidateInstanceId(id);
        var p = Path.Combine(_registryRoot, id + ".json");
        if (!File.Exists(p)) return null;
        return JsonSerializer.Deserialize<InstallationManifest>(File.ReadAllText(p), JsonOptions);
    }

    private void SaveManifest(InstallationManifest manifest)
    {
        ValidateInstanceId(manifest.Id);
        Directory.CreateDirectory(_registryRoot);
        var p = Path.Combine(_registryRoot, manifest.Id + ".json");
        var tmp = p + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(manifest, JsonOptions));
        File.Move(tmp, p, true);
    }

    private void DiscoverLegacyInstances(IDictionary<string, InstallationManifest> manifests)
    {
        foreach (var channel in new[] { "Test", "Production" })
        {
            var id = "posiran-" + channel.ToLowerInvariant();
            if (manifests.ContainsKey(id)) continue;
            var folder = channel == "Test" ? "test" : "production";
            var root = Path.Combine(_installRoot, folder, "current");
            var cfg = Path.Combine(_configRoot, channel, "appsettings.json");
            if (!Directory.Exists(root) && !File.Exists(cfg)) continue;
            manifests[id] = new InstallationManifest(
                id,
                channel == "Test" ? "Posiran ERP Test" : "Posiran ERP Production",
                "Posiran",
                channel,
                _installRoot,
                channel == "Test" ? 8082 : 8083,
                folder,
                root,
                cfg,
                channel == "Test" ? "posiran_test" : "posiran",
                channel == "Test" ? "PosiranERP-Test" : "PosiranERP-Production",
                channel == "Test" ? "PosiranERP-Test" : "PosiranERP-Production",
                ScheduledTaskExists(channel == "Test" ? "PosiranERP-Update-Test" : "PosiranERP-Update-Production"),
                DateTime.UtcNow,
                DateTime.UtcNow);
        }
    }

    private async Task<string?> GetStaticLatestAsync(string product, string channel, CancellationToken cancellationToken)
    {
        var p = product.Equals("Posiran", StringComparison.OrdinalIgnoreCase) ? "posiran" : "imonitor";
        var ch = p == "imonitor" ? (channel.Equals("Test", StringComparison.OrdinalIgnoreCase) ? "test" : "master")
                                : (channel.Equals("Test", StringComparison.OrdinalIgnoreCase) ? "test" : "production");
        var url = $"https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/channels/{p}/{ch}/latest.json?cb={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}";
        try
        {
            var http = _clients.CreateClient(); http.Timeout = TimeSpan.FromSeconds(15);
            http.DefaultRequestHeaders.UserAgent.ParseAdd("ERPDeploymentManager/1.1");
            using var r = await http.GetAsync(url, cancellationToken);
            if (!r.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await r.Content.ReadAsStringAsync(cancellationToken));
            return doc.RootElement.TryGetProperty("tag", out var t) ? t.GetString() : null;
        }
        catch { return null; }
    }

    private async Task<Dictionary<string, string>> GetLatestReleasesAsync(CancellationToken cancellationToken)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in new[] { ("Posiran","Test"), ("Posiran","Production"), ("iMonitor","Test"), ("iMonitor","Production") })
        {
            var tag = await GetStaticLatestAsync(item.Item1, item.Item2, cancellationToken);
            if (!string.IsNullOrWhiteSpace(tag)) result[$"{item.Item1}:{item.Item2}"] = tag;
        }
        if (result.Count == 4) return result;
        try
        {
            var http = _clients.CreateClient(); http.DefaultRequestHeaders.UserAgent.ParseAdd("ERPDeploymentManager/1.1"); http.Timeout = TimeSpan.FromSeconds(15);
            using var response = await http.GetAsync(ReleaseRepoApi + "&cb=" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), cancellationToken);
            if (!response.IsSuccessStatusCode) return result;
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            foreach (var x in doc.RootElement.EnumerateArray())
            {
                var tag=x.GetProperty("tag_name").GetString(); if(string.IsNullOrWhiteSpace(tag)) continue;
                if(tag.StartsWith("posiran-erp-test-v",StringComparison.OrdinalIgnoreCase)&&!result.ContainsKey("Posiran:Test"))result["Posiran:Test"]=tag;
                if(tag.StartsWith("posiran-erp-production-v",StringComparison.OrdinalIgnoreCase)&&!result.ContainsKey("Posiran:Production"))result["Posiran:Production"]=tag;
                if(tag.StartsWith("imonitor-ecomerp-test-v",StringComparison.OrdinalIgnoreCase)&&!result.ContainsKey("iMonitor:Test"))result["iMonitor:Test"]=tag;
                if(tag.StartsWith("imonitor-ecomerp-master-v",StringComparison.OrdinalIgnoreCase)&&!result.ContainsKey("iMonitor:Production"))result["iMonitor:Production"]=tag;
            }
        } catch { }
        return result;
    }

    private string? ReadInstalledRelease(InstallationManifest m)
    {
        var state = Path.Combine(m.InstallRoot, m.InstallFolderName, "installed-release.txt");
        try { return File.Exists(state) ? File.ReadAllText(state).Trim() : null; } catch { return null; }
    }

    private async Task<HealthResult> CheckHealthAsync(int port, CancellationToken cancellationToken)
    {
        try
        {
            var http = _clients.CreateClient();
            http.Timeout = TimeSpan.FromSeconds(4);
            using var r = await http.GetAsync($"http://127.0.0.1:{port}/health", cancellationToken);
            return new HealthResult(r.IsSuccessStatusCode, $"HTTP {(int)r.StatusCode}");
        }
        catch (Exception ex) { return new HealthResult(false, ex.GetType().Name); }
    }

    private async Task<HealthResult> WaitForHealthAsync(int port, CancellationToken cancellationToken)
    {
        HealthResult last = new(false, "Not checked");
        for (var i = 0; i < 15; i++)
        {
            await Task.Delay(1500, cancellationToken);
            last = await CheckHealthAsync(port, cancellationToken);
            if (last.Ok) return last;
        }
        return last;
    }

    private (string SiteState, string PoolState) GetIisState(string site, string pool)
    {
        if (!OperatingSystem.IsWindows()) return ("Unsupported", "Unsupported");
        try
        {
            var script = $"Import-Module WebAdministration; $s=(Get-Website -Name '{Ps(site)}' -ErrorAction SilentlyContinue).State; $p=(Get-WebAppPoolState -Name '{Ps(pool)}' -ErrorAction SilentlyContinue).Value; Write-Output (($s ?? 'Missing').ToString()+'|'+($p ?? 'Missing').ToString())";
            var r = RunProcess("powershell.exe", new[] { "-NoProfile", "-Command", script }, 10000);
            var parts = r.StdOut.Trim().Split('|');
            return parts.Length >= 2 ? (parts[0], parts[1]) : ("Unknown", "Unknown");
        }
        catch { return ("Unknown", "Unknown"); }
    }

    private DbCheckResult CheckDatabase(string configPath)
    {
        try
        {
            var cfg = ReadDbConfig(configPath);
            var mysql = FindMySqlTool("mysql.exe", "mysql");
            if (mysql is null) return new DbCheckResult(false, "mysql client not found");
            using var defaults = TemporaryMySqlDefaults(new DatabaseTarget(cfg.Server, cfg.Port, cfg.User, cfg.Password, cfg.Database, "application"));
            var r = RunProcess(mysql, new[] { $"--defaults-extra-file={defaults.Path}", "--batch", "--skip-column-names", "-e", "SELECT 1" }, 8000);
            return new DbCheckResult(r.ExitCode == 0 && r.StdOut.Contains('1'), r.ExitCode == 0 ? "OK" : SanitizeProcessError(r.StdErr));
        }
        catch (Exception ex) { return new DbCheckResult(false, ex.Message); }
    }

    private List<DatabaseTarget> DiscoverBookDatabases(string mysqlExe, DbConfig cfg, string appDatabase)
    {
        var result = new List<DatabaseTarget>();
        try
        {
            using var defaults = TemporaryMySqlDefaults(new DatabaseTarget(cfg.Server, cfg.Port, cfg.User, cfg.Password, appDatabase, "application"));
            var sql = $"SELECT ConnectionString FROM `{EscapeIdentifier(appDatabase)}`.`books` WHERE IsDeleted=0 AND IsActive=1";
            var r = RunProcess(mysqlExe, new[] { $"--defaults-extra-file={defaults.Path}", "--batch", "--skip-column-names", "-e", sql }, 15000);
            if (r.ExitCode != 0) return result;

            // The books table can contain stale/default rows such as book_0. Never let a
            // non-existent tenant database abort the whole application upgrade backup.
            var dbList = RunProcess(mysqlExe, new[] { $"--defaults-extra-file={defaults.Path}", "--batch", "--skip-column-names", "-e", "SHOW DATABASES" }, 15000);
            var existingDatabases = dbList.ExitCode == 0
                ? dbList.StdOut.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(x => x.Trim())
                    .ToHashSet(StringComparer.OrdinalIgnoreCase)
                : new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var line in r.StdOut.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var parsed = ParseConnectionString(line.Trim(), cfg);
                if (string.IsNullOrWhiteSpace(parsed.Database) ||
                    string.Equals(parsed.Database, "book_0", StringComparison.OrdinalIgnoreCase))
                    continue;

                // If SHOW DATABASES succeeded, only back up book databases that really exist.
                if (existingDatabases.Count > 0 && !existingDatabases.Contains(parsed.Database))
                    continue;

                result.Add(new DatabaseTarget(parsed.Server, parsed.Port, parsed.User, parsed.Password, parsed.Database, "book"));
            }
        }
        catch { }
        return result;
    }

    private DatabaseTarget? ResolveBookTarget(string mysqlExe, DbConfig cfg, string appDatabase, string wantedDatabase)
        => DiscoverBookDatabases(mysqlExe, cfg, appDatabase).FirstOrDefault(x => string.Equals(x.Database, wantedDatabase, StringComparison.OrdinalIgnoreCase));

    private DbConfig ReadDbConfig(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Instance configuration was not found.", path);
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var mysql = doc.RootElement.GetProperty("Database").GetProperty("MySql");
        var server = mysql.TryGetProperty("Server", out var s) ? s.GetString() : null;
        var port = mysql.TryGetProperty("Port", out var p) ? p.GetInt32() : 3306;
        var user = mysql.TryGetProperty("UserId", out var u) ? u.GetString() : null;
        var password = mysql.TryGetProperty("Password", out var pw) ? pw.GetString() : null;
        var cs = mysql.TryGetProperty("ConnectionString", out var c) ? c.GetString() : null;
        var parsed = ParseConnectionString(cs ?? "", new DbConfig(server ?? "127.0.0.1", port, user ?? "root", password ?? "", ""));
        return parsed;
    }

    private static DbConfig ParseConnectionString(string cs, DbConfig fallback)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var part in cs.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var i = part.IndexOf('=');
            if (i <= 0) continue;
            values[part[..i].Trim()] = part[(i + 1)..].Trim();
        }
        string Get(string[] keys, string fallbackValue)
        {
            foreach (var k in keys) if (values.TryGetValue(k, out var v) && !string.IsNullOrWhiteSpace(v)) return v;
            return fallbackValue;
        }
        var portText = Get(new[] { "Port" }, fallback.Port.ToString());
        _ = int.TryParse(portText, out var port);
        return new DbConfig(
            Get(new[] { "Server", "Host", "Data Source" }, fallback.Server),
            port is > 0 and <= 65535 ? port : fallback.Port,
            Get(new[] { "User", "User Id", "Uid", "Username" }, fallback.User),
            Get(new[] { "Password", "Pwd" }, fallback.Password),
            Get(new[] { "Database", "Initial Catalog" }, fallback.Database));
    }

    private static TemporaryFile TemporaryMySqlDefaults(DatabaseTarget db)
    {
        var path = Path.Combine(Path.GetTempPath(), "posiran-mysql-" + Guid.NewGuid().ToString("N") + ".cnf");
        var body = $"[client]\nhost={Ini(db.Server)}\nport={db.Port}\nuser={Ini(db.User)}\npassword={Ini(db.Password)}\ndefault-character-set=utf8mb4\n";
        File.WriteAllText(path, body, new UTF8Encoding(false));
        try { File.SetAttributes(path, FileAttributes.Hidden | FileAttributes.Temporary); } catch { }
        return new TemporaryFile(path);
    }

    private static string? FindMySqlTool(string windowsName, string unixName)
    {
        var candidates = new List<string>();
        if (OperatingSystem.IsWindows())
        {
            foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) })
            {
                if (string.IsNullOrWhiteSpace(root)) continue;
                var mysqlRoot = Path.Combine(root, "MySQL");
                if (Directory.Exists(mysqlRoot)) candidates.AddRange(Directory.EnumerateFiles(mysqlRoot, windowsName, SearchOption.AllDirectories));
                var mariaRoot = Path.Combine(root, "MariaDB");
                if (Directory.Exists(mariaRoot)) candidates.AddRange(Directory.EnumerateFiles(mariaRoot, windowsName, SearchOption.AllDirectories));
            }
            candidates.Add(windowsName);
        }
        else candidates.Add(unixName);
        foreach (var c in candidates)
        {
            try
            {
                var r = RunProcess(c, new[] { "--version" }, 5000);
                if (r.ExitCode == 0) return c;
            }
            catch { }
        }
        return null;
    }

    private void StopInstance(InstallationManifest m) => InvokeIisControl(m, false);
    private void StartInstance(InstallationManifest m) => InvokeIisControl(m, true);

    private static void InvokeIisControl(InstallationManifest m, bool start)
    {
        var verb = start ? "Start" : "Stop";
        var script = $"Import-Module WebAdministration; if(Test-Path 'IIS:\\Sites\\{Ps(m.IisSite)}'){{{verb}-Website -Name '{Ps(m.IisSite)}' -ErrorAction SilentlyContinue}}; if(Test-Path 'IIS:\\AppPools\\{Ps(m.AppPool)}'){{{verb}-WebAppPool -Name '{Ps(m.AppPool)}' -ErrorAction SilentlyContinue}}";
        var r = RunProcess("powershell.exe", new[] { "-NoProfile", "-Command", script }, 15000);
        if (r.ExitCode != 0) throw new InvalidOperationException($"IIS {verb.ToLowerInvariant()} failed: {SanitizeProcessError(r.StdErr)}");
    }

    private static bool ScheduledTaskExists(string taskName)
    {
        if (!OperatingSystem.IsWindows()) return false;
        try { return RunProcess("schtasks.exe", new[] { "/Query", "/TN", taskName }, 5000).ExitCode == 0; } catch { return false; }
    }

    private static MySqlServiceStatus ParseMySqlService(JsonElement e)
        => new(e.TryGetProperty("Name", out var n) ? n.GetString() ?? "" : "",
            e.TryGetProperty("DisplayName", out var d) ? d.GetString() ?? "" : "",
            e.TryGetProperty("State", out var s) ? s.GetString() ?? "Unknown" : "Unknown",
            e.TryGetProperty("StartMode", out var m) ? m.GetString() ?? "Unknown" : "Unknown",
            e.TryGetProperty("PathName", out var p) ? p.GetString() ?? "" : "");

    private static ProcessResult RunProcess(string file, IEnumerable<string> args, int timeoutMs)
    {
        var psi = NewPsi(file, args);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"Could not start {file}.");
        var o = p.StandardOutput.ReadToEndAsync();
        var e = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } throw new TimeoutException($"{Path.GetFileName(file)} timed out."); }
        Task.WaitAll(o, e);
        return new ProcessResult(p.ExitCode, o.Result, e.Result);
    }

    private static ProcessResult RunProcessToFile(string file, IEnumerable<string> args, string outputFile, int timeoutMs)
    {
        var psi = NewPsi(file, args);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"Could not start {file}.");
        var err = p.StandardError.ReadToEndAsync();
        using (var fs = File.Create(outputFile)) p.StandardOutput.BaseStream.CopyTo(fs);
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } throw new TimeoutException($"{Path.GetFileName(file)} timed out."); }
        err.Wait();
        return new ProcessResult(p.ExitCode, "", err.Result);
    }

    private static ProcessResult RunProcessWithInput(string file, IEnumerable<string> args, string inputFile, int timeoutMs)
    {
        var psi = NewPsi(file, args);
        psi.RedirectStandardInput = true;
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"Could not start {file}.");
        var o = p.StandardOutput.ReadToEndAsync();
        var e = p.StandardError.ReadToEndAsync();
        using (var fs = File.OpenRead(inputFile)) { fs.CopyTo(p.StandardInput.BaseStream); p.StandardInput.Close(); }
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } throw new TimeoutException($"{Path.GetFileName(file)} timed out."); }
        Task.WaitAll(o, e);
        return new ProcessResult(p.ExitCode, o.Result, e.Result);
    }

    private static ProcessStartInfo NewPsi(string file, IEnumerable<string> args)
    {
        var psi = new ProcessStartInfo { FileName = file, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return psi;
    }

    private static string SanitizeProcessError(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "No diagnostic output.";
        text = Regex.Replace(text, @"(?i)(password|pwd)\s*[=:]\s*[^\s;]+", "$1=***");
        return text.Length > 1200 ? text[..1200] : text.Trim();
    }

    private static string NormalizeProduct(string? product)
    {
        if (string.Equals(product, "posiran", StringComparison.OrdinalIgnoreCase)) return "Posiran";
        if (string.Equals(product, "imonitor", StringComparison.OrdinalIgnoreCase)) return "iMonitor";
        throw new InvalidOperationException("Product must be Posiran or iMonitor.");
    }

    private static string? NormalizeChannel(string? channel)
    {
        if (string.Equals(channel, "test", StringComparison.OrdinalIgnoreCase)) return "Test";
        if (string.Equals(channel, "production", StringComparison.OrdinalIgnoreCase)) return "Production";
        return null;
    }

    private static void ValidateInstanceId(string id)
    {
        if (string.IsNullOrWhiteSpace(id) || !Regex.IsMatch(id, "^[a-zA-Z0-9_-]{1,60}$")) throw new InvalidOperationException("Invalid instance id.");
    }

    private static void ValidateBackupId(string id)
    {
        if (string.IsNullOrWhiteSpace(id) || !Regex.IsMatch(id, "^[a-zA-Z0-9_-]{1,80}$")) throw new InvalidOperationException("Invalid backup id.");
    }

    private static string Ps(string value) => value.Replace("'", "''");
    private static string Ini(string value) => value.Replace("\r", "").Replace("\n", "");
    private static string EscapeIdentifier(string value) => value.Replace("`", "``");
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    private sealed class TemporaryFile : IDisposable
    {
        public string Path { get; }
        public TemporaryFile(string path) => Path = path;
        public void Dispose() { try { File.Delete(Path); } catch { } }
    }
}

public sealed record InstallationManifest(string Id, string DisplayName, string Product, string Channel, string InstallRoot, int Port, string InstallFolderName, string InstallPath, string ConfigPath, string DatabaseName, string IisSite, string AppPool, bool AutoUpdate, DateTime CreatedAtUtc, DateTime UpdatedAtUtc);
public sealed record InstallationStatus(string Id, string DisplayName, string Product, string Channel, string InstallRoot, int Port, string InstallFolderName, string InstallPath, string ConfigPath, string DatabaseName, string? InstalledVersion, string? LatestVersion, bool UpdateAvailable, bool AutoUpdate, bool FolderExists, bool ConfigExists, string IisSiteState, string IisPoolState, bool HealthOk, string HealthMessage, bool DatabaseReachable, string DatabaseMessage, IReadOnlyList<BackupSummary> Backups);
public sealed record MySqlServiceStatus(string Name, string DisplayName, string State, string StartMode, string PathName);
public sealed record BackupFile(string Kind, string Database, string FileName, string Sha256, long SizeBytes);
public sealed record BackupMetadata(string BackupId, string InstanceId, DateTime CreatedAtUtc, string Reason, IReadOnlyList<BackupFile> Files);
public sealed record BackupSummary(string BackupId, DateTime CreatedAtUtc, string Reason, int FileCount, long SizeBytes);
public sealed record BackupResult(string BackupId, string Directory, int FileCount, long SizeBytes);
public sealed record RestoreResult(string BackupId, string PreRestoreBackupId, bool HealthOk, string HealthMessage);
public sealed record OperationResult(string Action, bool HealthOk, string Message);
public sealed record DbConfig(string Server, int Port, string User, string Password, string Database);
public sealed record DatabaseTarget(string Server, int Port, string User, string Password, string Database, string Kind);
public sealed record DbCheckResult(bool Reachable, string Message);
public sealed record HealthResult(bool Ok, string Message);
public sealed record ProcessResult(int ExitCode, string StdOut, string StdErr);


public sealed record ReleaseInfo(string Tag, DateTime PublishedAtUtc, IReadOnlyList<string> Assets, bool Eligible);
public sealed record VersionHealthRecord(string Tag, DateTime CheckedAtUtc, string Status, string Message, string? BackupId, string? PackageSha256);
public sealed record VersionOperationResult(string Tag, bool Success, string Status, string Message, string? BackupId);
