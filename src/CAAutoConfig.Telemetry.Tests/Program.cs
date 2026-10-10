using System;
using System.Collections.Generic;
using CA.SystemOverlay;

internal static class Program
{
    private const string AdapterA = "luid_0x00000000_0x000000a1_phys_0";
    private const string AdapterB = "luid_0x00000000_0x000000b2_phys_0";
    private static int _passed;

    private static int Main()
    {
        var tests = new (string Name, Action Body)[]
        {
            ("duplicate model names map by internal identity", DuplicateNamesMapByIdentity),
            ("counter enumeration reorder is stable", CounterReorderIsStable),
            ("adapter enumeration reorder preserves display rows", AdapterReorderIsStable),
            ("unknown counter adapter fails closed", UnknownCounterAdapterFailsClosed),
            ("missing memory counter fails closed", MissingMemoryFailsClosed),
            ("malformed identity fails closed", MalformedIdentityFailsClosed),
            ("duplicate adapter identity fails closed", DuplicateAdapterIdentityFailsClosed),
            ("public result omits raw adapter identity", PublicResultOmitsRawIdentity),
            ("engine aggregation uses busiest engine", EngineAggregationUsesBusiestEngine)
        };

        try
        {
            foreach (var test in tests)
            {
                test.Body();
                _passed++;
                Console.WriteLine("PASS " + test.Name);
            }
            Console.WriteLine(_passed + " Windows GPU counter-mapping tests passed. Fixtures performed no hardware access.");
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
        List<WindowsGpuCounterObservation> observations = Observations();
        observations.Reverse();
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(Inventory(), observations);
        Assert(result.MappingChecksPass, "Reordered counters failed mapping.");
        Assert(result.Adapters[0].EngineLoadPercent == 72 && result.Adapters[1].EngineLoadPercent == 41, "Counter reorder changed the adapter assignment.");
    }

    private static void AdapterReorderIsStable()
    {
        List<WindowsGpuAdapterInventory> inventory = Inventory();
        inventory.Reverse();
        WindowsGpuCounterMapResult result = WindowsGpuCounterMapper.Map(inventory, Observations());
        Assert(result.MappingChecksPass, "Reordered inventory failed mapping.");
        Assert(result.Adapters[0].DisplayIndex == 0 && result.Adapters[0].EngineLoadPercent == 72, "Display row 0 changed after inventory reorder.");
        Assert(result.Adapters[1].DisplayIndex == 1 && result.Adapters[1].EngineLoadPercent == 41, "Display row 1 changed after inventory reorder.");
    }

    private static void UnknownCounterAdapterFailsClosed()
    {
        List<WindowsGpuCounterObservation> observations = Observations();
        observations.Add(new WindowsGpuCounterObservation
        {
            InstanceName = "luid_0x0_0xdead_phys_0_eng_0_engtype_3D",
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

    private static List<WindowsGpuAdapterInventory> Inventory()
    {
        return new List<WindowsGpuAdapterInventory>
        {
            new WindowsGpuAdapterInventory { CorrelationKey = AdapterA, DisplayIndex = 0, Name = "Fixture GPU", DriverVersion = "1.2.3.4" },
            new WindowsGpuAdapterInventory { CorrelationKey = AdapterB, DisplayIndex = 1, Name = "Fixture GPU", DriverVersion = "1.2.3.4" }
        };
    }

    private static List<WindowsGpuCounterObservation> Observations()
    {
        return new List<WindowsGpuCounterObservation>
        {
            new WindowsGpuCounterObservation { InstanceName = AdapterA + "_eng_0_engtype_3D", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 72 },
            new WindowsGpuCounterObservation { InstanceName = AdapterA + "_eng_1_engtype_Copy", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 18 },
            new WindowsGpuCounterObservation { InstanceName = AdapterA, Kind = WindowsGpuCounterKind.DedicatedMemoryBytes, Value = 8_000_000_000L },
            new WindowsGpuCounterObservation { InstanceName = AdapterB + "_eng_0_engtype_Compute_0", Kind = WindowsGpuCounterKind.EngineUtilizationPercent, Value = 41 },
            new WindowsGpuCounterObservation { InstanceName = AdapterB, Kind = WindowsGpuCounterKind.DedicatedMemoryBytes, Value = 12_000_000_000L }
        };
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}
