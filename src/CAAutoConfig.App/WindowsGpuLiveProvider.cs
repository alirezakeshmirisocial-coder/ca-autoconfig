using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace CA.SystemOverlay
{
    internal interface IWindowsGpuAdapterSource
    {
        bool TryRead(out List<WindowsGpuAdapterInventory> adapters, out string reasonCode);
    }

    internal interface IWindowsGpuCounterSource
    {
        bool TryRead(out List<WindowsGpuCounterObservation> observations, out string reasonCode);
    }

    internal sealed class WindowsGpuLiveProbeResult
    {
        public string CounterProvider = "unknown";
        public string ProbeStatus = "BLOCKED";
        public bool MappingChecksPass;
        public bool EngineLoadMappingChecksPass;
        public bool DedicatedMemoryMappingChecksPass;
        public bool CanUseInHud;
        public bool HardwareWrites;
        public bool NetworkAccess;
        public bool ElevationRequested;
        public bool RawAdapterIdentifiersIncluded;
        internal string InternalTopologyFingerprint = String.Empty;
        public List<string> ReasonCodes = new List<string>();
        public List<WindowsGpuMappedMetric> Adapters = new List<WindowsGpuMappedMetric>();
    }

    internal static class WindowsGpuLiveProbe
    {
        internal static WindowsGpuLiveProbeResult Run()
        {
            return Run(new DxgiWindowsGpuAdapterSource(), new WmiWindowsGpuCounterSource(), "windows-wmi-formatted");
        }

        internal static WindowsGpuLiveProbeResult RunPdh()
        {
            return Run(new DxgiWindowsGpuAdapterSource(), new PdhWindowsGpuCounterSource(), "windows-pdh");
        }

        internal static WindowsGpuLiveProbeResult Run(IWindowsGpuAdapterSource adapterSource, IWindowsGpuCounterSource counterSource)
        {
            return Run(adapterSource, counterSource, "injected-fixture");
        }

        private static WindowsGpuLiveProbeResult Run(
            IWindowsGpuAdapterSource adapterSource,
            IWindowsGpuCounterSource counterSource,
            string counterProvider)
        {
            WindowsGpuLiveProbeResult result = new WindowsGpuLiveProbeResult
            {
                CounterProvider = counterProvider
            };
            if (adapterSource == null || counterSource == null)
            {
                result.ReasonCodes.Add("live-source-missing");
                return result;
            }

            List<WindowsGpuAdapterInventory> adapters;
            string reason;
            if (!adapterSource.TryRead(out adapters, out reason))
            {
                result.ReasonCodes.Add(String.IsNullOrWhiteSpace(reason) ? "dxgi-adapter-query-failed" : reason);
                return result;
            }

            List<WindowsGpuCounterObservation> observations;
            if (!counterSource.TryRead(out observations, out reason))
            {
                result.ReasonCodes.Add(String.IsNullOrWhiteSpace(reason) ? "wddm-counter-query-failed" : reason);
                return result;
            }

            WindowsGpuCounterMapResult mapping = WindowsGpuCounterMapper.Map(adapters, observations);
            bool sourceEnginePass = String.IsNullOrWhiteSpace(reason) || !reason.Contains("-engine-");
            bool sourceMemoryPass = String.IsNullOrWhiteSpace(reason) || !reason.Contains("-memory-");
            bool sourceSharedPass = String.IsNullOrWhiteSpace(reason) ||
                reason.Contains("-engine-") || reason.Contains("-memory-");
            result.EngineLoadMappingChecksPass = mapping.EngineLoadMappingChecksPass && sourceEnginePass && sourceSharedPass;
            result.DedicatedMemoryMappingChecksPass = mapping.DedicatedMemoryMappingChecksPass && sourceMemoryPass && sourceSharedPass;
            result.MappingChecksPass = mapping.MappingChecksPass &&
                result.EngineLoadMappingChecksPass && result.DedicatedMemoryMappingChecksPass;
            result.Adapters = mapping.Adapters;
            if (!String.IsNullOrWhiteSpace(reason))
                AddReason(result.ReasonCodes, reason);
            foreach (string mappingReason in mapping.ReasonCodes)
                AddReason(result.ReasonCodes, mappingReason);
            result.ProbeStatus = result.MappingChecksPass
                ? "MAPPING_AVAILABLE"
                : (result.EngineLoadMappingChecksPass || result.DedicatedMemoryMappingChecksPass
                    ? "PARTIAL_MAPPING_AVAILABLE"
                    : "BLOCKED");
            result.InternalTopologyFingerprint = mapping.InternalTopologyFingerprint;
            result.CanUseInHud = false;
            result.HardwareWrites = false;
            result.NetworkAccess = false;
            result.ElevationRequested = false;
            result.RawAdapterIdentifiersIncluded = false;
            return result;
        }

        private static void AddReason(List<string> reasons, string reason)
        {
            if (!String.IsNullOrWhiteSpace(reason) && !reasons.Contains(reason))
                reasons.Add(reason);
        }
    }

    [DataContract]
    internal sealed class WindowsGpuPublicAdapter
    {
        [DataMember(Name = "index", Order = 1)] public int Index;
        [DataMember(Name = "name", Order = 2)] public string Name;
        [DataMember(Name = "engineLoadPercent", Order = 3)] public int EngineLoadPercent;
        [DataMember(Name = "dedicatedMemoryBytes", Order = 4)] public long DedicatedMemoryBytes;
        [DataMember(Name = "dedicatedMemoryCapacityBytes", Order = 5)] public long DedicatedMemoryCapacityBytes;
        [DataMember(Name = "vramPercent", Order = 6)] public int VramPercent;
        [DataMember(Name = "engineLoadAvailable", Order = 7)] public bool EngineLoadAvailable;
        [DataMember(Name = "dedicatedMemoryAvailable", Order = 8)] public bool DedicatedMemoryAvailable;
    }

    [DataContract]
    internal sealed class WindowsGpuLiveReportDocument
    {
        [DataMember(Name = "schemaVersion", Order = 1)] public int SchemaVersion;
        [DataMember(Name = "capturedUtc", Order = 2)] public string CapturedUtc;
        [DataMember(Name = "source", Order = 3)] public string Source;
        [DataMember(Name = "counterProvider", Order = 4)] public string CounterProvider;
        [DataMember(Name = "probeStatus", Order = 5)] public string ProbeStatus;
        [DataMember(Name = "mappingChecksPass", Order = 6)] public bool MappingChecksPass;
        [DataMember(Name = "canUseInHud", Order = 7)] public bool CanUseInHud;
        [DataMember(Name = "reasonCodes", Order = 8)] public string[] ReasonCodes;
        [DataMember(Name = "adapters", Order = 9)] public WindowsGpuPublicAdapter[] Adapters;
        [DataMember(Name = "hardwareWrites", Order = 10)] public bool HardwareWrites;
        [DataMember(Name = "networkAccess", Order = 11)] public bool NetworkAccess;
        [DataMember(Name = "elevationRequested", Order = 12)] public bool ElevationRequested;
        [DataMember(Name = "rawAdapterIdentifiersIncluded", Order = 13)] public bool RawAdapterIdentifiersIncluded;
        [DataMember(Name = "engineLoadMappingChecksPass", Order = 14)] public bool EngineLoadMappingChecksPass;
        [DataMember(Name = "dedicatedMemoryMappingChecksPass", Order = 15)] public bool DedicatedMemoryMappingChecksPass;
    }

    internal static class WindowsGpuLiveReport
    {
        internal static int Write(string resultPath)
        {
            return Write(resultPath, "wmi");
        }

        internal static int Write(string resultPath, string provider)
        {
            try
            {
                bool usePdh = String.Equals(provider, "pdh", StringComparison.OrdinalIgnoreCase);
                if (!usePdh && !String.Equals(provider, "wmi", StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("Windows GPU provider must be 'wmi' or 'pdh'.", "provider");
                WindowsGpuLiveProbeResult probe = usePdh ? WindowsGpuLiveProbe.RunPdh() : WindowsGpuLiveProbe.Run();
                WindowsGpuLiveReportDocument document = Create(probe, DateTime.UtcNow);
                string fullPath = Path.GetFullPath(resultPath);
                string directory = Path.GetDirectoryName(fullPath);
                if (!String.IsNullOrWhiteSpace(directory))
                    Directory.CreateDirectory(directory);
                File.WriteAllText(fullPath, Serialize(document), new UTF8Encoding(false));
                return 0;
            }
            catch
            {
                return 1;
            }
        }

        internal static WindowsGpuLiveReportDocument Create(WindowsGpuLiveProbeResult result, DateTime capturedUtc)
        {
            if (result == null)
                throw new ArgumentNullException("result");
            List<WindowsGpuPublicAdapter> adapters = new List<WindowsGpuPublicAdapter>();
            foreach (WindowsGpuMappedMetric adapter in result.Adapters)
            {
                int engineLoadPercent = result.EngineLoadMappingChecksPass ? adapter.EngineLoadPercent : -1;
                long dedicatedMemoryBytes = result.DedicatedMemoryMappingChecksPass ? adapter.DedicatedMemoryBytes : -1;
                int vramPercent = -1;
                if (dedicatedMemoryBytes >= 0 && adapter.DedicatedMemoryCapacityBytes > 0)
                {
                    vramPercent = Math.Max(0, Math.Min(100, (int)Math.Round(
                        100.0 * dedicatedMemoryBytes / adapter.DedicatedMemoryCapacityBytes,
                        MidpointRounding.AwayFromZero)));
                }
                adapters.Add(new WindowsGpuPublicAdapter
                {
                    Index = adapter.DisplayIndex,
                    Name = adapter.Name,
                    EngineLoadPercent = engineLoadPercent,
                    DedicatedMemoryBytes = dedicatedMemoryBytes,
                    DedicatedMemoryCapacityBytes = adapter.DedicatedMemoryCapacityBytes,
                    VramPercent = vramPercent,
                    EngineLoadAvailable = engineLoadPercent >= 0,
                    DedicatedMemoryAvailable = dedicatedMemoryBytes >= 0 && adapter.DedicatedMemoryCapacityBytes > 0
                });
            }

            return new WindowsGpuLiveReportDocument
            {
                SchemaVersion = 3,
                CapturedUtc = capturedUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                Source = "live-windows-read-only",
                CounterProvider = result.CounterProvider,
                ProbeStatus = result.ProbeStatus,
                MappingChecksPass = result.MappingChecksPass,
                CanUseInHud = false,
                ReasonCodes = result.ReasonCodes.ToArray(),
                Adapters = adapters.ToArray(),
                HardwareWrites = false,
                NetworkAccess = false,
                ElevationRequested = false,
                RawAdapterIdentifiersIncluded = false,
                EngineLoadMappingChecksPass = result.EngineLoadMappingChecksPass,
                DedicatedMemoryMappingChecksPass = result.DedicatedMemoryMappingChecksPass
            };
        }

        internal static string Serialize(WindowsGpuLiveReportDocument document)
        {
            DataContractJsonSerializer serializer = new DataContractJsonSerializer(typeof(WindowsGpuLiveReportDocument));
            using (MemoryStream stream = new MemoryStream())
            {
                serializer.WriteObject(stream, document);
                return Encoding.UTF8.GetString(stream.ToArray());
            }
        }
    }

    internal sealed class WmiWindowsGpuCounterSource : IWindowsGpuCounterSource
    {
        public bool TryRead(out List<WindowsGpuCounterObservation> observations, out string reasonCode)
        {
            observations = new List<WindowsGpuCounterObservation>();
            reasonCode = String.Empty;
            try
            {
                ReadClass(
                    "SELECT Name, UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine",
                    "UtilizationPercentage",
                    WindowsGpuCounterKind.EngineUtilizationPercent,
                    observations);
                ReadClass(
                    "SELECT Name, DedicatedUsage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory",
                    "DedicatedUsage",
                    WindowsGpuCounterKind.DedicatedMemoryBytes,
                    observations);
                if (observations.Count == 0)
                {
                    reasonCode = "wddm-counter-query-empty";
                    return false;
                }
                return true;
            }
            catch (UnauthorizedAccessException)
            {
                observations.Clear();
                reasonCode = "wddm-counter-access-denied";
                return false;
            }
            catch
            {
                observations.Clear();
                reasonCode = "wddm-counter-query-failed";
                return false;
            }
        }

        private static void ReadClass(
            string query,
            string valueProperty,
            WindowsGpuCounterKind kind,
            List<WindowsGpuCounterObservation> destination)
        {
            using (ManagementObjectSearcher searcher = new ManagementObjectSearcher("root\\CIMV2", query))
            {
                searcher.Options.Timeout = TimeSpan.FromSeconds(3);
                using (ManagementObjectCollection results = searcher.Get())
                {
                    foreach (ManagementObject item in results)
                    {
                        string name = Convert.ToString(item["Name"], CultureInfo.InvariantCulture);
                        object rawValue = item[valueProperty];
                        double value;
                        if (String.IsNullOrWhiteSpace(name) || rawValue == null ||
                            !Double.TryParse(Convert.ToString(rawValue, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out value))
                        {
                            destination.Add(new WindowsGpuCounterObservation
                            {
                                InstanceName = name ?? String.Empty,
                                Kind = kind,
                                Value = Double.NaN
                            });
                            continue;
                        }
                        destination.Add(new WindowsGpuCounterObservation { InstanceName = name, Kind = kind, Value = value });
                    }
                }
            }
        }
    }

    internal sealed class DxgiWindowsGpuAdapterSource : IWindowsGpuAdapterSource
    {
        private const int DxgiErrorNotFound = unchecked((int)0x887A0002);
        private const uint DxgiAdapterFlagSoftware = 2;
        private static readonly Guid Factory1Guid = new Guid("770AAE78-F26F-4DBA-A829-253C83D1B387");

        public bool TryRead(out List<WindowsGpuAdapterInventory> adapters, out string reasonCode)
        {
            adapters = new List<WindowsGpuAdapterInventory>();
            reasonCode = String.Empty;
            IDXGIFactory1 factory = null;
            try
            {
                Guid iid = Factory1Guid;
                int createResult = CreateDXGIFactory1(ref iid, out factory);
                if (createResult < 0 || factory == null)
                {
                    reasonCode = "dxgi-factory-unavailable";
                    return false;
                }

                for (uint index = 0; ; index++)
                {
                    IDXGIAdapter1 adapter = null;
                    int enumResult = factory.EnumAdapters1(index, out adapter);
                    if (enumResult == DxgiErrorNotFound)
                        break;
                    if (enumResult < 0 || adapter == null)
                    {
                        reasonCode = "dxgi-adapter-query-failed";
                        return false;
                    }
                    try
                    {
                        DxgiAdapterDesc1 description;
                        int describeResult = adapter.GetDesc1(out description);
                        if (describeResult < 0)
                        {
                            reasonCode = "dxgi-adapter-description-failed";
                            return false;
                        }
                        ulong capacity = description.DedicatedVideoMemory.ToUInt64();
                        if (capacity > Int64.MaxValue)
                        {
                            reasonCode = "dxgi-adapter-memory-invalid";
                            return false;
                        }
                        string correlationKey = String.Format(
                            CultureInfo.InvariantCulture,
                            "luid_0x{0:x8}_0x{1:x8}_phys_0",
                            unchecked((uint)description.AdapterLuid.HighPart),
                            description.AdapterLuid.LowPart);
                        adapters.Add(new WindowsGpuAdapterInventory
                        {
                            CorrelationKey = correlationKey,
                            DisplayIndex = checked((int)index),
                            Name = (description.Description ?? String.Empty).Trim(),
                            DriverVersion = String.Empty,
                            DedicatedMemoryCapacityBytes = checked((long)capacity),
                            IsSoftware = (description.Flags & DxgiAdapterFlagSoftware) != 0
                        });
                    }
                    finally
                    {
                        if (adapter != null && Marshal.IsComObject(adapter))
                            Marshal.FinalReleaseComObject(adapter);
                    }
                }

                if (adapters.Count == 0)
                {
                    reasonCode = "dxgi-adapter-inventory-empty";
                    return false;
                }
                return true;
            }
            catch
            {
                adapters.Clear();
                reasonCode = "dxgi-adapter-query-failed";
                return false;
            }
            finally
            {
                if (factory != null && Marshal.IsComObject(factory))
                    Marshal.FinalReleaseComObject(factory);
            }
        }

        [DllImport("dxgi.dll", PreserveSig = true)]
        private static extern int CreateDXGIFactory1(
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 factory);

        [ComImport]
        [Guid("770AAE78-F26F-4DBA-A829-253C83D1B387")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDXGIFactory1
        {
            [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
            [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
            [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
            [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
            [PreserveSig] int EnumAdapters(uint adapter, out IntPtr adapterPointer);
            [PreserveSig] int MakeWindowAssociation(IntPtr windowHandle, uint flags);
            [PreserveSig] int GetWindowAssociation(out IntPtr windowHandle);
            [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr description, out IntPtr swapChain);
            [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
            [PreserveSig] int EnumAdapters1(uint adapter, [MarshalAs(UnmanagedType.Interface)] out IDXGIAdapter1 adapterInterface);
            [PreserveSig] [return: MarshalAs(UnmanagedType.Bool)] bool IsCurrent();
        }

        [ComImport]
        [Guid("29038F61-3839-4626-91FD-086879011A05")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDXGIAdapter1
        {
            [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
            [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
            [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
            [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
            [PreserveSig] int EnumOutputs(uint output, out IntPtr outputPointer);
            [PreserveSig] int GetDesc(out DxgiAdapterDesc description);
            [PreserveSig] int CheckInterfaceSupport(ref Guid interfaceName, out long userModeDriverVersion);
            [PreserveSig] int GetDesc1(out DxgiAdapterDesc1 description);
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DxgiAdapterDesc
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId;
            public uint DeviceId;
            public uint SubSystemId;
            public uint Revision;
            public UIntPtr DedicatedVideoMemory;
            public UIntPtr DedicatedSystemMemory;
            public UIntPtr SharedSystemMemory;
            public Luid AdapterLuid;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DxgiAdapterDesc1
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId;
            public uint DeviceId;
            public uint SubSystemId;
            public uint Revision;
            public UIntPtr DedicatedVideoMemory;
            public UIntPtr DedicatedSystemMemory;
            public UIntPtr SharedSystemMemory;
            public Luid AdapterLuid;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Luid
        {
            public uint LowPart;
            public int HighPart;
        }
    }
}
