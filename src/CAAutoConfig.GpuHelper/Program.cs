using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace CA.GpuHelper;

internal static class Program
{
    public static int Main(string[] args)
    {
        StateStore? store = null;
        try
        {
            CliRequest request = CliParser.Parse(args);
            EnsureElevated();
            store = StateStore.ForProgramData();
            var service = new GpuLimitService(new NvidiaSmiRunner(), store);
            HelperState state = request.Operation == HelperOperation.Apply
                ? service.Apply(request.Targets, request.MaxClockMHz, request.PowerLimitWatts, request.AllowPowerIncrease)
                : service.Reset();
            Console.Out.WriteLine(JsonSerializer.Serialize(state, JsonDefaults.Options));
            return 0;
        }
        catch (Exception ex)
        {
            if (ex is not GpuOperationException)
            {
                try { store?.WriteFailure("startup", ex.Message, Array.Empty<string>()); } catch { }
            }
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static void EnsureElevated()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("CA GPU Helper supports Windows only.");

        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        if (!principal.IsInRole(WindowsBuiltInRole.Administrator) && !identity.IsSystem)
            throw new UnauthorizedAccessException("CA GPU Helper must run through its approved elevated task.");
    }
}

internal enum HelperOperation { Apply, Reset }

internal sealed class CliRequest
{
    public HelperOperation Operation { get; init; }
    public IReadOnlyList<GpuTarget> Targets { get; init; } = Array.Empty<GpuTarget>();
    public int MaxClockMHz { get; init; }
    public double PowerLimitWatts { get; init; }
    public bool AllowPowerIncrease { get; init; }
}

internal sealed class GpuTarget
{
    public int RequestedIndex { get; init; }
    public string Uuid { get; init; } = "";
}

internal static class CliParser
{
    private static readonly Regex UuidPattern = new(
        "^GPU-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static CliRequest Parse(string[] args)
    {
        if (args.Length == 1 && string.Equals(args[0], "reset", StringComparison.OrdinalIgnoreCase))
            return new CliRequest { Operation = HelperOperation.Reset };

        bool allowPowerIncrease = args.Length == 8 && string.Equals(args[7], "--allow-power-increase", StringComparison.Ordinal);
        if ((args.Length != 7 && !allowPowerIncrease) || !string.Equals(args[0], "apply", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(args[1], "--targets", StringComparison.Ordinal) ||
            !string.Equals(args[3], "--max-clock", StringComparison.Ordinal) ||
            !string.Equals(args[5], "--power-limit", StringComparison.Ordinal))
        {
            throw new ArgumentException("Expected: apply --targets <index=GPU-uuid,...> --max-clock <MHz> --power-limit <W> [--allow-power-increase], or: reset");
        }

        if (!int.TryParse(args[4], NumberStyles.None, CultureInfo.InvariantCulture, out int maxClock) || maxClock < 300 || maxClock > 3000)
            throw new ArgumentException("The maximum graphics clock must be an integer from 300 through 3000 MHz.");
        if (!double.TryParse(args[6], NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out double power) ||
            !double.IsFinite(power) || power < 50 || power > 1000)
            throw new ArgumentException("The power limit must be a finite value from 50 through 1000 watts.");

        var targets = new List<GpuTarget>();
        var indices = new HashSet<int>();
        var uuids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string token in args[2].Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            string[] pair = token.Split('=', 2, StringSplitOptions.None);
            if (pair.Length != 2 || !int.TryParse(pair[0], NumberStyles.None, CultureInfo.InvariantCulture, out int index) || index < 0)
                throw new ArgumentException("Each target must be index=GPU-uuid with a non-negative index.");
            string uuid = pair[1];
            if (!IsCanonicalGpuUuid(uuid))
                throw new ArgumentException("Each target must contain a canonical NVIDIA GPU UUID.");
            if (!indices.Add(index) || !uuids.Add(uuid))
                throw new ArgumentException("GPU indices and UUIDs must be unique.");
            targets.Add(new GpuTarget { RequestedIndex = index, Uuid = uuid });
        }
        if (targets.Count == 0 || targets.Count > 32)
            throw new ArgumentException("At least one and no more than 32 explicit GPU targets are required.");

        return new CliRequest
        {
            Operation = HelperOperation.Apply,
            Targets = targets,
            MaxClockMHz = maxClock,
            PowerLimitWatts = power,
            AllowPowerIncrease = allowPowerIncrease
        };
    }

    public static bool IsCanonicalGpuUuid(string value) => UuidPattern.IsMatch(value);
}

internal sealed class CommandResult
{
    public int ExitCode { get; init; }
    public string StandardOutput { get; init; } = "";
    public string StandardError { get; init; } = "";
}

internal interface INvidiaSmiRunner
{
    CommandResult Run(params string[] arguments);
}

internal sealed class NvidiaSmiRunner : INvidiaSmiRunner
{
    private readonly string _path;

    public NvidiaSmiRunner()
    {
        _path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "nvidia-smi.exe");
        if (!File.Exists(_path)) throw new FileNotFoundException("nvidia-smi was not found in Windows System32.", _path);
    }

    public CommandResult Run(params string[] arguments)
    {
        var start = new ProcessStartInfo
        {
            FileName = _path,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (string argument in arguments) start.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new InvalidOperationException("nvidia-smi did not start.");
        string standardOutput = process.StandardOutput.ReadToEndAsync().GetAwaiter().GetResult();
        string standardError = process.StandardError.ReadToEndAsync().GetAwaiter().GetResult();
        if (!process.WaitForExit(15_000))
        {
            try { process.Kill(true); } catch { }
            throw new TimeoutException("nvidia-smi exceeded the 15-second safety timeout.");
        }
        return new CommandResult
        {
            ExitCode = process.ExitCode,
            StandardOutput = standardOutput.Trim(),
            StandardError = standardError.Trim()
        };
    }
}

internal sealed class GpuLimitService
{
    private readonly INvidiaSmiRunner _runner;
    private readonly StateStore _store;

    public GpuLimitService(INvidiaSmiRunner runner, StateStore store)
    {
        _runner = runner;
        _store = store;
    }

    public HelperState Apply(IReadOnlyList<GpuTarget> targets, int maxClockMHz, double powerLimitWatts, bool allowPowerIncrease = false)
    {
        List<InventoryRow> inventory;
        try
        {
            inventory = targets.Select(Preflight).ToList();
            foreach (InventoryRow row in inventory)
            {
                if (powerLimitWatts < row.MinimumPowerWatts || powerLimitWatts > row.MaximumPowerWatts)
                    throw new InvalidOperationException($"Requested power is outside the vendor range for GPU {row.Index}.");
                if (powerLimitWatts > row.DefaultPowerWatts + 0.5)
                    throw new InvalidOperationException($"Requested power exceeds the vendor default for GPU {row.Index}.");
                if (powerLimitWatts > row.CurrentPowerLimitWatts + 0.5 && !allowPowerIncrease)
                    throw new InvalidOperationException($"Requested power would raise the current limit for GPU {row.Index} without explicit acknowledgement.");
                if (maxClockMHz > row.MaximumGraphicsClockMHz)
                    throw new InvalidOperationException($"Requested graphics clock exceeds the vendor-reported maximum for GPU {row.Index}.");
            }
        }
        catch (Exception ex)
        {
            return ThrowRecordedFailure("apply-preflight", ex, Array.Empty<string>());
        }

        RollbackDocument backup;
        try
        {
            RollbackDocument? existing = _store.TryReadRollback();
            backup = existing is null
                ? RollbackDocument.Create(inventory, maxClockMHz, powerLimitWatts)
                : ValidateExistingRollback(existing, inventory, maxClockMHz, powerLimitWatts);
            _store.WriteRollback(backup);
        }
        catch (Exception ex)
        {
            return ThrowRecordedFailure("apply-backup", ex, Array.Empty<string>());
        }

        var touched = new List<MutationRow>();
        var results = new List<GpuProfile>();
        try
        {
            foreach (InventoryRow row in inventory)
            {
                var mutation = new MutationRow(row);
                touched.Add(mutation);
                mutation.PowerChanged = true;
                RunChecked("set power", "-i", row.Uuid, "-pl", FormatNumber(powerLimitWatts));
                mutation.ClockChanged = true;
                RunChecked("set graphics clock", "-i", row.Uuid, "-lgc", $"0,{maxClockMHz}");

                string verify = RunChecked("verify profile", "-i", row.Uuid,
                    "--query-gpu=index,uuid,name,power.limit,clocks.gr", "--format=csv,noheader,nounits");
                string[] fields = SplitCsv(verify, 5);
                RequireUuid(row.Uuid, fields[1]);
                double actualPower = ParseFinite(fields[3], "live power limit");
                if (Math.Abs(actualPower - powerLimitWatts) > 0.5)
                    throw new InvalidOperationException($"GPU {row.Index} power verification failed.");

                results.Add(new GpuProfile
                {
                    Index = ParseIndex(fields[0]),
                    RequestedIndex = row.RequestedIndex,
                    Uuid = row.Uuid,
                    Name = row.Name,
                    MaxGraphicsClockMHz = maxClockMHz,
                    PowerLimitWatts = actualPower,
                    OriginalPowerLimitWatts = backup.Targets.Single(x => SameUuid(x.Uuid, row.Uuid)).OriginalPowerLimitWatts,
                    CurrentClockMHz = ParseFinite(fields[4], "current graphics clock")
                });
            }

            var state = HelperState.Applied(results);
            _store.WriteState(state);
            _store.Log("apply succeeded for all UUID-pinned targets");
            return state;
        }
        catch (Exception ex)
        {
            List<string> rollback = RollBackFailedApply(touched, backup);
            return ThrowRecordedFailure("apply", ex, rollback);
        }
    }

    public HelperState Reset()
    {
        RollbackDocument backup;
        List<InventoryRow> inventory;
        try
        {
            backup = _store.TryReadRollback() ?? throw new InvalidOperationException("No protected rollback record exists; refusing to guess reset targets.");
            inventory = backup.Targets.Select(target => Preflight(new GpuTarget
            {
                RequestedIndex = target.RequestedIndex,
                Uuid = target.Uuid
            })).ToList();
            foreach (InventoryRow row in inventory)
            {
                RollbackTarget original = backup.Targets.Single(x => SameUuid(x.Uuid, row.Uuid));
                if (original.OriginalPowerLimitWatts < row.MinimumPowerWatts || original.OriginalPowerLimitWatts > row.MaximumPowerWatts)
                    throw new InvalidOperationException($"Recorded rollback power is outside the current vendor range for GPU {row.Index}.");
            }
        }
        catch (Exception ex)
        {
            return ThrowRecordedFailure("reset-preflight", ex, Array.Empty<string>());
        }

        var touched = new List<InventoryRow>();
        var resetResults = new List<ResetResult>();
        try
        {
            foreach (InventoryRow row in inventory)
            {
                RollbackTarget original = backup.Targets.Single(x => SameUuid(x.Uuid, row.Uuid));
                touched.Add(row);
                RunChecked("reset graphics clock", "-i", row.Uuid, "-rgc");
                RunChecked("restore power", "-i", row.Uuid, "-pl", FormatNumber(original.OriginalPowerLimitWatts));
                string verify = RunChecked("verify reset", "-i", row.Uuid,
                    "--query-gpu=index,uuid,power.limit", "--format=csv,noheader,nounits");
                string[] fields = SplitCsv(verify, 3);
                RequireUuid(row.Uuid, fields[1]);
                double actualPower = ParseFinite(fields[2], "restored power limit");
                if (Math.Abs(actualPower - original.OriginalPowerLimitWatts) > 0.5)
                    throw new InvalidOperationException($"GPU {row.Index} rollback power verification failed.");
                resetResults.Add(new ResetResult
                {
                    Index = ParseIndex(fields[0]),
                    Uuid = row.Uuid,
                    RestoredPowerLimitWatts = actualPower,
                    GraphicsClockReset = true
                });
            }

            var state = HelperState.Reset(resetResults);
            _store.WriteState(state);
            _store.DeleteRollback();
            _store.Log("reset succeeded and protected rollback record was removed");
            return state;
        }
        catch (Exception ex)
        {
            var recovery = new List<string>();
            foreach (InventoryRow row in touched.AsEnumerable().Reverse())
            {
                try
                {
                    RunChecked("restore applied power after failed reset", "-i", row.Uuid, "-pl", FormatNumber(backup.PowerLimitWatts));
                    RunChecked("restore applied clock after failed reset", "-i", row.Uuid, "-lgc", $"0,{backup.MaxClockMHz}");
                    recovery.Add($"GPU {row.Index}: applied profile restored");
                }
                catch (Exception recoveryError)
                {
                    recovery.Add($"GPU {row.Index}: reset recovery failed ({recoveryError.Message})");
                }
            }
            return ThrowRecordedFailure("reset", ex, recovery);
        }
    }

    private InventoryRow Preflight(GpuTarget target)
    {
        string output = RunChecked("query GPU inventory", "-i", target.Uuid,
            "--query-gpu=index,uuid,name,power.min_limit,power.max_limit,power.limit,power.default_limit,clocks.max.gr",
            "--format=csv,noheader,nounits");
        string[] fields = SplitCsv(output, 8);
        RequireUuid(target.Uuid, fields[1]);
        return new InventoryRow
        {
            RequestedIndex = target.RequestedIndex,
            Index = ParseIndex(fields[0]),
            Uuid = fields[1],
            Name = fields[2],
            MinimumPowerWatts = ParseFinite(fields[3], "minimum power"),
            MaximumPowerWatts = ParseFinite(fields[4], "maximum power"),
            CurrentPowerLimitWatts = ParseFinite(fields[5], "current power limit"),
            DefaultPowerWatts = ParseFinite(fields[6], "default power"),
            MaximumGraphicsClockMHz = ParseFinite(fields[7], "maximum graphics clock")
        };
    }

    private RollbackDocument ValidateExistingRollback(RollbackDocument backup, IReadOnlyList<InventoryRow> inventory, int maxClockMHz, double powerLimitWatts)
    {
        if (backup.SchemaVersion != 1 || backup.Targets.Count != inventory.Count ||
            backup.MaxClockMHz != maxClockMHz || Math.Abs(backup.PowerLimitWatts - powerLimitWatts) > 0.5)
            throw new InvalidOperationException("The protected rollback record belongs to a different profile; reset it before applying another profile.");
        foreach (InventoryRow row in inventory)
        {
            if (!backup.Targets.Any(x => SameUuid(x.Uuid, row.Uuid)))
                throw new InvalidOperationException("The protected rollback record belongs to a different GPU set.");
        }
        return backup;
    }

    private List<string> RollBackFailedApply(IEnumerable<MutationRow> touched, RollbackDocument backup)
    {
        var report = new List<string>();
        bool complete = true;
        foreach (MutationRow mutation in touched.Reverse())
        {
            RollbackTarget original = backup.Targets.Single(x => SameUuid(x.Uuid, mutation.Row.Uuid));
            if (mutation.ClockChanged)
            {
                try { RunChecked("rollback graphics clock", "-i", mutation.Row.Uuid, "-rgc"); report.Add($"GPU {mutation.Row.Index}: clock reset"); }
                catch (Exception ex) { complete = false; report.Add($"GPU {mutation.Row.Index}: clock rollback failed ({ex.Message})"); }
            }
            if (mutation.PowerChanged)
            {
                try { RunChecked("rollback power", "-i", mutation.Row.Uuid, "-pl", FormatNumber(original.OriginalPowerLimitWatts)); report.Add($"GPU {mutation.Row.Index}: power restored"); }
                catch (Exception ex) { complete = false; report.Add($"GPU {mutation.Row.Index}: power rollback failed ({ex.Message})"); }
            }
        }
        if (complete) _store.DeleteRollback();
        return report;
    }

    private HelperState ThrowRecordedFailure(string operation, Exception exception, IReadOnlyList<string> rollback)
    {
        HelperState state = _store.WriteFailure(operation, exception.Message, rollback);
        throw new GpuOperationException(exception.Message, state, exception);
    }

    private string RunChecked(string label, params string[] arguments)
    {
        CommandResult result = _runner.Run(arguments);
        _store.Log($"{label}: nvidia-smi {Redact(arguments)} => exit {result.ExitCode}");
        if (result.ExitCode != 0)
        {
            string detail = string.IsNullOrWhiteSpace(result.StandardError) ? result.StandardOutput : result.StandardError;
            throw new InvalidOperationException($"{label} failed: {Sanitize(detail)}");
        }
        return result.StandardOutput;
    }

    private static string[] SplitCsv(string output, int expected)
    {
        if (output.Contains('\n') || output.Contains('\r')) throw new InvalidOperationException("nvidia-smi returned an unexpected number of rows.");
        string[] fields = output.Split(',').Select(x => x.Trim()).ToArray();
        if (fields.Length != expected) throw new InvalidOperationException("nvidia-smi returned an unexpected field count.");
        return fields;
    }

    private static int ParseIndex(string value)
    {
        if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int parsed) || parsed < 0)
            throw new InvalidOperationException("nvidia-smi returned an invalid GPU index.");
        return parsed;
    }

    private static double ParseFinite(string value, string label)
    {
        if (!double.TryParse(value, NumberStyles.AllowDecimalPoint | NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out double parsed) || !double.IsFinite(parsed))
            throw new InvalidOperationException($"nvidia-smi returned invalid {label} telemetry.");
        return parsed;
    }

    private static void RequireUuid(string expected, string actual)
    {
        if (!SameUuid(expected, actual)) throw new InvalidOperationException("GPU UUID identity verification failed.");
    }

    private static bool SameUuid(string left, string right) => string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    private static string FormatNumber(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
    private static string Redact(IEnumerable<string> values) => string.Join(' ', values.Select(v => v.StartsWith("GPU-", StringComparison.OrdinalIgnoreCase) ? "GPU-[redacted]" : v));
    private static string Sanitize(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "no diagnostic text";
        string clean = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
        clean = Regex.Replace(clean,
            "GPU-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
            "GPU-[redacted]", RegexOptions.CultureInvariant);
        return clean[..Math.Min(clean.Length, 300)];
    }
}

internal sealed class GpuOperationException : Exception
{
    public HelperState State { get; }
    public GpuOperationException(string message, HelperState state, Exception inner) : base(message, inner) => State = state;
}

internal sealed class StateStore
{
    private readonly string _root;
    public string StatePath => Path.Combine(_root, "gpu-limits-state.json");
    public string RollbackPath => Path.Combine(_root, "gpu-limits-backup.json");
    public string LogPath => Path.Combine(_root, "gpu-limits.log");

    public StateStore(string root)
    {
        _root = Path.GetFullPath(root);
        Directory.CreateDirectory(_root);
        if ((new DirectoryInfo(_root).Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("The helper data directory must not be a reparse point.");
    }

    public static StateStore ForProgramData() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CAGpuLimits"));

    public void WriteState(HelperState state) => WriteJsonAtomic(StatePath, state);
    public void WriteRollback(RollbackDocument document) => WriteJsonAtomic(RollbackPath, document);

    public RollbackDocument? TryReadRollback()
    {
        if (!File.Exists(RollbackPath)) return null;
        RollbackDocument? document = JsonSerializer.Deserialize<RollbackDocument>(File.ReadAllText(RollbackPath, Encoding.UTF8), JsonDefaults.Options);
        if (document is null || document.SchemaVersion != 1 || document.Targets is null ||
            document.Targets.Count == 0 || document.Targets.Count > 32 ||
            document.MaxClockMHz < 300 || document.MaxClockMHz > 3000 ||
            !double.IsFinite(document.PowerLimitWatts) || document.PowerLimitWatts < 50 || document.PowerLimitWatts > 1000)
            throw new InvalidOperationException("The protected rollback record is invalid.");
        var indices = new HashSet<int>();
        var uuids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (RollbackTarget target in document.Targets)
        {
            if (target.RequestedIndex < 0 || !indices.Add(target.RequestedIndex) ||
                !CliParser.IsCanonicalGpuUuid(target.Uuid) || !uuids.Add(target.Uuid) ||
                !double.IsFinite(target.OriginalPowerLimitWatts) || target.OriginalPowerLimitWatts <= 0)
                throw new InvalidOperationException("The protected rollback record contains an invalid target.");
        }
        return document;
    }

    public void DeleteRollback()
    {
        if (File.Exists(RollbackPath)) File.Delete(RollbackPath);
    }

    public HelperState WriteFailure(string operation, string message, IReadOnlyList<string> rollback)
    {
        var state = HelperState.Failed(operation, message, rollback);
        WriteState(state);
        Log($"{operation} failed: {message}");
        return state;
    }

    public void Log(string message) => File.AppendAllText(LogPath,
        $"{DateTimeOffset.UtcNow:O}\t{message}{Environment.NewLine}", new UTF8Encoding(false));

    private static void WriteJsonAtomic<T>(string path, T value)
    {
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(value, JsonDefaults.Options), new UTF8Encoding(false));
            File.Move(temp, path, true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }
}

internal static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
}

internal sealed class InventoryRow
{
    public int RequestedIndex { get; init; }
    public int Index { get; init; }
    public string Uuid { get; init; } = "";
    public string Name { get; init; } = "";
    public double MinimumPowerWatts { get; init; }
    public double MaximumPowerWatts { get; init; }
    public double CurrentPowerLimitWatts { get; init; }
    public double DefaultPowerWatts { get; init; }
    public double MaximumGraphicsClockMHz { get; init; }
}

internal sealed class MutationRow
{
    public InventoryRow Row { get; }
    public bool PowerChanged { get; set; }
    public bool ClockChanged { get; set; }
    public MutationRow(InventoryRow row) => Row = row;
}

internal sealed class RollbackDocument
{
    public int SchemaVersion { get; init; } = 1;
    public string CreatedUtc { get; init; } = "";
    public int MaxClockMHz { get; init; }
    public double PowerLimitWatts { get; init; }
    public List<RollbackTarget> Targets { get; init; } = new();

    public static RollbackDocument Create(IEnumerable<InventoryRow> rows, int maxClockMHz, double powerLimitWatts) => new()
    {
        CreatedUtc = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture),
        MaxClockMHz = maxClockMHz,
        PowerLimitWatts = powerLimitWatts,
        Targets = rows.Select(x => new RollbackTarget
        {
            RequestedIndex = x.RequestedIndex,
            Uuid = x.Uuid,
            OriginalPowerLimitWatts = x.CurrentPowerLimitWatts
        }).ToList()
    };
}

internal sealed class RollbackTarget
{
    public int RequestedIndex { get; init; }
    public string Uuid { get; init; } = "";
    public double OriginalPowerLimitWatts { get; init; }
}

internal sealed class GpuProfile
{
    public int Index { get; init; }
    public int RequestedIndex { get; init; }
    public string Uuid { get; init; } = "";
    public string Name { get; init; } = "";
    public int MaxGraphicsClockMHz { get; init; }
    public double PowerLimitWatts { get; init; }
    public double OriginalPowerLimitWatts { get; init; }
    public double CurrentClockMHz { get; init; }
}

internal sealed class ResetResult
{
    public int Index { get; init; }
    public string Uuid { get; init; } = "";
    public double RestoredPowerLimitWatts { get; init; }
    public bool GraphicsClockReset { get; init; }
}

internal sealed class HelperState
{
    public int SchemaVersion { get; init; } = 2;
    public string TimestampUtc { get; init; } = "";
    public string Status { get; init; } = "";
    public string Operation { get; init; } = "";
    public string Computer { get; init; } = "";
    public string? Message { get; init; }
    public IReadOnlyList<string>? Rollback { get; init; }
    public IReadOnlyList<GpuProfile>? Results { get; init; }
    public IReadOnlyList<ResetResult>? ResetResults { get; init; }

    public static HelperState Applied(IReadOnlyList<GpuProfile> results) => New("applied", "apply", results: results);
    public static HelperState Reset(IReadOnlyList<ResetResult> results) => New("reset", "reset", resetResults: results);
    public static HelperState Failed(string operation, string message, IReadOnlyList<string> rollback) =>
        New("failed", operation, message, rollback);

    private static HelperState New(string status, string operation, string? message = null,
        IReadOnlyList<string>? rollback = null, IReadOnlyList<GpuProfile>? results = null,
        IReadOnlyList<ResetResult>? resetResults = null) => new()
    {
        TimestampUtc = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture),
        Status = status,
        Operation = operation,
        Computer = Environment.MachineName,
        Message = message,
        Rollback = rollback,
        Results = results,
        ResetResults = resetResults
    };
}
