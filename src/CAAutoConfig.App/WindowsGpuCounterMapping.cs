using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
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
        public long DedicatedMemoryCapacityBytes { get; set; }
        public bool IsSoftware { get; set; }
    }

    internal sealed class WindowsGpuCounterObservation
    {
        public string InstanceName { get; set; }
        public WindowsGpuCounterKind Kind { get; set; }
        public double Value { get; set; }
        public string FailureReasonCode { get; set; }
    }

    internal sealed class WindowsGpuMappedMetric
    {
        public int DisplayIndex;
        public string Name;
        public string DriverVersion;
        public int EngineLoadPercent = -1;
        public long DedicatedMemoryBytes = -1;
        public long DedicatedMemoryCapacityBytes = -1;
    }

    internal sealed class WindowsGpuCounterMapResult
    {
        public bool MappingChecksPass;
        public bool EngineLoadMappingChecksPass;
        public bool DedicatedMemoryMappingChecksPass;
        public bool CanProceedToLiveProvider;
        public bool CanUseInHud;
        public bool RawAdapterIdentifiersIncluded;
        internal string InternalTopologyFingerprint = String.Empty;
        public List<string> ReasonCodes = new List<string>();
        public List<WindowsGpuMappedMetric> Adapters = new List<WindowsGpuMappedMetric>();
    }

    internal static class WindowsGpuCounterMapper
    {
        private static readonly Regex AdapterIdentityPattern = new Regex(
            @"^luid_(?<first>0x[0-9a-f]{1,16})_(?<second>0x[0-9a-f]{1,16})_phys_(?<physical>[0-9]+)$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly Regex CounterIdentityPattern = new Regex(
            @"(?:^|_)luid_(?<first>0x[0-9a-f]{1,16})_(?<second>0x[0-9a-f]{1,16})_phys_(?<physical>[0-9]+)(?<suffix>(?:_.*)?)$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly Regex EngineIdentityPattern = new Regex(
            @"^_eng_(?<engine>[0-9]+)_engtype_(?<type>[a-z0-9_]+?)(?:#[0-9]+)?$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly HashSet<string> AllowedObservationFailureReasons = new HashSet<string>(StringComparer.Ordinal)
        {
            "pdh-engine-instance-disappeared",
            "pdh-engine-not-validated",
            "pdh-engine-data-invalid",
            "pdh-engine-counter-status-invalid",
            "pdh-engine-instance-duplicate",
            "pdh-engine-baseline-missing",
            "pdh-engine-raw-calculation-failed",
            "pdh-memory-instance-disappeared",
            "pdh-memory-not-validated",
            "pdh-memory-data-invalid",
            "pdh-memory-counter-status-invalid"
        };

        private sealed class Builder
        {
            public WindowsGpuMappedMetric Metric;
            public int DedicatedMemorySamples;
            public bool EngineChecksPass = true;
            public bool MemoryChecksPass = true;
            public Dictionary<string, double> EngineTotals = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        }

        internal static WindowsGpuCounterMapResult Map(
            IEnumerable<WindowsGpuAdapterInventory> adapterInventory,
            IEnumerable<WindowsGpuCounterObservation> counterObservations)
        {
            WindowsGpuCounterMapResult result = new WindowsGpuCounterMapResult();
            List<string> reasons = result.ReasonCodes;
            bool sharedChecksPass = true;
            bool engineChecksPass = true;
            bool memoryChecksPass = true;
            Dictionary<string, Builder> byKey = new Dictionary<string, Builder>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> ignoredSoftwareKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> allAdapterKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
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
                    if (adapter == null || !TryNormalizeAdapterIdentity(adapter.CorrelationKey, out key))
                    {
                        AddReason(reasons, "adapter-identity-invalid");
                        sharedChecksPass = false;
                        continue;
                    }
                    if (adapter.DisplayIndex < 0 || !displayIndexes.Add(adapter.DisplayIndex))
                    {
                        AddReason(reasons, "adapter-display-index-invalid");
                        sharedChecksPass = false;
                        continue;
                    }
                    if (!allAdapterKeys.Add(key))
                    {
                        AddReason(reasons, "adapter-identity-duplicate");
                        sharedChecksPass = false;
                        continue;
                    }
                    if (String.IsNullOrWhiteSpace(adapter.Name))
                    {
                        AddReason(reasons, "adapter-name-missing");
                        sharedChecksPass = false;
                        continue;
                    }
                    if (adapter.IsSoftware)
                    {
                        ignoredSoftwareKeys.Add(key);
                        continue;
                    }
                    Builder builder = new Builder();
                    builder.Metric = new WindowsGpuMappedMetric
                    {
                        DisplayIndex = adapter.DisplayIndex,
                        Name = adapter.Name.Trim(),
                        DriverVersion = (adapter.DriverVersion ?? String.Empty).Trim(),
                        DedicatedMemoryCapacityBytes = adapter.DedicatedMemoryCapacityBytes
                    };
                    if (adapter.DedicatedMemoryCapacityBytes <= 0)
                    {
                        AddReason(reasons, "adapter-memory-capacity-unavailable");
                        AddAdapterReason(reasons, "adapter-memory-capacity-unavailable", adapter.DisplayIndex);
                        builder.MemoryChecksPass = false;
                    }
                    byKey.Add(key, builder);
                }
            }

            if (byKey.Count == 0)
            {
                AddReason(reasons, "adapter-inventory-empty");
                sharedChecksPass = false;
            }

            if (counterObservations == null)
            {
                AddReason(reasons, "counter-observations-missing");
                sharedChecksPass = false;
            }
            else
            {
                foreach (WindowsGpuCounterObservation observation in counterObservations)
                {
                    string key;
                    string suffix;
                    if (observation == null || !TryParseCounterIdentity(observation.InstanceName, out key, out suffix))
                    {
                        AddReason(reasons, "counter-identity-invalid");
                        MarkGlobalCounterFailure(observation, ref sharedChecksPass, ref engineChecksPass, ref memoryChecksPass);
                        continue;
                    }

                    Builder builder;
                    if (ignoredSoftwareKeys.Contains(key))
                        continue;
                    if (!byKey.TryGetValue(key, out builder))
                    {
                        AddReason(reasons, "counter-adapter-not-in-inventory");
                        MarkGlobalCounterFailure(observation, ref sharedChecksPass, ref engineChecksPass, ref memoryChecksPass);
                        continue;
                    }
                    if (!String.IsNullOrWhiteSpace(observation.FailureReasonCode))
                    {
                        string failureReason = NormalizeObservationFailureReason(observation);
                        AddReason(reasons, failureReason);
                        AddAdapterReason(reasons, failureReason, builder.Metric.DisplayIndex);
                        MarkBuilderCounterFailure(observation, builder);
                        continue;
                    }
                    if (Double.IsNaN(observation.Value) || Double.IsInfinity(observation.Value))
                    {
                        AddReason(reasons, "counter-value-invalid");
                        AddAdapterReason(reasons, "counter-value-invalid", builder.Metric.DisplayIndex);
                        MarkBuilderCounterFailure(observation, builder);
                        continue;
                    }

                    if (observation.Kind == WindowsGpuCounterKind.EngineUtilizationPercent)
                    {
                        Match engineMatch = EngineIdentityPattern.Match(suffix);
                        if (!engineMatch.Success)
                        {
                            AddReason(reasons, "engine-counter-instance-invalid");
                            AddAdapterReason(reasons, "engine-counter-instance-invalid", builder.Metric.DisplayIndex);
                            builder.EngineChecksPass = false;
                            continue;
                        }
                        if (observation.Value < 0 || observation.Value > 100)
                        {
                            AddReason(reasons, "engine-counter-out-of-range");
                            AddAdapterReason(reasons, "engine-counter-out-of-range", builder.Metric.DisplayIndex);
                            builder.EngineChecksPass = false;
                            continue;
                        }
                        string engineKey = engineMatch.Groups["engine"].Value + ":" + engineMatch.Groups["type"].Value.ToLowerInvariant();
                        double currentTotal;
                        builder.EngineTotals.TryGetValue(engineKey, out currentTotal);
                        builder.EngineTotals[engineKey] = currentTotal + observation.Value;
                    }
                    else if (observation.Kind == WindowsGpuCounterKind.DedicatedMemoryBytes)
                    {
                        if (suffix.Length != 0)
                        {
                            AddReason(reasons, "memory-counter-instance-invalid");
                            AddAdapterReason(reasons, "memory-counter-instance-invalid", builder.Metric.DisplayIndex);
                            builder.MemoryChecksPass = false;
                            continue;
                        }
                        if (observation.Value < 0 || observation.Value > Int64.MaxValue)
                        {
                            AddReason(reasons, "memory-counter-out-of-range");
                            AddAdapterReason(reasons, "memory-counter-out-of-range", builder.Metric.DisplayIndex);
                            builder.MemoryChecksPass = false;
                            continue;
                        }
                        builder.DedicatedMemorySamples++;
                        if (builder.DedicatedMemorySamples > 1)
                        {
                            AddReason(reasons, "dedicated-memory-counter-duplicate");
                            AddAdapterReason(reasons, "dedicated-memory-counter-duplicate", builder.Metric.DisplayIndex);
                            builder.MemoryChecksPass = false;
                            continue;
                        }
                        builder.Metric.DedicatedMemoryBytes = Convert.ToInt64(Math.Round(observation.Value, MidpointRounding.AwayFromZero));
                    }
                    else
                    {
                        AddReason(reasons, "counter-kind-unsupported");
                        sharedChecksPass = false;
                    }
                }
            }

            foreach (KeyValuePair<string, Builder> pair in byKey)
            {
                Builder builder = pair.Value;
                if (builder.EngineTotals.Count == 0)
                {
                    AddReason(reasons, "engine-counter-missing");
                    AddAdapterReason(reasons, "engine-counter-missing", builder.Metric.DisplayIndex);
                    builder.EngineChecksPass = false;
                }
                else if (builder.EngineChecksPass)
                {
                    double busiestEngine = 0;
                    foreach (double total in builder.EngineTotals.Values)
                        busiestEngine = Math.Max(busiestEngine, total);
                    if (busiestEngine > 100.5)
                    {
                        AddReason(reasons, "engine-aggregate-out-of-range");
                        AddAdapterReason(reasons, "engine-aggregate-out-of-range", builder.Metric.DisplayIndex);
                        builder.EngineChecksPass = false;
                    }
                    else
                        builder.Metric.EngineLoadPercent = ClampPercent((int)Math.Round(busiestEngine, MidpointRounding.AwayFromZero));
                }
                if (builder.DedicatedMemorySamples == 0)
                {
                    AddReason(reasons, "dedicated-memory-counter-missing");
                    AddAdapterReason(reasons, "dedicated-memory-counter-missing", builder.Metric.DisplayIndex);
                    builder.MemoryChecksPass = false;
                }
                if (!builder.EngineChecksPass)
                    builder.Metric.EngineLoadPercent = -1;
                if (!builder.MemoryChecksPass)
                    builder.Metric.DedicatedMemoryBytes = -1;
                engineChecksPass = engineChecksPass && builder.EngineChecksPass;
                memoryChecksPass = memoryChecksPass && builder.MemoryChecksPass;
                result.Adapters.Add(builder.Metric);
            }

            result.Adapters.Sort(delegate(WindowsGpuMappedMetric left, WindowsGpuMappedMetric right)
            {
                return left.DisplayIndex.CompareTo(right.DisplayIndex);
            });
            result.EngineLoadMappingChecksPass = sharedChecksPass && engineChecksPass;
            result.DedicatedMemoryMappingChecksPass = sharedChecksPass && memoryChecksPass;
            result.MappingChecksPass = result.EngineLoadMappingChecksPass && result.DedicatedMemoryMappingChecksPass && reasons.Count == 0;
            result.CanProceedToLiveProvider = result.MappingChecksPass;
            result.CanUseInHud = false;
            result.RawAdapterIdentifiersIncluded = false;
            result.InternalTopologyFingerprint = BuildTopologyFingerprint(byKey.Keys);
            return result;
        }

        private static void MarkGlobalCounterFailure(
            WindowsGpuCounterObservation observation,
            ref bool sharedChecksPass,
            ref bool engineChecksPass,
            ref bool memoryChecksPass)
        {
            if (observation == null)
            {
                sharedChecksPass = false;
                return;
            }
            if (observation.Kind == WindowsGpuCounterKind.EngineUtilizationPercent)
                engineChecksPass = false;
            else if (observation.Kind == WindowsGpuCounterKind.DedicatedMemoryBytes)
                memoryChecksPass = false;
            else
                sharedChecksPass = false;
        }

        private static void MarkBuilderCounterFailure(WindowsGpuCounterObservation observation, Builder builder)
        {
            if (observation.Kind == WindowsGpuCounterKind.EngineUtilizationPercent)
                builder.EngineChecksPass = false;
            else if (observation.Kind == WindowsGpuCounterKind.DedicatedMemoryBytes)
                builder.MemoryChecksPass = false;
            else
            {
                builder.EngineChecksPass = false;
                builder.MemoryChecksPass = false;
            }
        }

        private static string NormalizeObservationFailureReason(WindowsGpuCounterObservation observation)
        {
            string reason = (observation.FailureReasonCode ?? String.Empty).Trim().ToLowerInvariant();
            string expectedPrefix = observation.Kind == WindowsGpuCounterKind.EngineUtilizationPercent
                ? "pdh-engine-"
                : "pdh-memory-";
            if (reason.StartsWith(expectedPrefix, StringComparison.Ordinal) &&
                AllowedObservationFailureReasons.Contains(reason))
                return reason;
            return "counter-value-invalid";
        }

        private static void AddAdapterReason(List<string> reasons, string reason, int displayIndex)
        {
            AddReason(reasons, reason + "-adapter-" + displayIndex.ToString(CultureInfo.InvariantCulture));
        }

        private static string BuildTopologyFingerprint(IEnumerable<string> keys)
        {
            List<string> sorted = new List<string>(keys);
            sorted.Sort(StringComparer.OrdinalIgnoreCase);
            if (sorted.Count == 0)
                return String.Empty;
            string joined = String.Join("\n", sorted).ToLowerInvariant();
            using (SHA256 sha = SHA256.Create())
            {
                byte[] digest = sha.ComputeHash(Encoding.UTF8.GetBytes(joined));
                return BitConverter.ToString(digest).Replace("-", String.Empty).ToLowerInvariant();
            }
        }

        private static bool TryNormalizeAdapterIdentity(string value, out string key)
        {
            key = String.Empty;
            Match match = AdapterIdentityPattern.Match((value ?? String.Empty).Trim());
            if (!match.Success)
                return false;

            return TryBuildNormalizedKey(match, out key);
        }

        private static bool TryParseCounterIdentity(string value, out string key, out string suffix)
        {
            key = String.Empty;
            suffix = String.Empty;
            Match match = CounterIdentityPattern.Match((value ?? String.Empty).Trim());
            if (!match.Success || !TryBuildNormalizedKey(match, out key))
                return false;
            suffix = match.Groups["suffix"].Value;
            return true;
        }

        private static bool TryBuildNormalizedKey(Match match, out string key)
        {
            key = String.Empty;

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
