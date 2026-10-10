using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace CA.SystemOverlay
{
    internal enum WindowsGpuCounterKind
    {
        EngineUtilizationPercent,
        DedicatedMemoryBytes
    }

    // CorrelationKey is an internal, same-sample join key derived from the DXGI
    // adapter LUID. It must never be copied into diagnostics or public reports.
    internal sealed class WindowsGpuAdapterInventory
    {
        public string CorrelationKey { get; set; }
        public int DisplayIndex { get; set; }
        public string Name { get; set; }
        public string DriverVersion { get; set; }
    }

    internal sealed class WindowsGpuCounterObservation
    {
        public string InstanceName { get; set; }
        public WindowsGpuCounterKind Kind { get; set; }
        public double Value { get; set; }
    }

    internal sealed class WindowsGpuMappedMetric
    {
        public int DisplayIndex;
        public string Name;
        public string DriverVersion;
        public int EngineLoadPercent = -1;
        public long DedicatedMemoryBytes = -1;
    }

    internal sealed class WindowsGpuCounterMapResult
    {
        public bool MappingChecksPass;
        public bool CanProceedToLiveProvider;
        public bool CanUseInHud;
        public bool RawAdapterIdentifiersIncluded;
        public List<string> ReasonCodes = new List<string>();
        public List<WindowsGpuMappedMetric> Adapters = new List<WindowsGpuMappedMetric>();
    }

    internal static class WindowsGpuCounterMapper
    {
        private static readonly Regex CounterIdentityPattern = new Regex(
            @"^luid_(?<first>0x[0-9a-f]{1,16})_(?<second>0x[0-9a-f]{1,16})_phys_(?<physical>[0-9]+)(?:_|$)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        private sealed class Builder
        {
            public WindowsGpuMappedMetric Metric;
            public int EngineSamples;
            public int DedicatedMemorySamples;
            public double MaximumEngineLoad = -1;
        }

        internal static WindowsGpuCounterMapResult Map(
            IEnumerable<WindowsGpuAdapterInventory> adapterInventory,
            IEnumerable<WindowsGpuCounterObservation> counterObservations)
        {
            WindowsGpuCounterMapResult result = new WindowsGpuCounterMapResult();
            List<string> reasons = result.ReasonCodes;
            Dictionary<string, Builder> byKey = new Dictionary<string, Builder>(StringComparer.OrdinalIgnoreCase);
            HashSet<int> displayIndexes = new HashSet<int>();

            if (adapterInventory == null)
            {
                AddReason(reasons, "adapter-inventory-missing");
            }
            else
            {
                foreach (WindowsGpuAdapterInventory adapter in adapterInventory)
                {
                    string key;
                    if (adapter == null || !TryNormalizeIdentity(adapter.CorrelationKey, out key))
                    {
                        AddReason(reasons, "adapter-identity-invalid");
                        continue;
                    }
                    if (adapter.DisplayIndex < 0 || !displayIndexes.Add(adapter.DisplayIndex))
                    {
                        AddReason(reasons, "adapter-display-index-invalid");
                        continue;
                    }
                    if (String.IsNullOrWhiteSpace(adapter.Name))
                    {
                        AddReason(reasons, "adapter-name-missing");
                        continue;
                    }
                    if (byKey.ContainsKey(key))
                    {
                        AddReason(reasons, "adapter-identity-duplicate");
                        continue;
                    }

                    Builder builder = new Builder();
                    builder.Metric = new WindowsGpuMappedMetric
                    {
                        DisplayIndex = adapter.DisplayIndex,
                        Name = adapter.Name.Trim(),
                        DriverVersion = (adapter.DriverVersion ?? String.Empty).Trim()
                    };
                    byKey.Add(key, builder);
                }
            }

            if (byKey.Count == 0)
                AddReason(reasons, "adapter-inventory-empty");

            if (counterObservations == null)
            {
                AddReason(reasons, "counter-observations-missing");
            }
            else
            {
                foreach (WindowsGpuCounterObservation observation in counterObservations)
                {
                    string key;
                    if (observation == null || !TryNormalizeIdentity(observation.InstanceName, out key))
                    {
                        AddReason(reasons, "counter-identity-invalid");
                        continue;
                    }

                    Builder builder;
                    if (!byKey.TryGetValue(key, out builder))
                    {
                        AddReason(reasons, "counter-adapter-not-in-inventory");
                        continue;
                    }
                    if (Double.IsNaN(observation.Value) || Double.IsInfinity(observation.Value))
                    {
                        AddReason(reasons, "counter-value-invalid");
                        continue;
                    }

                    if (observation.Kind == WindowsGpuCounterKind.EngineUtilizationPercent)
                    {
                        if (observation.Value < 0 || observation.Value > 100)
                        {
                            AddReason(reasons, "engine-counter-out-of-range");
                            continue;
                        }
                        builder.EngineSamples++;
                        builder.MaximumEngineLoad = Math.Max(builder.MaximumEngineLoad, observation.Value);
                    }
                    else if (observation.Kind == WindowsGpuCounterKind.DedicatedMemoryBytes)
                    {
                        if (observation.Value < 0 || observation.Value > Int64.MaxValue)
                        {
                            AddReason(reasons, "memory-counter-out-of-range");
                            continue;
                        }
                        builder.DedicatedMemorySamples++;
                        if (builder.DedicatedMemorySamples > 1)
                        {
                            AddReason(reasons, "dedicated-memory-counter-duplicate");
                            continue;
                        }
                        builder.Metric.DedicatedMemoryBytes = Convert.ToInt64(Math.Round(observation.Value, MidpointRounding.AwayFromZero));
                    }
                    else
                    {
                        AddReason(reasons, "counter-kind-unsupported");
                    }
                }
            }

            foreach (KeyValuePair<string, Builder> pair in byKey)
            {
                Builder builder = pair.Value;
                if (builder.EngineSamples == 0)
                    AddReason(reasons, "engine-counter-missing");
                else
                    builder.Metric.EngineLoadPercent = ClampPercent((int)Math.Round(builder.MaximumEngineLoad, MidpointRounding.AwayFromZero));
                if (builder.DedicatedMemorySamples == 0)
                    AddReason(reasons, "dedicated-memory-counter-missing");
                result.Adapters.Add(builder.Metric);
            }

            result.Adapters.Sort(delegate(WindowsGpuMappedMetric left, WindowsGpuMappedMetric right)
            {
                return left.DisplayIndex.CompareTo(right.DisplayIndex);
            });
            result.MappingChecksPass = reasons.Count == 0;
            result.CanProceedToLiveProvider = result.MappingChecksPass;
            result.CanUseInHud = false;
            result.RawAdapterIdentifiersIncluded = false;
            return result;
        }

        private static bool TryNormalizeIdentity(string value, out string key)
        {
            key = String.Empty;
            Match match = CounterIdentityPattern.Match((value ?? String.Empty).Trim());
            if (!match.Success)
                return false;

            ulong first;
            ulong second;
            int physical;
            if (!UInt64.TryParse(match.Groups["first"].Value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out first) ||
                !UInt64.TryParse(match.Groups["second"].Value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out second) ||
                !Int32.TryParse(match.Groups["physical"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out physical))
                return false;

            key = String.Format(CultureInfo.InvariantCulture, "luid_0x{0:x16}_0x{1:x16}_phys_{2}", first, second, physical);
            return true;
        }

        private static void AddReason(List<string> reasons, string reason)
        {
            if (!reasons.Contains(reason))
                reasons.Add(reason);
        }

        private static int ClampPercent(int value)
        {
            return Math.Max(0, Math.Min(100, value));
        }
    }
}
