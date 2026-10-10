using System;
using System.Collections.Generic;
using CA.SystemOverlay;

internal static class Program
{
    private const string AdapterA = "luid_0x00000000_0x000000a1_phys_0";
    private const string AdapterB = "luid_0x00000000_0x000000b2_phys_0";
    private static int _passed;

    private static int Main(string[] args)
    {
        if (args.Length == 1 && String.Equals(args[0], "--live-probe", StringComparison.OrdinalIgnoreCase))
            return RunLiveProbe();

        var tests = new (string Name, Action Body)[]
        {
            ("duplicate model names map by internal identity", DuplicateNamesMapByIdentity),
            ("counter enumeration reorder is stable", CounterReorderIsStable),
            ("adapter enumeration reorder preserves display rows", AdapterReorderIsStable),
            ("unknown counter adapter fails closed", UnknownCounterAdapterFailsClosed),
            ("missing memory counter fails closed", MissingMemoryFailsClosed),
            ("missing dedicated capacity preserves only engine capability", MissingCapacityPreservesEngine),
            ("malformed identity fails closed", MalformedIdentityFailsClosed),
            ("duplicate adapter identity fails closed", DuplicateAdapterIdentityFailsClosed),
            ("public result omits raw adapter identity", PublicResultOmitsRawIdentity),
            ("process engine samples aggregate before busiest engine", EngineAggregationUsesBusiestEngine),
            ("live orchestrator cannot authorize HUD use", LiveOrchestratorCannotAuthorizeHud),
            ("DXGI source failure is retained", AdapterSourceFailureIsRetained),
            ("counter source failure is retained", CounterSourceFailureIsRetained),
            ("partial source retains healthy memory mapping", PartialSourceRetainsHealthyMemory),
            ("partial public report marks only healthy fields available", PartialPublicReportMarksAvailability),
            ("DXGI software adapter counters are explicitly ignored", SoftwareAdapterCountersAreIgnored),
            ("public live report is sanitized and non-authorizing", PublicLiveReportIsSanitized)
        };

        try
        {
            foreach (var test in tests)
            {
                test.Body();
                _passed++;
                Console.WriteLine("PASS " + test.Name);
            }
            _passed += WindowsGpuPdhTests.RunAll();
            _passed += WindowsGpuPollingTests.RunAll();
            Console.WriteLine(_passed + " Windows GPU telemetry tests passed. Fixtures performed no hardware access.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("FAIL after " + _passed + " tests: " + exception.Message);
            return 1;
        }
    }

    private static void DuplicateNamesMapByIdentity()
    {
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), Observations());
        Assert(result.MappingChecksPass && result.CanProceedToLiveProvider, "Complete mapping did not pass.");
        Assert(!result.CanUseInHud, "Recorded mapping authorized HUD use.");
        Assert(result.Adapters.Count == 2, "Expected two mapped adapters.");
        Assert(result.Adapters[0].Name == result.Adapters[1].Name, "Fixture no longer covers duplicate model names.");
        Assert(result.Adapters[0].EngineLoadPercent == 72 && result.Adapters[0].DedicatedMemoryBytes == 8_000_000_000L, "Adapter A received the wrong counters.");
        Assert(result.Adapters[1].EngineLoadPercent == 41 && result.Adapters[1].DedicatedMemoryBytes == 12_000_000_000L, "Adapter B received the wrong counters.");
    }

    private static void CounterReorderIsStable()
    {
        WindowsGpuCounterMapResult baseline = WindowsGpuCounterMapper.Map(Inventory(), Observations());
        List<WindowsGpuCounterObservation> observations = Observations();
        observations.Reverse();
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), observations);
        Assert(result.MappingChecksPass, "Reordered counters failed mapping.");
        Assert(result.Adapters[0].EngineLoadPercent == 72 && result.Adapters[1].EngineLoadPercent == 41, "Counter reorder changed the adapter assignment.");
        Assert(result.InternalTopologyFingerprint == baseline.InternalTopologyFingerprint, "Counter reorder changed the topology fingerprint.");
    }

    private static void AdapterReorderIsStable()
    {
        List<WindowsGpuAdapterInventory> inventory = Inventory();
        inventory.Reverse();
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(inventory, Observations());
        Assert(result.MappingChecksPass, "Reordered inventory failed mapping.");
        Assert(result.Adapters[0].DisplayIndex == 0 && result.Adapters[0].EngineLoadPercent == 72, "Display row 0 changed after inventory reorder.");
        Assert(result.Adapters[1].DisplayIndex == 1 && result.Adapters[1].EngineLoadPercent == 41, "Display row 1 changed after inventory reorder.");
        Assert(result.InternalTopologyFingerprint == WindowsGpuCounterMapper.Map(Inventory(), Observations()).InternalTopologyFingerprint, "Inventory reorder changed the topology fingerprint.");
    }

    private static void UnknownCounterAdapterFailsClosed()
    {
        List<WindowsGpuCounterObservation> observations = Observations();
        observations.Add(new WindowsGpuCounterObservation
        {
            InstanceName = "pid_999_luid_0x0_0xdead_phys_0_eng_0_engtype_3D",
            Kind = WindowsGpuCounterKind.EngineUtilizationPercent,
            Value = 1
        });
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), observations);
        Assert(!result.MappingChecksPass && result.ReasonCodes.Contains("counter-adapter-not-in-inventory"), "Unknown counter identity was accepted.");
    }

    private static void MissingMemoryFailsClosed()
    {
        List<WindowsGpuCounterObservation> observations = Observations();
        observations.RemoveAll(item => item.InstanceName.StartsWith(AdapterB, StringComparison.OrdinalIgnoreCase) && item.Kind == WindowsGpuCounterKind.DedicatedMemoryBytes);
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), observations);
        Assert(!result.MappingChecksPass && result.ReasonCodes.Contains("dedicated-memory-counter-missing"), "Missing memory counter was accepted.");
        Assert(result.EngineLoadMappingChecksPass && !result.DedicatedMemoryMappingChecksPass, "A missing memory row invalidated the healthy engine family or passed memory.");
    }

    private static void MissingCapacityPreservesEngine()
    {
        List<WindowsGpuAdapterInventory> inventory = Inventory();
        inventory[0].DedicatedMemoryCapacityBytes = 0;
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(inventory, Observations());
        Assert(!result.MappingChecksPass && result.EngineLoadMappingChecksPass && !result.DedicatedMemoryMappingChecksPass, "Missing capacity did not isolate memory capability.");
        Assert(result.ReasonCodes.Contains("adapter-memory-capacity-unavailable"), "Missing capacity reason was not retained.");
        Assert(result.Adapters.Count == 2 && result.Adapters[0].EngineLoadPercent >= 0, "Engine evidence was discarded with unavailable memory capacity.");
    }

    private static void MalformedIdentityFailsClosed()
    {
        List<WindowsGpuCounterObservation> observations = Observations();
        observations[0].InstanceName = "not-a-wddm-instance";
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), observations);
        Assert(!result.MappingChecksPass && result.ReasonCodes.Contains("counter-identity-invalid"), "Malformed counter identity was accepted.");
    }

    private static void DuplicateAdapterIdentityFailsClosed()
    {
        List<WindowsGpuAdapterInventory> inventory = Inventory();
        inventory.Add(new WindowsGpuAdapterInventory { CorrelationKey = AdapterA, DisplayIndex = 2, Name = "Duplicate", DriverVersion = "1" });
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(inventory, Observations());
        Assert(!result.MappingChecksPass && result.ReasonCodes.Contains("adapter-identity-duplicate"), "Duplicate adapter identity was accepted.");
    }

    private static void PublicResultOmitsRawIdentity()
    {
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), Observations());
        Assert(!result.RawAdapterIdentifiersIncluded, "Result claims to include raw identifiers.");
        foreach (WindowsGpuMappedMetric adapter in result.Adapters)
        {
            string publicText = adapter.DisplayIndex + "|" + adapter.Name + "|" + adapter.DriverVersion + "|" + adapter.EngineLoadPercent + "|" + adapter.DedicatedMemoryBytes;
            Assert(!publicText.Contains("luid_", StringComparison.OrdinalIgnoreCase), "Mapped output exposed a raw LUID.");
        }
    }

    private static void EngineAggregationUsesBusiestEngine()
    {
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), Observations());
        Assert(result.Adapters[0].EngineLoadPercent == 72, "Engine counters were summed or assigned incorrectly.");
        Assert(result.Adapters[0].EngineLoadPercent <= 100, "Engine aggregation exceeded 100 percent.");
    }

    private static void LiveOrchestratorCannotAuthorizeHud()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(
            new FakeAdapterSource(true, String.Empty),
            new FakeCounterSource(true, String.Empty));
        Assert(result.ProbeStatus == "MAPPING_AVAILABLE" && result.MappingChecksPass, "Complete recorded live inputs did not reach the mapping boundary.");
        Assert(!result.CanUseInHud && !result.HardwareWrites && !result.NetworkAccess && !result.ElevationRequested && !result.RawAdapterIdentifiersIncluded, "Live orchestrator weakened a safety boundary.");
    }

    private static void AdapterSourceFailureIsRetained()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(
            new FakeAdapterSource(false, "dxgi-test-failure"),
            new FakeCounterSource(true, String.Empty));
        Assert(result.ProbeStatus == "BLOCKED" && result.ReasonCodes.Contains("dxgi-test-failure"), "DXGI failure was hidden.");
    }

    private static void CounterSourceFailureIsRetained()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(
            new FakeAdapterSource(true, String.Empty),
            new FakeCounterSource(false, "counter-test-failure"));
        Assert(result.ProbeStatus == "BLOCKED" && result.ReasonCodes.Contains("counter-test-failure"), "Counter failure was hidden.");
    }

    private static void PartialSourceRetainsHealthyMemory()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(
            new FakeAdapterSource(true, String.Empty),
            new MemoryOnlyCounterSource());
        Assert(result.ProbeStatus == "PARTIAL_MAPPING_AVAILABLE", "Partial counter evidence was not labeled explicitly.");
        Assert(!result.MappingChecksPass && !result.EngineLoadMappingChecksPass && result.DedicatedMemoryMappingChecksPass, "Per-field mapping state is wrong.");
        Assert(result.Adapters.Count == 2 && result.Adapters[0].EngineLoadPercent == -1 && result.Adapters[0].DedicatedMemoryBytes >= 0, "Healthy memory evidence was discarded.");
        Assert(result.ReasonCodes.Contains("pdh-engine-data-invalid") && result.ReasonCodes.Contains("engine-counter-missing"), "Partial failure evidence was not retained.");
        Assert(!result.CanUseInHud, "Partial evidence authorized HUD use.");
    }

    private static void PartialPublicReportMarksAvailability()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(
            new FakeAdapterSource(true, String.Empty),
            new MemoryOnlyCounterSource());
        WindowsGpuLiveReportDocument document = WindowsGpuLiveReport.Create(result, DateTime.UtcNow);
        Assert(document.Adapters.Length == 2, "Partial report dropped mapped adapters.");
        Assert(!document.Adapters[0].EngineLoadAvailable && document.Adapters[0].EngineLoadPercent == -1, "Invalid engine data appeared available.");
        Assert(document.Adapters[0].DedicatedMemoryAvailable && document.Adapters[0].DedicatedMemoryBytes >= 0 && document.Adapters[0].VramPercent >= 0, "Healthy memory data was hidden.");
        Assert(!document.CanUseInHud, "Partial report authorized HUD use.");
    }

    private static void SoftwareAdapterCountersAreIgnored()
    {
        const string software = "luid_0x00000000_0x000000c3_phys_0";
        List<WindowsGpuAdapterInventory> inventory = Inventory();
        inventory.Add(new WindowsGpuAdapterInventory
        {
            CorrelationKey = software,
            DisplayIndex = 2,
            Name = "Software Adapter",
            DriverVersion = String.Empty,
            DedicatedMemoryCapacityBytes = 0,
            IsSoftware = true
        });
        List<WindowsGpuCounterObservation> observations = Observations();
        observations.Add(new WindowsGpuCounterObservation { InstanceName = "pid_400_" + software + "_eng_0_engtype_3D#1", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 0 });
        observations.Add(new WindowsGpuCounterObservation { InstanceName = software, Kind = WindowsGpuCounterKind.DedicatedMemoryBytes, Value = 0 });
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(inventory, observations);
        Assert(result.MappingChecksPass && result.Adapters.Count == 2, "An explicitly flagged DXGI software adapter contaminated hardware mapping.");
    }

    private static void PublicLiveReportIsSanitized()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(
            new FakeAdapterSource(true, String.Empty),
            new FakeCounterSource(true, String.Empty));
        WindowsGpuLiveReportDocument document = WindowsGpuLiveReport.Create(result, DateTime.Parse("2026-10-10T12:00:00Z").ToUniversalTime());
        string json = WindowsGpuLiveReport.Serialize(document);
        Assert(document.SchemaVersion == 3 && document.CounterProvider == "injected-fixture", "Public report omitted its explicit counter provider.");
        Assert(document.EngineLoadMappingChecksPass && document.DedicatedMemoryMappingChecksPass, "Public report omitted per-field mapping state.");
        Assert(json.Contains("live-windows-read-only", StringComparison.Ordinal), "Public report omitted its source boundary.");
        Assert(json.Contains("\"vramPercent\":33", StringComparison.Ordinal), "Public report did not derive bounded VRAM percentage.");
        Assert(!json.Contains("luid_", StringComparison.OrdinalIgnoreCase) && !json.Contains("pid_", StringComparison.OrdinalIgnoreCase), "Public report exposed a raw adapter or process identifier.");
        Assert(!json.Contains(result.InternalTopologyFingerprint, StringComparison.OrdinalIgnoreCase), "Public report exposed the internal topology fingerprint.");
        Assert(!document.CanUseInHud && !document.HardwareWrites && !document.NetworkAccess && !document.ElevationRequested && !document.RawAdapterIdentifiersIncluded, "Public report weakened a safety boundary.");
    }

    private static List<WindowsGpuAdapterInventory> Inventory()
    {
        return new List<WindowsGpuAdapterInventory>
        {
            new WindowsGpuAdapterInventory { CorrelationKey = AdapterA, DisplayIndex = 0, Name = "Fixture GPU", DriverVersion = "1.2.3.4", DedicatedMemoryCapacityBytes = 24_000_000_000L },
            new WindowsGpuAdapterInventory { CorrelationKey = AdapterB, DisplayIndex = 1, Name = "Fixture GPU", DriverVersion = "1.2.3.4", DedicatedMemoryCapacityBytes = 24_000_000_000L }
        };
    }

    private static List<WindowsGpuCounterObservation> Observations()
    {
        return new List<WindowsGpuCounterObservation>
        {
            new WindowsGpuCounterObservation { InstanceName = "pid_100_" + AdapterA + "_eng_0_engtype_3D", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 50 },
            new WindowsGpuCounterObservation { InstanceName = "pid_200_" + AdapterA + "_eng_0_engtype_3D", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 22 },
            new WindowsGpuCounterObservation { InstanceName = "pid_100_" + AdapterA + "_eng_1_engtype_Copy", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 18 },
            new WindowsGpuCounterObservation { InstanceName = AdapterA, Kind = WindowsGpuCounterKind.DedicatedMemoryBytes, Value = 8_000_000_000L },
            new WindowsGpuCounterObservation { InstanceName = "pid_300_" + AdapterB + "_eng_0_engtype_Compute_0", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 41 },
            new WindowsGpuCounterObservation { InstanceName = AdapterB, Kind = WindowsGpuCounterKind.DedicatedMemoryBytes, Value = 12_000_000_000L }
        };
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    private static int RunLiveProbe()
    {
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run();
        Console.WriteLine("ProbeStatus=" + result.ProbeStatus);
        Console.WriteLine("MappingChecksPass=" + result.MappingChecksPass);
        Console.WriteLine("AdapterCount=" + result.Adapters.Count);
        foreach (WindowsGpuMappedMetric adapter in result.Adapters)
        {
            Console.WriteLine(
                "Adapter " + adapter.DisplayIndex + ": " + adapter.Name +
                "; engine=" + adapter.EngineLoadPercent +
                "; dedicatedBytes=" + adapter.DedicatedMemoryBytes +
                "; capacityBytes=" + adapter.DedicatedMemoryCapacityBytes);
        }
        Console.WriteLine("ReasonCodes=" + String.Join(",", result.ReasonCodes));
        Console.WriteLine("CanUseInHud=" + result.CanUseInHud);
        Console.WriteLine("HardwareWrites=" + result.HardwareWrites);
        Console.WriteLine("NetworkAccess=" + result.NetworkAccess);
        Console.WriteLine("ElevationRequested=" + result.ElevationRequested);
        Console.WriteLine("RawAdapterIdentifiersIncluded=" + result.RawAdapterIdentifiersIncluded);
        return 0;
    }

    private sealed class FakeAdapterSource : IWindowsGpuAdapterSource
    {
        private readonly bool _success;
        private readonly string _reason;

        public FakeAdapterSource(bool success, string reason)
        {
            _success = success;
            _reason = reason;
        }

        public bool TryRead(out List<WindowsGpuAdapterInventory> adapters, out string reasonCode)
        {
            adapters = _success ? Inventory() : new List<WindowsGpuAdapterInventory>();
            reasonCode = _reason;
            return _success;
        }
    }

    private sealed class FakeCounterSource : IWindowsGpuCounterSource
    {
        private readonly bool _success;
        private readonly string _reason;

        public FakeCounterSource(bool success, string reason)
        {
            _success = success;
            _reason = reason;
        }

        public bool TryRead(out List<WindowsGpuCounterObservation> observations, out string reasonCode)
        {
            observations = _success ? Observations() : new List<WindowsGpuCounterObservation>();
            reasonCode = _reason;
            return _success;
        }
    }

    private sealed class MemoryOnlyCounterSource : IWindowsGpuCounterSource
    {
        public bool TryRead(out List<WindowsGpuCounterObservation> observations, out string reasonCode)
        {
            observations = Observations();
            observations.RemoveAll(delegate(WindowsGpuCounterObservation value)
            {
                return value.Kind == WindowsGpuCounterKind.EngineUtilizationPercent;
            });
            reasonCode = "pdh-engine-data-invalid";
            return true;
        }
    }
}
