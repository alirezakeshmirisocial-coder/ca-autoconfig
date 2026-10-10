using System;
using System.Collections.Generic;
using CA.SystemOverlay;

internal static class WindowsGpuPdhRawTests
{
    private const string Adapter = "luid_0x00000000_0x000000a1_phys_0";
    private const string EngineInstance = "pid_999_" + Adapter + "_eng_0_engtype_3D";

    internal static int RunAll()
    {
        var tests = new (string Name, Action Body)[]
        {
            ("raw PDH pairs the same engine instance", StableInstanceIsFormatted),
            ("raw PDH marks a new engine instance incomplete", NewInstanceNeedsBaseline),
            ("raw PDH ignores an instance absent from the current sample", DisappearedInstanceIsAbsent),
            ("raw PDH retains an invalid current status", InvalidCurrentStatusIsRetained),
            ("raw PDH retains a calculation failure", CalculationFailureIsRetained),
            ("raw PDH aggregates only compatible duplicate identities", DuplicateCurrentIdentityIsGuarded),
            ("raw PDH public report omits the internal process identity", PublicReportIsSanitized)
        };
        int passed = 0;
        foreach (var test in tests)
        {
            test.Body();
            passed++;
            Console.WriteLine("PASS " + test.Name);
        }
        return passed;
    }

    private static void StableInstanceIsFormatted()
    {
        FakeFormatter formatter = new FakeFormatter(true, 12.5, NativePdhGpuCounterReader.NewData);
        List<PdhGpuCounterSample> result = RawPdhEnginePairing.Format(
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 10),
            Samples(EngineInstance, NativePdhGpuCounterReader.NewData, 20),
            formatter);
        Assert(result.Count == 1 && result[0].Value == 12.5 &&
            result[0].CounterStatus == NativePdhGpuCounterReader.NewData &&
            String.IsNullOrWhiteSpace(result[0].FailureReasonCode), "Stable raw pair was not formatted.");
        Assert(formatter.CallCount == 1 && formatter.LastCurrent.FirstValue == 20 &&
            formatter.LastPrevious.FirstValue == 10, "Raw values were not passed in current/previous order.");
    }

    private static void NewInstanceNeedsBaseline()
    {
        FakeFormatter formatter = new FakeFormatter(true, 0, NativePdhGpuCounterReader.ValidData);
        List<PdhGpuCounterSample> result = RawPdhEnginePairing.Format(
            new List<PdhRawCounterSample>(),
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 20),
            formatter);
        Assert(result.Count == 1 && result[0].FailureReasonCode == "pdh-engine-baseline-missing" &&
            formatter.CallCount == 0, "New instance was converted into a plausible zero.");

        const string olderInstance = "pid_888_" + Adapter + "_eng_1_engtype_Copy";
        formatter = new FakeFormatter(true, 0, NativePdhGpuCounterReader.ValidData);
        List<PdhRawCounterSample> previous = Samples(olderInstance, NativePdhGpuCounterReader.ValidData, 4);
        PdhRawCounterSample previousValue = previous[0];
        PdhRawCounterValue rawPrevious = previousValue.Value;
        rawPrevious.SecondValue = 100;
        previousValue.Value = rawPrevious;
        List<PdhRawCounterSample> current = Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 0);
        PdhRawCounterSample currentValue = current[0];
        PdhRawCounterValue rawCurrent = currentValue.Value;
        rawCurrent.SecondValue = 200;
        currentValue.Value = rawCurrent;
        result = RawPdhEnginePairing.Format(previous, current, formatter);
        Assert(result.Count == 1 && String.IsNullOrWhiteSpace(result[0].FailureReasonCode) &&
            formatter.CallCount == 1 && formatter.LastPrevious.FirstValue == 0 &&
            formatter.LastPrevious.SecondValue == 100, "Provable zero-valued new instance was not given the prior collection timebase.");

        formatter = new FakeFormatter(true, 0, NativePdhGpuCounterReader.ValidData);
        rawCurrent.MultiCount = 2;
        currentValue.Value = rawCurrent;
        result = RawPdhEnginePairing.Format(previous, current, formatter);
        Assert(result.Count == 1 && result[0].FailureReasonCode == "pdh-engine-baseline-missing" &&
            formatter.CallCount == 0, "Zero baseline crossed incompatible MultiCount metadata.");
    }

    private static void DisappearedInstanceIsAbsent()
    {
        FakeFormatter formatter = new FakeFormatter(true, 0, NativePdhGpuCounterReader.ValidData);
        List<PdhGpuCounterSample> result = RawPdhEnginePairing.Format(
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 10),
            new List<PdhRawCounterSample>(),
            formatter);
        Assert(result.Count == 0 && formatter.CallCount == 0, "A disappeared instance remained in the current aggregation.");
    }

    private static void InvalidCurrentStatusIsRetained()
    {
        FakeFormatter formatter = new FakeFormatter(true, 0, NativePdhGpuCounterReader.ValidData);
        List<PdhGpuCounterSample> result = RawPdhEnginePairing.Format(
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 10),
            Samples(EngineInstance, NativePdhGpuCounterReader.InvalidData, 5),
            formatter);
        Assert(result.Count == 1 && result[0].CounterStatus == NativePdhGpuCounterReader.InvalidData &&
            formatter.CallCount == 0, "Invalid raw status reached the formatter or disappeared.");
    }

    private static void CalculationFailureIsRetained()
    {
        FakeFormatter formatter = new FakeFormatter(false, 0, NativePdhGpuCounterReader.InvalidData);
        List<PdhGpuCounterSample> result = RawPdhEnginePairing.Format(
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 10),
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 20),
            formatter);
        Assert(result.Count == 1 && result[0].FailureReasonCode == "pdh-engine-raw-calculation-failed" &&
            formatter.CallCount == 1, "Raw calculation failure was hidden.");
    }

    private static void DuplicateCurrentIdentityIsGuarded()
    {
        FakeFormatter formatter = new FakeFormatter(true, 7, NativePdhGpuCounterReader.ValidData);
        List<PdhRawCounterSample> current = Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 20);
        current.Add(current[0]);
        List<PdhGpuCounterSample> result = RawPdhEnginePairing.Format(
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 10),
            current,
            formatter);
        Assert(result.Count == 1 && String.IsNullOrWhiteSpace(result[0].FailureReasonCode) &&
            formatter.LastCurrent.FirstValue == 40, "Compatible duplicate numerators were not aggregated safely.");

        formatter = new FakeFormatter(true, 7, NativePdhGpuCounterReader.ValidData);
        current = Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 20);
        List<PdhRawCounterSample> incompatible = Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 20);
        PdhRawCounterSample changed = incompatible[0];
        PdhRawCounterValue changedValue = changed.Value;
        changedValue.SecondValue = 101;
        changed.Value = changedValue;
        current.Add(changed);
        result = RawPdhEnginePairing.Format(
            Samples(EngineInstance, NativePdhGpuCounterReader.ValidData, 10),
            current,
            formatter);
        Assert(result.Count == 1 && result[0].FailureReasonCode == "pdh-engine-instance-duplicate" &&
            formatter.CallCount == 0, "Incompatible duplicate raw identity was guessed or formatted.");
    }

    private static void PublicReportIsSanitized()
    {
        PdhWindowsGpuCounterSource counterSource = new PdhWindowsGpuCounterSource(new BaselineMissingReader());
        WindowsGpuLiveProbeResult result = WindowsGpuLiveProbe.Run(new AdapterSource(), counterSource);
        WindowsGpuLiveReportDocument report = WindowsGpuLiveReport.Create(result, DateTime.UtcNow);
        string json = WindowsGpuLiveReport.Serialize(report);
        Assert(result.ProbeStatus == "PARTIAL_MAPPING_AVAILABLE" && !report.Adapters[0].EngineLoadAvailable &&
            report.Adapters[0].DedicatedMemoryAvailable, "Raw partial source did not preserve healthy memory.");
        Assert(json.Contains("pdh-engine-baseline-missing-adapter-0", StringComparison.Ordinal) &&
            !json.Contains("pid_", StringComparison.OrdinalIgnoreCase) &&
            !json.Contains("luid_", StringComparison.OrdinalIgnoreCase), "Raw process identity entered public output.");
        Assert(!report.CanUseInHud && !report.HardwareWrites && !report.NetworkAccess &&
            !report.ElevationRequested && !report.RawAdapterIdentifiersIncluded, "Raw research report weakened a safety boundary.");
    }

    private static List<PdhRawCounterSample> Samples(string name, uint status, long firstValue)
    {
        return new List<PdhRawCounterSample>
        {
            new PdhRawCounterSample
            {
                InstanceName = name,
                Value = new PdhRawCounterValue
                {
                    CounterStatus = status,
                    FirstValue = firstValue,
                    SecondValue = 100,
                    MultiCount = 1
                }
            }
        };
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    private sealed class FakeFormatter : IPdhRawValueFormatter
    {
        private readonly bool _success;
        private readonly double _value;
        private readonly uint _status;
        internal int CallCount;
        internal PdhRawCounterValue LastCurrent;
        internal PdhRawCounterValue LastPrevious;

        internal FakeFormatter(bool success, double value, uint status)
        {
            _success = success;
            _value = value;
            _status = status;
        }

        public bool TryFormat(
            PdhRawCounterValue current,
            PdhRawCounterValue previous,
            out double value,
            out uint counterStatus)
        {
            CallCount++;
            LastCurrent = current;
            LastPrevious = previous;
            value = _value;
            counterStatus = _status;
            return _success;
        }
    }

    private sealed class AdapterSource : IWindowsGpuAdapterSource
    {
        public bool TryRead(out List<WindowsGpuAdapterInventory> adapters, out string reasonCode)
        {
            adapters = new List<WindowsGpuAdapterInventory>
            {
                new WindowsGpuAdapterInventory
                {
                    CorrelationKey = Adapter,
                    DisplayIndex = 0,
                    Name = "GPU A",
                    DedicatedMemoryCapacityBytes = 100,
                    IsSoftware = false
                }
            };
            reasonCode = String.Empty;
            return true;
        }
    }

    private sealed class BaselineMissingReader : IPdhGpuCounterReader
    {
        public bool TryRead(out List<PdhGpuCounterSample> samples, out string reasonCode)
        {
            samples = new List<PdhGpuCounterSample>
            {
                new PdhGpuCounterSample
                {
                    InstanceName = EngineInstance,
                    Kind = WindowsGpuCounterKind.EngineUtilizationPercent,
                    Value = Double.NaN,
                    CounterStatus = NativePdhGpuCounterReader.InvalidData,
                    FailureReasonCode = "pdh-engine-baseline-missing"
                },
                new PdhGpuCounterSample
                {
                    InstanceName = Adapter,
                    Kind = WindowsGpuCounterKind.DedicatedMemoryBytes,
                    Value = 25,
                    CounterStatus = NativePdhGpuCounterReader.ValidData
                }
            };
            reasonCode = String.Empty;
            return true;
        }
    }
}
