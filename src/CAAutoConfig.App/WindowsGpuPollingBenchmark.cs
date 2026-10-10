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
    internal sealed class WindowsGpuPollingReportDocument
    {
        [DataMember(Name = "schemaVersion", Order = 1)] public int SchemaVersion;
        [DataMember(Name = "capturedUtc", Order = 2)] public string CapturedUtc;
        [DataMember(Name = "source", Order = 3)] public string Source;
        [DataMember(Name = "durationSeconds", Order = 4)] public int DurationSeconds;
        [DataMember(Name = "intervalMilliseconds", Order = 5)] public int IntervalMilliseconds;
        [DataMember(Name = "elapsedMilliseconds", Order = 6)] public long ElapsedMilliseconds;
        [DataMember(Name = "normalizedProcessCpuPercent", Order = 7)] public double NormalizedProcessCpuPercent;
        [DataMember(Name = "finalStatus", Order = 8)] public string FinalStatus;
        [DataMember(Name = "mappingReadyForValidation", Order = 9)] public bool MappingReadyForValidation;
        [DataMember(Name = "canUseInHud", Order = 10)] public bool CanUseInHud;
        [DataMember(Name = "consecutiveStableSamples", Order = 11)] public int ConsecutiveStableSamples;
        [DataMember(Name = "completedCollections", Order = 12)] public int CompletedCollections;
        [DataMember(Name = "successfulMappingCollections", Order = 13)] public int SuccessfulMappingCollections;
        [DataMember(Name = "unavailableCollections", Order = 14)] public int UnavailableCollections;
        [DataMember(Name = "suppressedOverlaps", Order = 15)] public int SuppressedOverlaps;
        [DataMember(Name = "lastCollectionDurationMilliseconds", Order = 16)] public long LastCollectionDurationMilliseconds;
        [DataMember(Name = "maximumCollectionDurationMilliseconds", Order = 17)] public long MaximumCollectionDurationMilliseconds;
        [DataMember(Name = "reasonCodes", Order = 18)] public string[] ReasonCodes;
        [DataMember(Name = "adapters", Order = 19)] public WindowsGpuPublicAdapter[] Adapters;
        [DataMember(Name = "hardwareWrites", Order = 20)] public bool HardwareWrites;
        [DataMember(Name = "networkAccess", Order = 21)] public bool NetworkAccess;
        [DataMember(Name = "elevationRequested", Order = 22)] public bool ElevationRequested;
        [DataMember(Name = "rawAdapterIdentifiersIncluded", Order = 23)] public bool RawAdapterIdentifiersIncluded;
    }

    internal static class WindowsGpuPollingBenchmark
    {
        internal static int Write(string resultPath, int durationSeconds, int intervalMilliseconds)
        {
            if (durationSeconds < 10 || durationSeconds > 3600)
                throw new ArgumentOutOfRangeException("durationSeconds");
            if (intervalMilliseconds < 1000 || intervalMilliseconds > 60000)
                throw new ArgumentOutOfRangeException("intervalMilliseconds");

            try
            {
                TimeSpan cpuStart;
                TimeSpan cpuEnd;
                Stopwatch elapsed = Stopwatch.StartNew();
                WindowsGpuPollingSnapshot snapshot;
                using (Process process = Process.GetCurrentProcess())
                {
                    process.Refresh();
                    cpuStart = process.TotalProcessorTime;
                    using (WindowsGpuPollingProvider provider = new WindowsGpuPollingProvider())
                    {
                        provider.Start(intervalMilliseconds);
                        Thread.Sleep(TimeSpan.FromSeconds(durationSeconds));
                        provider.Dispose();
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
                    cpuPercent);
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

        internal static WindowsGpuPollingReportDocument Create(
            WindowsGpuPollingSnapshot snapshot,
            DateTime capturedUtc,
            int durationSeconds,
            int intervalMilliseconds,
            long elapsedMilliseconds,
            double normalizedProcessCpuPercent)
        {
            if (snapshot == null)
                throw new ArgumentNullException("snapshot");
            List<WindowsGpuPublicAdapter> adapters = new List<WindowsGpuPublicAdapter>();
            foreach (WindowsGpuMappedMetric adapter in snapshot.Adapters)
            {
                int vramPercent = -1;
                if (adapter.DedicatedMemoryBytes >= 0 && adapter.DedicatedMemoryCapacityBytes > 0)
                {
                    vramPercent = Math.Max(0, Math.Min(100, (int)Math.Round(
                        100.0 * adapter.DedicatedMemoryBytes / adapter.DedicatedMemoryCapacityBytes,
                        MidpointRounding.AwayFromZero)));
                }
                adapters.Add(new WindowsGpuPublicAdapter
                {
                    Index = adapter.DisplayIndex,
                    Name = adapter.Name,
                    EngineLoadPercent = adapter.EngineLoadPercent,
                    DedicatedMemoryBytes = adapter.DedicatedMemoryBytes,
                    DedicatedMemoryCapacityBytes = adapter.DedicatedMemoryCapacityBytes,
                    VramPercent = vramPercent
                });
            }

            return new WindowsGpuPollingReportDocument
            {
                SchemaVersion = 1,
                CapturedUtc = capturedUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                Source = "live-windows-polling-read-only",
                DurationSeconds = durationSeconds,
                IntervalMilliseconds = intervalMilliseconds,
                ElapsedMilliseconds = elapsedMilliseconds,
                NormalizedProcessCpuPercent = Math.Round(Math.Max(0, normalizedProcessCpuPercent), 3),
                FinalStatus = snapshot.Status,
                MappingReadyForValidation = snapshot.Status == "READY_FOR_VALIDATION",
                CanUseInHud = false,
                ConsecutiveStableSamples = snapshot.ConsecutiveStableSamples,
                CompletedCollections = snapshot.CompletedCollectionCount,
                SuccessfulMappingCollections = snapshot.SuccessfulMappingCollectionCount,
                UnavailableCollections = snapshot.UnavailableCollectionCount,
                SuppressedOverlaps = snapshot.SuppressedOverlapCount,
                LastCollectionDurationMilliseconds = snapshot.LastCollectionDurationMilliseconds,
                MaximumCollectionDurationMilliseconds = snapshot.MaximumCollectionDurationMilliseconds,
                ReasonCodes = snapshot.ReasonCodes.ToArray(),
                Adapters = adapters.ToArray(),
                HardwareWrites = false,
                NetworkAccess = false,
                ElevationRequested = false,
                RawAdapterIdentifiersIncluded = false
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
