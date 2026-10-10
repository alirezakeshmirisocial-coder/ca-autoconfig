using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using CA.GpuHelper;

namespace CA.GpuHelper.Tests;

internal static class Program
{
    private const string Uuid0 = "GPU-00000000-0000-0000-0000-000000000000";
    private const string Uuid1 = "GPU-11111111-1111-1111-1111-111111111111";

    public static int Main()
    {
        var tests = new (string Name, Action Body)[]
        {
            ("parser accepts one fixed apply grammar", ParserAcceptsFixedGrammar),
            ("parser rejects command-shaped target input", ParserRejectsInjection),
            ("preflight failure performs no mutation", PreflightFailurePerformsNoMutation),
            ("apply failure rolls back UUID-pinned changes", ApplyFailureRollsBack),
            ("reset uses protected original values", ResetUsesProtectedOriginalValues),
            ("reset failure restores the applied profile", ResetFailureRestoresAppliedProfile),
            ("corrupt rollback record is rejected before NVIDIA access", CorruptRollbackIsRejected),
            ("existing rollback cannot be overwritten by another profile", ExistingRollbackCannotBeOverwritten)
        };

        int failed = 0;
        foreach ((string name, Action body) in tests)
        {
            try { body(); Console.WriteLine($"PASS  {name}"); }
            catch (Exception ex) { failed++; Console.Error.WriteLine($"FAIL  {name}: {ex.Message}"); }
        }
        Console.WriteLine($"{tests.Length - failed}/{tests.Length} GPU helper safety tests passed.");
        return failed == 0 ? 0 : 1;
    }

    private static void ParserAcceptsFixedGrammar()
    {
        CliRequest request = CliParser.Parse(new[] { "apply", "--targets", $"0={Uuid0},1={Uuid1}", "--max-clock", "1700", "--power-limit", "280" });
        Assert(request.Targets.Count == 2 && request.MaxClockMHz == 1700 && request.PowerLimitWatts == 280, "valid request was not preserved");
        Assert(CliParser.Parse(new[] { "reset" }).Operation == HelperOperation.Reset, "reset grammar was rejected");
    }

    private static void ParserRejectsInjection()
    {
        ExpectThrows(() => CliParser.Parse(new[] { "apply", "--targets", $"0={Uuid0};calc.exe", "--max-clock", "1700", "--power-limit", "280" }));
        ExpectThrows(() => CliParser.Parse(new[] { "reset", "--targets", $"0={Uuid0}" }));
        ExpectThrows(() => CliParser.Parse(new[] { "apply", "--targets", $"0={Uuid0}", "--max-clock", "1700", "--power-limit", "280", "extra" }));
    }

    private static void PreflightFailurePerformsNoMutation()
    {
        using var fixture = new Fixture();
        fixture.Runner.EnqueueQuery(Inventory(0, Uuid0, 100, 450, 450, 450));
        fixture.Runner.EnqueueQuery(Inventory(1, Uuid1, 300, 450, 450, 450));
        ExpectThrows(() => fixture.Service.Apply(Targets(), 1700, 280));
        Assert(!fixture.Runner.Calls.Any(IsMutation), "a GPU was changed before every target passed preflight");
        Assert(!File.Exists(fixture.Store.RollbackPath), "preflight failure wrote a rollback record");
    }

    private static void ApplyFailureRollsBack()
    {
        using var fixture = new Fixture();
        fixture.Runner.EnqueueQuery(Inventory(0, Uuid0, 100, 450, 320, 450));
        fixture.Runner.EnqueueQuery(Inventory(1, Uuid1, 100, 450, 330, 450));
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueQuery($"0, {Uuid0}, Test GPU, 280, 1500");
        fixture.Runner.EnqueueFailure($"simulated power failure for {Uuid1}");
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueSuccess();

        ExpectThrows(() => fixture.Service.Apply(Targets(), 1700, 280));
        string calls = string.Join("\n", fixture.Runner.Calls.Select(x => string.Join(' ', x)));
        Assert(calls.Contains($"-i {Uuid0} -rgc", StringComparison.Ordinal), "clock rollback did not use GPU 0 UUID");
        Assert(calls.Contains($"-i {Uuid0} -pl 320", StringComparison.Ordinal), "GPU 0 original power was not restored");
        Assert(calls.Contains($"-i {Uuid1} -pl 330", StringComparison.Ordinal), "GPU 1 original power was not restored");
        Assert(!File.Exists(fixture.Store.RollbackPath), "complete rollback left a stale rollback record");
        string state = File.ReadAllText(fixture.Store.StatePath);
        Assert(!state.Contains(Uuid1, StringComparison.OrdinalIgnoreCase), "failure state leaked a GPU UUID from driver diagnostics");
    }

    private static void ResetUsesProtectedOriginalValues()
    {
        using var fixture = new Fixture();
        fixture.Store.WriteRollback(new RollbackDocument
        {
            CreatedUtc = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture),
            MaxClockMHz = 1700,
            PowerLimitWatts = 280,
            Targets = new List<RollbackTarget>
            {
                new() { RequestedIndex = 0, Uuid = Uuid0, OriginalPowerLimitWatts = 320 },
                new() { RequestedIndex = 1, Uuid = Uuid1, OriginalPowerLimitWatts = 330 }
            }
        });
        fixture.Runner.EnqueueQuery(Inventory(0, Uuid0, 100, 450, 280, 450));
        fixture.Runner.EnqueueQuery(Inventory(1, Uuid1, 100, 450, 280, 450));
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueQuery($"0, {Uuid0}, 320");
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueQuery($"1, {Uuid1}, 330");

        HelperState state = fixture.Service.Reset();
        Assert(state.Status == "reset", "reset did not report success");
        string calls = string.Join("\n", fixture.Runner.Calls.Select(x => string.Join(' ', x)));
        Assert(calls.Contains($"-i {Uuid0} -pl 320", StringComparison.Ordinal), "GPU 0 protected original power was ignored");
        Assert(calls.Contains($"-i {Uuid1} -pl 330", StringComparison.Ordinal), "GPU 1 protected original power was ignored");
        Assert(!File.Exists(fixture.Store.RollbackPath), "successful reset retained rollback record");
    }

    private static void ExistingRollbackCannotBeOverwritten()
    {
        using var fixture = new Fixture();
        fixture.Store.WriteRollback(new RollbackDocument
        {
            CreatedUtc = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture),
            MaxClockMHz = 1600,
            PowerLimitWatts = 250,
            Targets = new List<RollbackTarget> { new() { RequestedIndex = 0, Uuid = Uuid0, OriginalPowerLimitWatts = 320 } }
        });
        fixture.Runner.EnqueueQuery(Inventory(0, Uuid0, 100, 450, 250, 450));
        ExpectThrows(() => fixture.Service.Apply(new[] { new GpuTarget { RequestedIndex = 0, Uuid = Uuid0 } }, 1700, 280));
        Assert(!fixture.Runner.Calls.Any(IsMutation), "a mismatched saved profile was overwritten or mutated");
        RollbackDocument saved = fixture.Store.TryReadRollback()!;
        Assert(saved.MaxClockMHz == 1600 && saved.PowerLimitWatts == 250, "protected rollback record changed");
    }

    private static void ResetFailureRestoresAppliedProfile()
    {
        using var fixture = new Fixture();
        fixture.Store.WriteRollback(new RollbackDocument
        {
            CreatedUtc = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture),
            MaxClockMHz = 1700,
            PowerLimitWatts = 280,
            Targets = new List<RollbackTarget>
            {
                new() { RequestedIndex = 0, Uuid = Uuid0, OriginalPowerLimitWatts = 320 }
            }
        });
        fixture.Runner.EnqueueQuery(Inventory(0, Uuid0, 100, 450, 280, 450));
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueFailure("simulated reset power failure");
        fixture.Runner.EnqueueSuccess();
        fixture.Runner.EnqueueSuccess();

        ExpectThrows(() => fixture.Service.Reset());
        string calls = string.Join("\n", fixture.Runner.Calls.Select(x => string.Join(' ', x)));
        Assert(calls.Contains($"-i {Uuid0} -pl 280", StringComparison.Ordinal), "failed reset did not restore the applied power profile");
        Assert(calls.Contains($"-i {Uuid0} -lgc 0,1700", StringComparison.Ordinal), "failed reset did not restore the applied clock profile");
        Assert(File.Exists(fixture.Store.RollbackPath), "failed reset discarded the only protected rollback record");
    }

    private static void CorruptRollbackIsRejected()
    {
        using var fixture = new Fixture();
        File.WriteAllText(fixture.Store.RollbackPath,
            "{\"schemaVersion\":1,\"createdUtc\":\"2026-10-10T00:00:00Z\",\"maxClockMHz\":1700,\"powerLimitWatts\":280," +
            "\"targets\":[{\"requestedIndex\":0,\"uuid\":\"--help\",\"originalPowerLimitWatts\":320}]}");
        ExpectThrows(() => fixture.Service.Reset());
        Assert(fixture.Runner.Calls.Count == 0, "corrupt rollback input reached nvidia-smi");
    }

    private static IReadOnlyList<GpuTarget> Targets() => new[]
    {
        new GpuTarget { RequestedIndex = 0, Uuid = Uuid0 },
        new GpuTarget { RequestedIndex = 1, Uuid = Uuid1 }
    };

    private static string Inventory(int index, string uuid, double min, double max, double current, double @default) =>
        $"{index}, {uuid}, Test GPU, {min}, {max}, {current}, {@default}";
    private static bool IsMutation(string[] args) => args.Contains("-pl") || args.Contains("-lgc") || args.Contains("-rgc");
    private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static void ExpectThrows(Action action) { try { action(); } catch { return; } throw new InvalidOperationException("expected an exception"); }

    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "ca-gpu-helper-tests-" + Guid.NewGuid().ToString("N"));
        public FakeRunner Runner { get; } = new();
        public StateStore Store { get; }
        public GpuLimitService Service { get; }
        public Fixture() { Store = new StateStore(Root); Service = new GpuLimitService(Runner, Store); }
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }

    private sealed class FakeRunner : INvidiaSmiRunner
    {
        private readonly Queue<CommandResult> _results = new();
        public List<string[]> Calls { get; } = new();
        public void EnqueueQuery(string output) => _results.Enqueue(new CommandResult { ExitCode = 0, StandardOutput = output });
        public void EnqueueSuccess() => _results.Enqueue(new CommandResult { ExitCode = 0, StandardOutput = "OK" });
        public void EnqueueFailure(string error) => _results.Enqueue(new CommandResult { ExitCode = 1, StandardError = error });
        public CommandResult Run(params string[] arguments)
        {
            Calls.Add(arguments.ToArray());
            if (_results.Count == 0) throw new InvalidOperationException("fake runner queue exhausted");
            return _results.Dequeue();
        }
    }
}
