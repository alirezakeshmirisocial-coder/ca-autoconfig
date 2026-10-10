using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;

namespace CA.SystemOverlay
{
    [DataContract]
    internal sealed class WindowsGpuPollingReasonCount
    {
        [DataMember(Name = "code", Order = 1)] public string Code;
        [DataMember(Name = "count", Order = 2)] public int Count;
    }

    [DataContract]
    internal sealed class WindowsGpuPollingReportDocument
    {
        [DataMember(Name = "schemaVersion", Order = 1)] public int SchemaVersion;
        [DataMember(Name = "capturedUtc", Order = 2)] public string CapturedUtc;
        [DataMember(Name = "source", Order = 3)] public string Source;
        [DataMember(Name = "counterProvider", Order = 4)] public string CounterProvider;
        [DataMember(Name = "durationSeconds", Order = 5)] public int DurationSeconds;
        [DataMember(Name = "intervalMilliseconds", Order = 6)] public int IntervalMilliseconds;
        [DataMember(Name = "elapsedMilliseconds", Order = 7)] public long ElapsedMilliseconds;
        [DataMember(Name = "normalizedProcessCpuPercent", Order = 8)] public double NormalizedProcessCpuPercent;
        [DataMember(Name = "finalStatus", Order = 9)] public string FinalStatus;
        [DataMember(Name = "mappingReadyForValidation", Order = 10)] public bool MappingReadyForValidation;
        [DataMember(Name = "canUseInHud", Order = 11)] public bool CanUseInHud;
        [DataMember(Name = "consecutiveStableSamples", Order = 12)] public int ConsecutiveStableSamples;
        [DataMember(Name = "completedCollections", Order = 13)] public int CompletedCollections;
        [DataMember(Name = "successfulMappingCollections", Order = 14)] public int SuccessfulMappingCollections;
        [DataMember(Name = "unavailableCollections", Order = 15)] public int UnavailableCollections;
        [DataMember(Name = "suppressedOverlaps", Order = 16)] public int SuppressedOverlaps;
        [DataMember(Name = "lastCollectionDurationMilliseconds", Order = 17)] public long LastCollectionDurationMilliseconds;
        [DataMember(Name = "maximumCollectionDurationMilliseconds", Order = 18)] public long MaximumCollectionDurationMilliseconds;
        [DataMember(Name = "reasonCodes", Order = 19)] public string[] ReasonCodes;
        [DataMember(Name = "failureReasonCounts", Order = 20)] public WindowsGpuPollingReasonCount[] FailureReasonCounts;
        [DataMember(Name = "adapters", Order = 21)] public WindowsGpuPublicAdapter[] Adapters;
        [DataMember(Name = "hardwareWrites", Order = 22)] public bool HardwareWrites;
        [DataMember(Name = "networkAccess", Order = 23)] public bool NetworkAccess;
        [DataMember(Name = "elevationRequested", Order = 24)] public bool ElevationRequested;
        [DataMember(Name = "rawAdapterIdentifiersIncluded", Order = 25)] public bool RawAdapterIdentifiersIncluded;
        [DataMember(Name = "engineLoadReadyForValidation", Order = 26)] public bool EngineLoadReadyForValidation;
        [DataMember(Name = "dedicatedMemoryReadyForValidation", Order = 27)] public bool DedicatedMemoryReadyForValidation;
        [DataMember(Name = "successfulEngineLoadCollections", Order = 28)] public int SuccessfulEngineLoadCollections;
        [DataMember(Name = "successfulDedicatedMemoryCollections", Order = 29)] public int SuccessfulDedicatedMemoryCollections;
        [DataMember(Name = "partialMappingCollections", Order = 30)] public int PartialMappingCollections;
    }

    internal static class WindowsGpuPollingBenchmark
    {
        internal static int Write(string resultPath, int durationSeconds, int intervalMilliseconds)
        {
            return Write(resultPath, durationSeconds, intervalMilliseconds, "wmi");
        }

        internal static int Write(string resultPath, int durationSeconds, int intervalMilliseconds, string providerName)
        {
            if (durationSeconds < 10 || durationSeconds > 3600)
                throw new ArgumentOutOfRangeException("durationSeconds");
            if (intervalMilliseconds < 1000 || intervalMilliseconds > 60000)
                throw new ArgumentOutOfRangeException("intervalMilliseconds");

            try
            {
                bool usePdh = String.Equals(providerName, "pdh", StringComparison.OrdinalIgnoreCase);
                bool usePdhRaw = String.Equals(providerName, "pdh-raw", StringComparison.OrdinalIgnoreCase);
                if (!usePdh && !usePdhRaw && !String.Equals(providerName, "wmi", StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("Windows GPU provider must be 'wmi', 'pdh', or 'pdh-raw'.", "providerName");
                using (PdhWindowsGpuCounterSource pdhSource = usePdh
                    ? new PdhWindowsGpuCounterSource()
                    : (usePdhRaw
                        ? new PdhWindowsGpuCounterSource(new NativeRawPdhGpuCounterReader())
                        : null))
                {
                    Func<WindowsGpuLiveProbeResult> collector;
                    string counterProvider;
                    if (usePdhRaw)
                    {
                        collector = new Func<WindowsGpuLiveProbeResult>(delegate
                        {
                            return WindowsGpuLiveProbe.RunPdhRaw(pdhSource);
                        });
                        counterProvider = "windows-pdh-raw-engine";
                    }
                    else if (usePdh)
                    {
                        collector = new Func<WindowsGpuLiveProbeResult>(delegate
                        {
                            return WindowsGpuLiveProbe.RunPdh(pdhSource);
                        });
                        counterProvider = "windows-pdh";
                    }
                    else
                    {
                        collector = new Func<WindowsGpuLiveProbeResult>(WindowsGpuLiveProbe.Run);
                        counterProvider = "windows-wmi-formatted";
                    }
                    TimeSpan cpuStart;
                    TimeSpan cpuEnd;
                    Stopwatch elapsed = Stopwatch.StartNew();
                    WindowsGpuPollingSnapshot snapshot;
                    using (Process process = Process.GetCurrentProcess())
                    {
                        process.Refresh();
                        cpuStart = process.TotalProcessorTime;
                        using (WindowsGpuPollingProvider provider = new WindowsGpuPollingProvider(
                            collector,
                            delegate { return DateTime.UtcNow; },
                            TimeSpan.FromMilliseconds(Math.Max(8000, intervalMilliseconds * 4)),
                            2))
                        {
                            provider.Start(intervalMilliseconds);
                            Thread.Sleep(TimeSpan.FromSeconds(durationSeconds));
                            snapshot = provider.GetSnapshot();
                        }
                        elapsed.Stop();
                        process.Refresh();
                        cpuEnd = process.TotalProcessorTime;
                    }

                    double cpuPercent = 0;
                    if (elapsed.Elapsed.TotalMilliseconds > 0 && Environment.ProcessorCount > 0)
                    {
                        cpuPercent = 100.0 * (cpuEnd - cpuStart).TotalMilliseconds /
                            (elapsed.Elapsed.TotalMilliseconds * Environment.ProcessorCount);
                    }
                    WindowsGpuPollingReportDocument document = Create(
                        snapshot,
                        DateTime.UtcNow,
                        durationSeconds,
                        intervalMilliseconds,
                        elapsed.ElapsedMilliseconds,
                        cpuPercent,
                        counterProvider);
                    string fullPath = Path.GetFullPath(resultPath);
                    string directory = Path.GetDirectoryName(fullPath);
                    if (!String.IsNullOrWhiteSpace(directory))
                        Directory.CreateDirectory(directory);
                    File.WriteAllText(fullPath, Serialize(document), new UTF8Encoding(false));
                    return 0;
                }
            }
            catch
            {
                return 1;
            }
        }

        internal static WindowsGpuPollingReportDocument Create(
            WindowsGpuPollingSnapshot snapshot,
            DateTime capturedUtc,
            int durationSeconds,
            int intervalMilliseconds,
            long elapsedMilliseconds,
            double normalizedProcessCpuPercent)
        {
            return Create(
                snapshot,
                capturedUtc,
                durationSeconds,
                intervalMilliseconds,
                elapsedMilliseconds,
                normalizedProcessCpuPercent,
                "injected-fixture");
        }

        internal static WindowsGpuPollingReportDocument Create(
            WindowsGpuPollingSnapshot snapshot,
            DateTime capturedUtc,
            int durationSeconds,
            int intervalMilliseconds,
            long elapsedMilliseconds,
            double normalizedProcessCpuPercent,
            string counterProvider)
        {
            if (snapshot == null)
                throw new ArgumentNullException("snapshot");
            bool finalStateReady = snapshot.Status == "READY_FOR_VALIDATION" ||
                snapshot.Status == "PARTIAL_READY_FOR_VALIDATION";
            bool noMissedCadence = snapshot.SuppressedOverlapCount == 0;
            bool engineSustained = finalStateReady && noMissedCadence &&
                snapshot.CompletedCollectionCount > 0 &&
                snapshot.SuccessfulEngineLoadCollectionCount == snapshot.CompletedCollectionCount;
            bool memorySustained = finalStateReady && noMissedCadence &&
                snapshot.CompletedCollectionCount > 0 &&
                snapshot.SuccessfulDedicatedMemoryCollectionCount == snapshot.CompletedCollectionCount;
            List<WindowsGpuPublicAdapter> adapters = new List<WindowsGpuPublicAdapter>();
            List<WindowsGpuPollingReasonCount> failureReasons = new List<WindowsGpuPollingReasonCount>();
            foreach (WindowsGpuMappedMetric adapter in snapshot.Adapters)
            {
                int engineLoadPercent = adapter.EngineLoadPercent;
                long dedicatedMemoryBytes = adapter.DedicatedMemoryBytes;
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
            List<string> failureCodes = new List<string>(snapshot.FailureReasonCounts.Keys);
            failureCodes.Sort(StringComparer.Ordinal);
            foreach (string code in failureCodes)
            {
                failureReasons.Add(new WindowsGpuPollingReasonCount
                {
                    Code = code,
                    Count = snapshot.FailureReasonCounts[code]
                });
            }

            return new WindowsGpuPollingReportDocument
            {
                SchemaVersion = 3,
                CapturedUtc = capturedUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                Source = "live-windows-polling-read-only",
                CounterProvider = counterProvider,
                DurationSeconds = durationSeconds,
                IntervalMilliseconds = intervalMilliseconds,
                ElapsedMilliseconds = elapsedMilliseconds,
                NormalizedProcessCpuPercent = Math.Round(Math.Max(0, normalizedProcessCpuPercent), 3),
                FinalStatus = snapshot.Status,
                MappingReadyForValidation = engineSustained && memorySustained,
                CanUseInHud = false,
                ConsecutiveStableSamples = snapshot.ConsecutiveStableSamples,
                CompletedCollections = snapshot.CompletedCollectionCount,
                SuccessfulMappingCollections = snapshot.SuccessfulMappingCollectionCount,
                UnavailableCollections = snapshot.UnavailableCollectionCount,
                SuppressedOverlaps = snapshot.SuppressedOverlapCount,
                LastCollectionDurationMilliseconds = snapshot.LastCollectionDurationMilliseconds,
                MaximumCollectionDurationMilliseconds = snapshot.MaximumCollectionDurationMilliseconds,
                ReasonCodes = snapshot.ReasonCodes.ToArray(),
                FailureReasonCounts = failureReasons.ToArray(),
                Adapters = adapters.ToArray(),
                HardwareWrites = false,
                NetworkAccess = false,
                ElevationRequested = false,
                RawAdapterIdentifiersIncluded = false,
                EngineLoadReadyForValidation = engineSustained,
                DedicatedMemoryReadyForValidation = memorySustained,
                SuccessfulEngineLoadCollections = snapshot.SuccessfulEngineLoadCollectionCount,
                SuccessfulDedicatedMemoryCollections = snapshot.SuccessfulDedicatedMemoryCollectionCount,
                PartialMappingCollections = snapshot.PartialMappingCollectionCount
            };
        }

        internal static string Serialize(WindowsGpuPollingReportDocument document)
        {
            DataContractJsonSerializer serializer = new DataContractJsonSerializer(typeof(WindowsGpuPollingReportDocument));
            using (MemoryStream stream = new MemoryStream())
            {
                serializer.WriteObject(stream, document);
                return Encoding.UTF8.GetString(stream.ToArray());
            }
        }
    }
}
