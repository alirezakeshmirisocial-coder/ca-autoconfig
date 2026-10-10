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
            ("PDH source isolates an invalid engine status", InvalidStatusFailsClosed),
            ("PDH source distinguishes an invalid memory status", InvalidMemoryStatusIsDistinguished),
            ("PDH source fails when every metric family is invalid", EveryFamilyInvalidFails),
            ("PDH source identifies a disappeared engine instance", DisappearedInstanceIsDistinguished),
            ("PDH source retains a native failure reason", NativeFailureIsRetained),
            ("PDH source rejects an empty successful collection", EmptyCollectionFailsClosed),
            ("PDH source rejects a blank counter instance", BlankInstanceFailsClosed),
            ("PDH source disposes its stateful reader", SourceDisposesReader)
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
        Assert(source.TryRead(out observations, out reason), "Healthy memory evidence was discarded with an invalid engine family.");
        Assert(reason == "pdh-engine-data-invalid" && observations.Count == 1 && observations[0].Kind == WindowsGpuCounterKind.DedicatedMemoryBytes, "Invalid engine status did not isolate the failed family.");
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
        Assert(source.TryRead(out observations, out reason), "Healthy engine evidence was discarded with an invalid memory family.");
        Assert(reason == "pdh-memory-data-invalid" && observations.Count == 1 && observations[0].Kind == WindowsGpuCounterKind.EngineUtilizationPercent, "Memory status failure was not isolated.");
    }

    private static void EveryFamilyInvalidFails()
    {
        List<PdhGpuCounterSample> samples = Samples();
        samples[0].CounterStatus = NativePdhGpuCounterReader.InvalidData;
        samples[1].CounterStatus = NativePdhGpuCounterReader.InvalidData;
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, samples));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(!source.TryRead(out observations, out reason), "A sample with no valid metric family was accepted.");
        Assert(reason == "pdh-engine-data-invalid" && observations.Count == 0, "All-invalid sample did not fail with deterministic evidence.");
    }

    private static void DisappearedInstanceIsDistinguished()
    {
        List<PdhGpuCounterSample> samples = Samples();
        samples[0].CounterStatus = NativePdhGpuCounterReader.NoInstance;
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(new FakeReader(true, String.Empty, samples));
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(source.TryRead(out observations, out reason), "Disappeared engine instance discarded healthy memory evidence.");
        Assert(reason == "pdh-engine-instance-disappeared" && observations.Count == 1 && observations[0].Kind == WindowsGpuCounterKind.DedicatedMemoryBytes, "Disappeared instance was not isolated safely.");
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
        Assert(source.TryRead(out observations, out reason), "Blank engine instance discarded the healthy memory family.");
        Assert(reason == "pdh-engine-instance-invalid" && observations.Count == 1 && observations[0].Kind == WindowsGpuCounterKind.DedicatedMemoryBytes, "Blank instance was not isolated to its family.");
    }

    private static void SourceDisposesReader()
    {
        FakeReader reader = new FakeReader(true, String.Empty, Samples());
        PdhWindowsGpuCounterSource source = new PdhWindowsGpuCounterSource(reader);
        source.Dispose();
        source.Dispose();
        List<WindowsGpuCounterObservation> observations;
        string reason;
        Assert(reader.DisposeCount == 1, "Stateful PDH reader was not disposed exactly once.");
        Assert(!source.TryRead(out observations, out reason) && reason == "pdh-source-disposed", "Disposed source accepted another read.");
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

    private sealed class FakeReader : IPdhGpuCounterReader, IDisposable
    {
        private readonly bool _success;
        private readonly string _reason;
        private readonly List<PdhGpuCounterSample> _samples;
        internal int DisposeCount { get; private set; }

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

        public void Dispose()
        {
            DisposeCount++;
        }
    }
}
