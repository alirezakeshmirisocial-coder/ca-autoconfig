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
    internal sealed class PdhWindowsGpuCounterSource : IWindowsGpuCounterSource
    {
        private readonly IPdhGpuCounterReader _reader;

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

            bool engineFamilyInvalid = false;
            bool memoryFamilyInvalid = false;
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
                    MarkFamilyInvalid(sample.Kind, ref engineFamilyInvalid, ref memoryFamilyInvalid);
                    SetFirstReason(ref reasonCode, GetFamilyReason(sample.Kind, "instance-invalid"));
                    continue;
                }
                if (sample.CounterStatus != NativePdhGpuCounterReader.ValidData &&
                    sample.CounterStatus != NativePdhGpuCounterReader.NewData)
                {
                    MarkFamilyInvalid(sample.Kind, ref engineFamilyInvalid, ref memoryFamilyInvalid);
                    SetFirstReason(ref reasonCode, GetInvalidStatusReason(sample.Kind, sample.CounterStatus));
                    continue;
                }
                observations.Add(new WindowsGpuCounterObservation
                {
                    InstanceName = sample.InstanceName,
                    Kind = sample.Kind,
                    Value = sample.Value
                });
            }

            if (engineFamilyInvalid)
                observations.RemoveAll(delegate(WindowsGpuCounterObservation value)
                {
                    return value.Kind == WindowsGpuCounterKind.EngineUtilizationPercent;
                });
            if (memoryFamilyInvalid)
                observations.RemoveAll(delegate(WindowsGpuCounterObservation value)
                {
                    return value.Kind == WindowsGpuCounterKind.DedicatedMemoryBytes;
                });

            // A bad status invalidates that whole metric family for this sample,
            // but a healthy sibling family remains useful as explicit partial
            // evidence. The caller preserves reasonCode even when this returns
            // true, and neither partial nor complete data is authorized for HUD use.
            return observations.Count > 0;
        }

        private static void MarkFamilyInvalid(
            WindowsGpuCounterKind kind,
            ref bool engineFamilyInvalid,
            ref bool memoryFamilyInvalid)
        {
            if (kind == WindowsGpuCounterKind.EngineUtilizationPercent)
                engineFamilyInvalid = true;
            else
                memoryFamilyInvalid = true;
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
    }

    internal sealed class NativePdhGpuCounterReader : IPdhGpuCounterReader
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

        public bool TryRead(out List<PdhGpuCounterSample> samples, out string reasonCode)
        {
            samples = new List<PdhGpuCounterSample>();
            reasonCode = String.Empty;
            IntPtr query = IntPtr.Zero;
            try
            {
                uint status = PdhOpenQueryW(null, UIntPtr.Zero, out query);
                if (status != ErrorSuccess || query == IntPtr.Zero)
                    return Fail(samples, out reasonCode, "pdh-query-open-failed");

                IntPtr engineCounter;
                status = PdhAddEnglishCounterW(query, EnginePath, UIntPtr.Zero, out engineCounter);
                if (status != ErrorSuccess || engineCounter == IntPtr.Zero)
                    return Fail(samples, out reasonCode, "pdh-engine-counter-add-failed");

                IntPtr memoryCounter;
                status = PdhAddEnglishCounterW(query, MemoryPath, UIntPtr.Zero, out memoryCounter);
                if (status != ErrorSuccess || memoryCounter == IntPtr.Zero)
                    return Fail(samples, out reasonCode, "pdh-memory-counter-add-failed");

                status = PdhCollectQueryData(query);
                if (status != ErrorSuccess)
                    return Fail(samples, out reasonCode, "pdh-first-collection-failed");

                Thread.Sleep(SampleIntervalMilliseconds);
                status = PdhCollectQueryData(query);
                if (status != ErrorSuccess)
                    return Fail(samples, out reasonCode, "pdh-second-collection-failed");

                if (!TryReadArray(engineCounter, WindowsGpuCounterKind.EngineUtilizationPercent, samples, out reasonCode))
                    return false;
                if (!TryReadArray(memoryCounter, WindowsGpuCounterKind.DedicatedMemoryBytes, samples, out reasonCode))
                    return false;
                if (samples.Count == 0)
                    return Fail(samples, out reasonCode, "pdh-counter-query-empty");
                return true;
            }
            catch (DllNotFoundException)
            {
                return Fail(samples, out reasonCode, "pdh-unavailable");
            }
            catch (EntryPointNotFoundException)
            {
                return Fail(samples, out reasonCode, "pdh-unavailable");
            }
            catch
            {
                return Fail(samples, out reasonCode, "pdh-counter-query-failed");
            }
            finally
            {
                if (query != IntPtr.Zero)
                    PdhCloseQuery(query);
            }
        }

        private static bool TryReadArray(
            IntPtr counter,
            WindowsGpuCounterKind kind,
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
