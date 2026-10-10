using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace CA.SystemOverlay
{
    internal sealed class PdhGpuCounterSample
    {
        public string InstanceName;
        public WindowsGpuCounterKind Kind;
        public double Value;
        public uint CounterStatus;
    }

    internal interface IPdhGpuCounterReader
    {
        bool TryRead(out List<PdhGpuCounterSample> samples, out string reasonCode);
    }

    // Research-only PDH source. It is deliberately separate from the WMI
    // implementation so sustained evidence can compare the two paths without
    // silently falling back or masking an invalid sample.
    internal sealed class PdhWindowsGpuCounterSource : IWindowsGpuCounterSource, IDisposable
    {
        private readonly IPdhGpuCounterReader _reader;
        private int _disposed;

        internal PdhWindowsGpuCounterSource()
            : this(new NativePdhGpuCounterReader())
        {
        }

        internal PdhWindowsGpuCounterSource(IPdhGpuCounterReader reader)
        {
            if (reader == null)
                throw new ArgumentNullException("reader");
            _reader = reader;
        }

        public bool TryRead(out List<WindowsGpuCounterObservation> observations, out string reasonCode)
        {
            observations = new List<WindowsGpuCounterObservation>();
            reasonCode = String.Empty;
            if (Volatile.Read(ref _disposed) != 0)
            {
                reasonCode = "pdh-source-disposed";
                return false;
            }
            List<PdhGpuCounterSample> samples;
            if (!_reader.TryRead(out samples, out reasonCode))
            {
                if (String.IsNullOrWhiteSpace(reasonCode))
                    reasonCode = "pdh-counter-query-failed";
                return false;
            }
            if (samples == null || samples.Count == 0)
            {
                reasonCode = "pdh-counter-query-empty";
                return false;
            }

            foreach (PdhGpuCounterSample sample in samples)
            {
                if (sample == null)
                {
                    observations.Clear();
                    reasonCode = "pdh-counter-instance-invalid";
                    return false;
                }
                if (String.IsNullOrWhiteSpace(sample.InstanceName))
                {
                    SetFirstReason(ref reasonCode, GetFamilyReason(sample.Kind, "instance-invalid"));
                    observations.Add(new WindowsGpuCounterObservation
                    {
                        InstanceName = sample.InstanceName ?? String.Empty,
                        Kind = sample.Kind,
                        Value = Double.NaN,
                        FailureReasonCode = GetFamilyReason(sample.Kind, "instance-invalid")
                    });
                    continue;
                }
                if (sample.CounterStatus != NativePdhGpuCounterReader.ValidData &&
                    sample.CounterStatus != NativePdhGpuCounterReader.NewData)
                {
                    observations.Add(new WindowsGpuCounterObservation
                    {
                        InstanceName = sample.InstanceName,
                        Kind = sample.Kind,
                        Value = Double.NaN,
                        FailureReasonCode = GetInvalidStatusReason(sample.Kind, sample.CounterStatus)
                    });
                    continue;
                }
                observations.Add(new WindowsGpuCounterObservation
                {
                    InstanceName = sample.InstanceName,
                    Kind = sample.Kind,
                    Value = sample.Value
                });
            }

            // Invalid items remain internal observations so the mapper can
            // invalidate only the matching adapter field. Public reports retain
            // sanitized adapter-index reason codes and never expose instance names.
            return observations.Count > 0;
        }

        private static void SetFirstReason(ref string destination, string reason)
        {
            if (String.IsNullOrWhiteSpace(destination))
                destination = reason;
        }

        private static string GetFamilyReason(WindowsGpuCounterKind kind, string suffix)
        {
            string family = kind == WindowsGpuCounterKind.EngineUtilizationPercent ? "engine" : "memory";
            return "pdh-" + family + "-" + suffix;
        }

        private static string GetInvalidStatusReason(WindowsGpuCounterKind kind, uint status)
        {
            string family = kind == WindowsGpuCounterKind.EngineUtilizationPercent ? "engine" : "memory";
            if (status == NativePdhGpuCounterReader.NoInstance)
                return "pdh-" + family + "-instance-disappeared";
            if (status == NativePdhGpuCounterReader.ItemNotValidated)
                return "pdh-" + family + "-not-validated";
            if (status == NativePdhGpuCounterReader.InvalidData)
                return "pdh-" + family + "-data-invalid";
            return "pdh-" + family + "-counter-status-invalid";
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;
            IDisposable disposable = _reader as IDisposable;
            if (disposable != null)
                disposable.Dispose();
        }
    }

    // PDH stores the previous and current raw values on the query. Keep one
    // query for the bounded polling lifetime, collect the baseline only once,
    // and close/reset on a fatal query or array error.
    internal sealed class NativePdhGpuCounterReader : IPdhGpuCounterReader, IDisposable
    {
        internal const uint ValidData = 0x00000000;
        internal const uint NewData = 0x00000001;
        internal const uint NoInstance = 0x800007D1;
        internal const uint ItemNotValidated = 0x800007D3;
        internal const uint InvalidData = 0xC0000BBA;
        private const uint ErrorSuccess = 0x00000000;
        private const uint MoreData = 0x800007D2;
        private const uint FormatDouble = 0x00000200;
        private const uint FormatNoCap100 = 0x00008000;
        private const int SampleIntervalMilliseconds = 1000;
        private const uint MaximumBufferBytes = 64 * 1024 * 1024;
        private const uint MaximumItemCount = 32768;
        private const string EnginePath = @"\GPU Engine(*)\Utilization Percentage";
        private const string MemoryPath = @"\GPU Adapter Memory(*)\Dedicated Usage";
        private readonly object _sync = new object();
        private IntPtr _query;
        private IntPtr _engineCounter;
        private IntPtr _memoryCounter;
        private bool _hasBaseline;
        private bool _disposed;

        public bool TryRead(out List<PdhGpuCounterSample> samples, out string reasonCode)
        {
            samples = new List<PdhGpuCounterSample>();
            reasonCode = String.Empty;
            lock (_sync)
            {
                if (_disposed)
                    return Fail(samples, out reasonCode, "pdh-reader-disposed");
                try
                {
                    if (!EnsureQueryLocked(out reasonCode))
                        return Fail(samples, out reasonCode, reasonCode);

                    uint status;
                    if (!_hasBaseline)
                    {
                        status = PdhCollectQueryData(_query);
                        if (status != ErrorSuccess)
                            return ResetAndFail(samples, out reasonCode, "pdh-first-collection-failed");
                        _hasBaseline = true;
                        Thread.Sleep(SampleIntervalMilliseconds);
                    }

                    status = PdhCollectQueryData(_query);
                    if (status != ErrorSuccess)
                        return ResetAndFail(samples, out reasonCode, "pdh-next-collection-failed");

                    bool engineContainsInvalidStatus;
                    if (!TryReadArray(
                        _engineCounter,
                        WindowsGpuCounterKind.EngineUtilizationPercent,
                        samples,
                        out engineContainsInvalidStatus,
                        out reasonCode))
                        return ResetAndFail(samples, out reasonCode, reasonCode);
                    bool memoryContainsInvalidStatus;
                    if (!TryReadArray(
                        _memoryCounter,
                        WindowsGpuCounterKind.DedicatedMemoryBytes,
                        samples,
                        out memoryContainsInvalidStatus,
                        out reasonCode))
                        return ResetAndFail(samples, out reasonCode, reasonCode);
                    if (samples.Count == 0)
                        return ResetAndFail(samples, out reasonCode, "pdh-counter-query-empty");

                    // An invalid formatted item means PDH could not safely compare
                    // its current and previous raw values. Return the item so this
                    // collection fails closed for the mapped adapter, then discard
                    // the query state. The next collection must establish a fresh
                    // baseline instead of remaining stuck behind a regressed or
                    // disappeared process-scoped GPU Engine instance.
                    if (engineContainsInvalidStatus || memoryContainsInvalidStatus)
                        ResetQueryLocked();
                    return true;
                }
                catch (DllNotFoundException)
                {
                    return ResetAndFail(samples, out reasonCode, "pdh-unavailable");
                }
                catch (EntryPointNotFoundException)
                {
                    return ResetAndFail(samples, out reasonCode, "pdh-unavailable");
                }
                catch
                {
                    return ResetAndFail(samples, out reasonCode, "pdh-counter-query-failed");
                }
            }
        }

        private bool EnsureQueryLocked(out string reasonCode)
        {
            reasonCode = String.Empty;
            if (_query != IntPtr.Zero)
                return true;

            uint status = PdhOpenQueryW(null, UIntPtr.Zero, out _query);
            if (status != ErrorSuccess || _query == IntPtr.Zero)
            {
                ResetQueryLocked();
                reasonCode = "pdh-query-open-failed";
                return false;
            }

            status = PdhAddEnglishCounterW(_query, EnginePath, UIntPtr.Zero, out _engineCounter);
            if (status != ErrorSuccess || _engineCounter == IntPtr.Zero)
            {
                ResetQueryLocked();
                reasonCode = "pdh-engine-counter-add-failed";
                return false;
            }

            status = PdhAddEnglishCounterW(_query, MemoryPath, UIntPtr.Zero, out _memoryCounter);
            if (status != ErrorSuccess || _memoryCounter == IntPtr.Zero)
            {
                ResetQueryLocked();
                reasonCode = "pdh-memory-counter-add-failed";
                return false;
            }
            return true;
        }

        private bool ResetAndFail<T>(List<T> values, out string reasonCode, string code)
        {
            ResetQueryLocked();
            return Fail(values, out reasonCode, code);
        }

        private void ResetQueryLocked()
        {
            if (_query != IntPtr.Zero)
                PdhCloseQuery(_query);
            _query = IntPtr.Zero;
            _engineCounter = IntPtr.Zero;
            _memoryCounter = IntPtr.Zero;
            _hasBaseline = false;
        }

        public void Dispose()
        {
            lock (_sync)
            {
                if (_disposed)
                    return;
                _disposed = true;
                ResetQueryLocked();
            }
        }

        private static bool TryReadArray(
            IntPtr counter,
            WindowsGpuCounterKind kind,
            List<PdhGpuCounterSample> destination,
            out bool containsInvalidStatus,
            out string reasonCode)
        {
            containsInvalidStatus = false;
            reasonCode = String.Empty;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                uint bufferBytes = 0;
                uint itemCount = 0;
                uint status = PdhGetFormattedCounterArrayW(
                    counter,
                    FormatDouble | FormatNoCap100,
                    ref bufferBytes,
                    out itemCount,
                    IntPtr.Zero);
                if (status != MoreData || bufferBytes == 0 || bufferBytes > MaximumBufferBytes || itemCount > MaximumItemCount)
                    return Fail(destination, out reasonCode, "pdh-counter-array-size-failed");

                IntPtr buffer = Marshal.AllocHGlobal(checked((int)bufferBytes));
                try
                {
                    status = PdhGetFormattedCounterArrayW(
                        counter,
                        FormatDouble | FormatNoCap100,
                        ref bufferBytes,
                        out itemCount,
                        buffer);
                    if (status == MoreData)
                        continue;
                    if (status != ErrorSuccess || itemCount == 0 || itemCount > MaximumItemCount)
                        return Fail(destination, out reasonCode, "pdh-counter-array-read-failed");

                    int itemSize = Marshal.SizeOf<PdhFormattedCounterValueItem>();
                    for (uint index = 0; index < itemCount; index++)
                    {
                        IntPtr itemPointer = IntPtr.Add(buffer, checked((int)index * itemSize));
                        PdhFormattedCounterValueItem item = Marshal.PtrToStructure<PdhFormattedCounterValueItem>(itemPointer);
                        destination.Add(new PdhGpuCounterSample
                        {
                            InstanceName = Marshal.PtrToStringUni(item.Name) ?? String.Empty,
                            Kind = kind,
                            Value = item.Value.Value.DoubleValue,
                            CounterStatus = item.Value.CounterStatus
                        });
                        if (item.Value.CounterStatus != ValidData && item.Value.CounterStatus != NewData)
                            containsInvalidStatus = true;
                    }
                    return true;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            return Fail(destination, out reasonCode, "pdh-counter-array-unstable");
        }

        private static bool Fail<T>(List<T> values, out string reasonCode, string code)
        {
            values.Clear();
            reasonCode = code;
            return false;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct PdhFormattedValueUnion
        {
            [FieldOffset(0)] public int LongValue;
            [FieldOffset(0)] public double DoubleValue;
            [FieldOffset(0)] public long LargeValue;
            [FieldOffset(0)] public IntPtr PointerValue;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PdhFormattedCounterValue
        {
            public uint CounterStatus;
            public PdhFormattedValueUnion Value;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PdhFormattedCounterValueItem
        {
            public IntPtr Name;
            public PdhFormattedCounterValue Value;
        }

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhOpenQueryW(string dataSource, UIntPtr userData, out IntPtr query);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhAddEnglishCounterW(
            IntPtr query,
            string fullCounterPath,
            UIntPtr userData,
            out IntPtr counter);

        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhCollectQueryData(IntPtr query);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhGetFormattedCounterArrayW(
            IntPtr counter,
            uint format,
            ref uint bufferSize,
            out uint itemCount,
            IntPtr itemBuffer);

        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhCloseQuery(IntPtr query);
    }
}
