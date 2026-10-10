using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace CA.SystemOverlay
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct PdhRawFileTime
    {
        public uint LowDateTime;
        public uint HighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PdhRawCounterValue
    {
        public uint CounterStatus;
        public PdhRawFileTime TimeStamp;
        public long FirstValue;
        public long SecondValue;
        public uint MultiCount;
    }

    internal sealed class PdhRawCounterSample
    {
        public string InstanceName;
        public PdhRawCounterValue Value;
    }

    internal interface IPdhRawValueFormatter
    {
        bool TryFormat(
            PdhRawCounterValue current,
            PdhRawCounterValue previous,
            out double value,
            out uint counterStatus);
    }

    // Pure matching boundary for the native raw-PDH experiment. Raw instance
    // names remain internal and are required only to match the same process and
    // physical engine across adjacent collections. New instances fail closed
    // for one interval; disappeared instances are absent from the current set.
    internal static class RawPdhEnginePairing
    {
        internal static List<PdhGpuCounterSample> Format(
            IEnumerable<PdhRawCounterSample> previousSamples,
            IEnumerable<PdhRawCounterSample> currentSamples,
            IPdhRawValueFormatter formatter)
        {
            if (previousSamples == null)
                throw new ArgumentNullException("previousSamples");
            if (currentSamples == null)
                throw new ArgumentNullException("currentSamples");
            if (formatter == null)
                throw new ArgumentNullException("formatter");

            AggregatedSet previous = Aggregate(previousSamples, false);
            AggregatedSet current = Aggregate(currentSamples, true);
            List<PdhGpuCounterSample> output = current.Failures;
            foreach (KeyValuePair<string, PdhRawCounterValue> pair in current.Values)
            {
                string name = pair.Key;
                PdhRawCounterValue older;
                if (!previous.Values.TryGetValue(name, out older))
                {
                    if (pair.Value.FirstValue != 0 ||
                        !TryCreateZeroBaseline(previous.Values.Values, pair.Value, out older))
                    {
                        output.Add(Failure(name, "pdh-engine-baseline-missing"));
                        continue;
                    }
                }

                double value;
                uint status;
                if (!formatter.TryFormat(pair.Value, older, out value, out status))
                {
                    output.Add(Failure(name, "pdh-engine-raw-calculation-failed"));
                    continue;
                }
                output.Add(new PdhGpuCounterSample
                {
                    InstanceName = name,
                    Kind = WindowsGpuCounterKind.EngineUtilizationPercent,
                    Value = value,
                    CounterStatus = status
                });
            }
            return output;
        }

        private static bool TryCreateZeroBaseline(
            IEnumerable<PdhRawCounterValue> previousValues,
            PdhRawCounterValue current,
            out PdhRawCounterValue baseline)
        {
            baseline = current;
            bool found = false;
            long secondValue = 0;
            PdhRawFileTime timeStamp = default(PdhRawFileTime);
            uint multiCount = 0;
            foreach (PdhRawCounterValue value in previousValues)
            {
                if (!found)
                {
                    found = true;
                    secondValue = value.SecondValue;
                    timeStamp = value.TimeStamp;
                    multiCount = value.MultiCount;
                }
                else if (value.SecondValue != secondValue ||
                    value.TimeStamp.LowDateTime != timeStamp.LowDateTime ||
                    value.TimeStamp.HighDateTime != timeStamp.HighDateTime ||
                    value.MultiCount != multiCount)
                    return false;
            }
            if (!found || current.SecondValue <= secondValue || current.MultiCount != multiCount)
                return false;
            baseline.FirstValue = 0;
            baseline.SecondValue = secondValue;
            baseline.TimeStamp = timeStamp;
            baseline.CounterStatus = NativePdhGpuCounterReader.ValidData;
            return true;
        }

        private sealed class AggregatedSet
        {
            internal readonly Dictionary<string, PdhRawCounterValue> Values =
                new Dictionary<string, PdhRawCounterValue>(StringComparer.OrdinalIgnoreCase);
            internal readonly List<PdhGpuCounterSample> Failures = new List<PdhGpuCounterSample>();
            internal readonly HashSet<string> Rejected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        }

        private static AggregatedSet Aggregate(
            IEnumerable<PdhRawCounterSample> samples,
            bool retainFailures)
        {
            AggregatedSet result = new AggregatedSet();
            foreach (PdhRawCounterSample sample in samples)
            {
                if (sample == null || String.IsNullOrWhiteSpace(sample.InstanceName))
                {
                    if (retainFailures)
                        result.Failures.Add(Failure(
                            sample == null ? String.Empty : sample.InstanceName,
                            "pdh-engine-instance-invalid"));
                    continue;
                }
                string name = sample.InstanceName.Trim();
                if (result.Rejected.Contains(name))
                    continue;
                if (!IsValidStatus(sample.Value.CounterStatus))
                {
                    result.Values.Remove(name);
                    result.Rejected.Add(name);
                    if (retainFailures)
                    {
                        result.Failures.Add(new PdhGpuCounterSample
                        {
                            InstanceName = name,
                            Kind = WindowsGpuCounterKind.EngineUtilizationPercent,
                            Value = Double.NaN,
                            CounterStatus = sample.Value.CounterStatus
                        });
                    }
                    continue;
                }

                PdhRawCounterValue aggregate;
                if (!result.Values.TryGetValue(name, out aggregate))
                {
                    result.Values.Add(name, sample.Value);
                    continue;
                }

                PdhRawCounterValue combined;
                if (!TryCombine(aggregate, sample.Value, out combined))
                {
                    result.Values.Remove(name);
                    result.Rejected.Add(name);
                    if (retainFailures)
                        result.Failures.Add(Failure(name, "pdh-engine-instance-duplicate"));
                }
                else
                    result.Values[name] = combined;
            }
            return result;
        }

        private static bool TryCombine(
            PdhRawCounterValue left,
            PdhRawCounterValue right,
            out PdhRawCounterValue combined)
        {
            combined = left;
            if (left.SecondValue != right.SecondValue || left.MultiCount != right.MultiCount ||
                left.TimeStamp.LowDateTime != right.TimeStamp.LowDateTime ||
                left.TimeStamp.HighDateTime != right.TimeStamp.HighDateTime)
                return false;
            try
            {
                combined.FirstValue = checked(left.FirstValue + right.FirstValue);
                if (left.CounterStatus == NativePdhGpuCounterReader.NewData ||
                    right.CounterStatus == NativePdhGpuCounterReader.NewData)
                    combined.CounterStatus = NativePdhGpuCounterReader.NewData;
                return true;
            }
            catch (OverflowException)
            {
                return false;
            }
        }

        private static PdhGpuCounterSample Failure(string instanceName, string reasonCode)
        {
            return new PdhGpuCounterSample
            {
                InstanceName = instanceName ?? String.Empty,
                Kind = WindowsGpuCounterKind.EngineUtilizationPercent,
                Value = Double.NaN,
                CounterStatus = NativePdhGpuCounterReader.InvalidData,
                FailureReasonCode = reasonCode
            };
        }

        private static bool IsValidStatus(uint status)
        {
            return status == NativePdhGpuCounterReader.ValidData ||
                status == NativePdhGpuCounterReader.NewData;
        }
    }

    // Independent research reader for GPU Engine. It retains raw samples by
    // instance and asks PDH to format only matching adjacent pairs, avoiding
    // implicit wildcard-array pairing. Dedicated memory stays on the stable
    // formatted gauge path. No value is clamped and no invalid item is hidden.
    internal sealed class NativeRawPdhGpuCounterReader : IPdhGpuCounterReader, IDisposable
    {
        private const uint ErrorSuccess = 0x00000000;
        private const uint MoreData = 0x800007D2;
        private const uint FormatDouble = 0x00000200;
        private const uint FormatNoCap100 = 0x00008000;
        private const uint Timer100NsCounterType = 0x20510500;
        private const int SampleIntervalMilliseconds = 1000;
        private const uint MaximumBufferBytes = 64 * 1024 * 1024;
        private const uint MaximumItemCount = 32768;
        private const string EnginePath = @"\GPU Engine(*)\Utilization Percentage";
        private const string MemoryPath = @"\GPU Adapter Memory(*)\Dedicated Usage";
        private readonly object _sync = new object();
        private IntPtr _query;
        private IntPtr _engineCounter;
        private IntPtr _memoryCounter;
        private List<PdhRawCounterSample> _previousEngineSamples;
        private bool _disposed;

        public bool TryRead(out List<PdhGpuCounterSample> samples, out string reasonCode)
        {
            samples = new List<PdhGpuCounterSample>();
            reasonCode = String.Empty;
            lock (_sync)
            {
                if (_disposed)
                    return Fail(samples, out reasonCode, "pdh-raw-reader-disposed");
                try
                {
                    if (!EnsureQueryLocked(out reasonCode))
                        return Fail(samples, out reasonCode, reasonCode);

                    if (_previousEngineSamples == null)
                    {
                        if (PdhCollectQueryData(_query) != ErrorSuccess)
                            return ResetAndFail(samples, out reasonCode, "pdh-raw-first-collection-failed");
                        if (!TryReadRawArray(_engineCounter, out _previousEngineSamples, out reasonCode))
                            return ResetAndFail(samples, out reasonCode, reasonCode);
                        Thread.Sleep(SampleIntervalMilliseconds);
                    }

                    if (PdhCollectQueryData(_query) != ErrorSuccess)
                        return ResetAndFail(samples, out reasonCode, "pdh-raw-next-collection-failed");

                    List<PdhRawCounterSample> currentEngine;
                    if (!TryReadRawArray(_engineCounter, out currentEngine, out reasonCode))
                        return ResetAndFail(samples, out reasonCode, reasonCode);
                    NativeRawValueFormatter formatter = new NativeRawValueFormatter(_engineCounter);
                    samples.AddRange(RawPdhEnginePairing.Format(_previousEngineSamples, currentEngine, formatter));
                    _previousEngineSamples = currentEngine;

                    if (!TryReadFormattedMemoryArray(_memoryCounter, samples, out reasonCode))
                        return ResetAndFail(samples, out reasonCode, reasonCode);
                    if (samples.Count == 0)
                        return ResetAndFail(samples, out reasonCode, "pdh-raw-counter-query-empty");
                    return true;
                }
                catch (DllNotFoundException)
                {
                    return ResetAndFail(samples, out reasonCode, "pdh-raw-unavailable");
                }
                catch (EntryPointNotFoundException)
                {
                    return ResetAndFail(samples, out reasonCode, "pdh-raw-unavailable");
                }
                catch
                {
                    return ResetAndFail(samples, out reasonCode, "pdh-raw-counter-query-failed");
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
                reasonCode = "pdh-raw-query-open-failed";
                return false;
            }
            status = PdhAddEnglishCounterW(_query, EnginePath, UIntPtr.Zero, out _engineCounter);
            if (status != ErrorSuccess || _engineCounter == IntPtr.Zero)
            {
                ResetQueryLocked();
                reasonCode = "pdh-raw-engine-counter-add-failed";
                return false;
            }
            uint counterType;
            if (!TryReadCounterType(_engineCounter, out counterType) || counterType != Timer100NsCounterType)
            {
                ResetQueryLocked();
                reasonCode = "pdh-raw-engine-counter-type-unsupported";
                return false;
            }
            status = PdhAddEnglishCounterW(_query, MemoryPath, UIntPtr.Zero, out _memoryCounter);
            if (status != ErrorSuccess || _memoryCounter == IntPtr.Zero)
            {
                ResetQueryLocked();
                reasonCode = "pdh-raw-memory-counter-add-failed";
                return false;
            }
            return true;
        }

        private static bool TryReadCounterType(IntPtr counter, out uint counterType)
        {
            counterType = 0;
            uint bufferBytes = 0;
            uint status = PdhGetCounterInfoW(counter, false, ref bufferBytes, IntPtr.Zero);
            if (status != MoreData || bufferBytes < Marshal.SizeOf<PdhCounterInfoPrefix>() ||
                bufferBytes > MaximumBufferBytes)
                return false;
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)bufferBytes));
            try
            {
                status = PdhGetCounterInfoW(counter, false, ref bufferBytes, buffer);
                if (status != ErrorSuccess)
                    return false;
                PdhCounterInfoPrefix info = Marshal.PtrToStructure<PdhCounterInfoPrefix>(buffer);
                counterType = info.CounterType;
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static bool TryReadRawArray(
            IntPtr counter,
            out List<PdhRawCounterSample> samples,
            out string reasonCode)
        {
            samples = new List<PdhRawCounterSample>();
            reasonCode = String.Empty;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                uint bufferBytes = 0;
                uint itemCount = 0;
                uint status = PdhGetRawCounterArrayW(counter, ref bufferBytes, out itemCount, IntPtr.Zero);
                if (status != MoreData || bufferBytes == 0 || bufferBytes > MaximumBufferBytes ||
                    itemCount > MaximumItemCount)
                    return Fail(samples, out reasonCode, "pdh-raw-engine-array-size-failed");

                IntPtr buffer = Marshal.AllocHGlobal(checked((int)bufferBytes));
                try
                {
                    status = PdhGetRawCounterArrayW(counter, ref bufferBytes, out itemCount, buffer);
                    if (status == MoreData)
                        continue;
                    if (status != ErrorSuccess || itemCount == 0 || itemCount > MaximumItemCount)
                        return Fail(samples, out reasonCode, "pdh-raw-engine-array-read-failed");

                    int itemSize = Marshal.SizeOf<PdhRawCounterValueItem>();
                    for (uint index = 0; index < itemCount; index++)
                    {
                        IntPtr itemPointer = IntPtr.Add(buffer, checked((int)index * itemSize));
                        PdhRawCounterValueItem item = Marshal.PtrToStructure<PdhRawCounterValueItem>(itemPointer);
                        samples.Add(new PdhRawCounterSample
                        {
                            InstanceName = Marshal.PtrToStringUni(item.Name) ?? String.Empty,
                            Value = item.Value
                        });
                    }
                    return true;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            return Fail(samples, out reasonCode, "pdh-raw-engine-array-unstable");
        }

        private static bool TryReadFormattedMemoryArray(
            IntPtr counter,
            List<PdhGpuCounterSample> destination,
            out string reasonCode)
        {
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
                if (status != MoreData || bufferBytes == 0 || bufferBytes > MaximumBufferBytes ||
                    itemCount > MaximumItemCount)
                    return Fail(destination, out reasonCode, "pdh-raw-memory-array-size-failed");

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
                        return Fail(destination, out reasonCode, "pdh-raw-memory-array-read-failed");

                    int itemSize = Marshal.SizeOf<PdhFormattedCounterValueItem>();
                    for (uint index = 0; index < itemCount; index++)
                    {
                        IntPtr itemPointer = IntPtr.Add(buffer, checked((int)index * itemSize));
                        PdhFormattedCounterValueItem item = Marshal.PtrToStructure<PdhFormattedCounterValueItem>(itemPointer);
                        destination.Add(new PdhGpuCounterSample
                        {
                            InstanceName = Marshal.PtrToStringUni(item.Name) ?? String.Empty,
                            Kind = WindowsGpuCounterKind.DedicatedMemoryBytes,
                            Value = item.Value.Value.DoubleValue,
                            CounterStatus = item.Value.CounterStatus
                        });
                    }
                    return true;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            return Fail(destination, out reasonCode, "pdh-raw-memory-array-unstable");
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
            _previousEngineSamples = null;
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

        private static bool Fail<T>(List<T> values, out string reasonCode, string code)
        {
            values.Clear();
            reasonCode = code;
            return false;
        }

        private sealed class NativeRawValueFormatter : IPdhRawValueFormatter
        {
            private readonly IntPtr _counter;

            internal NativeRawValueFormatter(IntPtr counter)
            {
                _counter = counter;
            }

            public bool TryFormat(
                PdhRawCounterValue current,
                PdhRawCounterValue previous,
                out double value,
                out uint counterStatus)
            {
                PdhFormattedCounterValue formatted;
                uint status = PdhCalculateCounterFromRawValue(
                    _counter,
                    FormatDouble | FormatNoCap100,
                    ref current,
                    ref previous,
                    out formatted);
                value = formatted.Value.DoubleValue;
                counterStatus = formatted.CounterStatus;
                return status == ErrorSuccess;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PdhRawCounterValueItem
        {
            public IntPtr Name;
            public PdhRawCounterValue Value;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PdhCounterInfoPrefix
        {
            public uint Length;
            public uint CounterType;
            public uint Version;
            public uint CounterStatus;
            public int Scale;
            public int DefaultScale;
            public UIntPtr UserData;
            public UIntPtr QueryUserData;
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
        private static extern uint PdhGetCounterInfoW(
            IntPtr counter,
            [MarshalAs(UnmanagedType.Bool)] bool retrieveExplainText,
            ref uint bufferSize,
            IntPtr counterInfo);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhGetRawCounterArrayW(
            IntPtr counter,
            ref uint bufferSize,
            out uint itemCount,
            IntPtr itemBuffer);

        [DllImport("pdh.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint PdhGetFormattedCounterArrayW(
            IntPtr counter,
            uint format,
            ref uint bufferSize,
            out uint itemCount,
            IntPtr itemBuffer);

        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhCalculateCounterFromRawValue(
            IntPtr counter,
            uint format,
            ref PdhRawCounterValue currentValue,
            ref PdhRawCounterValue previousValue,
            out PdhFormattedCounterValue formattedValue);

        [DllImport("pdh.dll", ExactSpelling = true)]
        private static extern uint PdhCloseQuery(IntPtr query);
    }
}
