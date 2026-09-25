using System.Collections.Concurrent;
using System.Text.Json;

public sealed class OperationLogStore
{
    private readonly string _root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "iMonitor", "ERPDeploymentManager", "operations");
    private readonly ConcurrentDictionary<string, OperationState> _states = new(StringComparer.OrdinalIgnoreCase);

    public OperationLogStore() => Directory.CreateDirectory(_root);

    public OperationState Start(string title)
    {
        var id = DateTime.UtcNow.ToString("yyyyMMddHHmmss") + "-" + Guid.NewGuid().ToString("N")[..8];
        var state = new OperationState(id, title, "Running", DateTime.UtcNow, null, new List<OperationLogLine>());
        _states[id] = state; Save(state); Add(id, "info", "عملیات شروع شد: " + title);
        return state;
    }

    public void Add(string id, string level, string message)
    {
        if (!_states.TryGetValue(id, out var state)) return;
        lock (state.Lines)
        {
            state.Lines.Add(new OperationLogLine(DateTime.UtcNow, level, message));
            if (state.Lines.Count > 2000) state.Lines.RemoveRange(0, state.Lines.Count - 2000);
            Save(state);
        }
    }

    public void Complete(string id, bool ok, string message)
    {
        if (!_states.TryGetValue(id, out var state)) return;
        Add(id, ok ? "ok" : "error", message);
        _states[id] = state with { Status = ok ? "Succeeded" : "Failed", CompletedAtUtc = DateTime.UtcNow };
        Save(_states[id]);
    }

    public OperationState? Get(string id)
    {
        if (_states.TryGetValue(id, out var s)) return s;
        var path = Path.Combine(_root, Safe(id) + ".json");
        if (!File.Exists(path)) return null;
        try { var x=JsonSerializer.Deserialize<OperationState>(File.ReadAllText(path)); if(x is not null)_states[id]=x; return x; } catch { return null; }
    }

    public IReadOnlyList<OperationState> Recent() =>
        Directory.EnumerateFiles(_root, "*.json").OrderByDescending(File.GetLastWriteTimeUtc).Take(30)
            .Select(p => { try { return JsonSerializer.Deserialize<OperationState>(File.ReadAllText(p)); } catch { return null; } })
            .Where(x => x is not null).Cast<OperationState>().ToArray();

    private void Save(OperationState state)
    {
        try { File.WriteAllText(Path.Combine(_root, Safe(state.Id) + ".json"), JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented=true })); } catch { }
    }
    private static string Safe(string value) => new(value.Where(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_').ToArray());
}
public sealed record OperationState(string Id,string Title,string Status,DateTime StartedAtUtc,DateTime? CompletedAtUtc,List<OperationLogLine> Lines);
public sealed record OperationLogLine(DateTime AtUtc,string Level,string Message);
