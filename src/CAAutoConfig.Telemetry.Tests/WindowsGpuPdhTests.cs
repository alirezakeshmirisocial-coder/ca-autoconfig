using System;
using System.Collections.Generic;
using CA.SystemOverlay;

internal static class WindowsGpuPdhTests
{
    internal static int RunAll()
    {
        var tests = new (string Name, Action Body)[]
        {
            ("PDH source accepts only valid counter statuses", ValidSamplesAreTranslated),
            ("PDH source rejects an invalid counter status", InvalidStatusFailsClosed),
            ("PDH source distinguishes an invalid memory status", InvalidMemoryStatusIsDistinguished),
            ("PDH source identifies a disappeared engine instance", DisappearedInstanceIsDistinguished),
            ("PDH source retains a native failure reason", NativeFailureIsRetained),
            ("PDH source rejects an empty successful collection", EmptyCollectionFailsClosed),
            ("PDH source rejects a blank counter instance", BlankInstanceFailsClosed)
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

    private static void ValidSamplesAreTranslated()
    {
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, Samples()));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(source.TryRead(out observations, out reason), "Valid PDH fixture did not pass.");
        Assert(observations.Count == 2, "PDH fixture did not retain both counter kinds.");
        Assert(observations[0].Value == 42.5 && observations[1].Value == 8_000_000_000d, "PDH values changed during translation.");
    }

    private static void InvalidStatusFailsClosed()
    {
        List<PdhGpuCounterSample> samples = Samples();
        samples[0].CounterStatus = NativePdhGpuCounterReader.InvalidData;
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, samples));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "Invalid PDH status was accepted.");
        Assert(reason == "pdh-engine-data-invalid" && observations.Count == 0, "Invalid status did not fail closed with a sanitized reason.");
    }

    private static void NativeFailureIsRetained()
    {
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(
            new FakeReader(false, "pdh-second-collection-failed", new List<PdhGpuCounterSample>()));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "Native failure was accepted.");
        Assert(reason == "pdh-second-collection-failed" && observations.Count == 0, "Native failure reason was hidden.");
    }

    private static void InvalidMemoryStatusIsDistinguished()
    {
        List<PdhGpuCounterSample> samples = Samples();
        samples[1].CounterStatus = NativePdhGpuCounterReader.InvalidData;
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, samples));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "Invalid PDH memory status was accepted.");
        Assert(reason == "pdh-memory-data-invalid" && observations.Count == 0, "Memory status failure was not distinguished.");
    }

    private static void DisappearedInstanceIsDistinguished()
    {
        List<PdhGpuCounterSample> samples = Samples();
        samples[0].CounterStatus = NativePdhGpuCounterReader.NoInstance;
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, samples));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "Disappeared engine instance was accepted.");
        Assert(reason == "pdh-engine-instance-disappeared" && observations.Count == 0, "Disappeared instance was not classified safely.");
    }

    private static void EmptyCollectionFailsClosed()
    {
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(
            new FakeReader(true, String.Empty, new List<PdhGpuCounterSample>()));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "Empty PDH collection was accepted.");
        Assert(reason == "pdh-counter-query-empty", "Empty collection reason changed.");
    }

    private static void BlankInstanceFailsClosed()
    {
        List<PdhGpuCounterSample> samples = Samples();
        samples[0].InstanceName = " ";
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, samples));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "Blank PDH instance was accepted.");
        Assert(reason == "pdh-counter-instance-invalid" && observations.Count == 0, "Blank instance did not fail closed.");
    }

    private static List<PdhGpuCounterSample> Samples()
    {
        return new List<PdhGpuCounterSample>
        {
            new PdhGpuCounterSample
            {
                InstanceName = "pid_100_luid_0x00000000_0x000000a1_phys_0_eng_0_engtype_3D",
                Kind = WindowsGpuCounterKind.EngineUtilizationPercent,
                Value = 42.5,
                CounterStatus = NativePdhGpuCounterReader.NewData
            },
            new PdhGpuCounterSample
            {
                InstanceName = "luid_0x00000000_0x000000a1_phys_0",
                Kind = WindowsGpuCounterKind.DedicatedMemoryBytes,
                Value = 8_000_000_000d,
                CounterStatus = NativePdhGpuCounterReader.ValidData
            }
        };
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    private sealed class FakeReader : IPdhGpuCounterReader
    {
        private readonly bool _success;
        private readonly string _reason;
        private readonly List<PdhGpuCounterSample> _samples;

        internal FakeReader(bool success, string reason, List<PdhGpuCounterSample> samples)
        {
            _success = success;
            _reason = reason;
            _samples = samples;
        }

        public bool TryRead(out List<PdhGpuCounterSample> samples, out string reasonCode)
        {
            samples = _samples;
            reasonCode = _reason;
            return _success;
        }
    }
}
