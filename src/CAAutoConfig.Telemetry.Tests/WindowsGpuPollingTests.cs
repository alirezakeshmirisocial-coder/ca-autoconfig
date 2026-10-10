using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using CA.SystemOverlay;

internal static class WindowsGpuPollingTests
{
    internal static int RunAll()
    {
        var tests = new (string Name, Action Body)[]
        {
            ("polling requires consecutive stable samples", RequiresStableSamples),
            ("adapter reorder preserves a stable topology", ReorderPreservesTopology),
            ("topology change requires revalidation", TopologyChangeRequiresRevalidation),
            ("collector failure clears published rows", CollectorFailureClearsRows),
            ("mapping failure retains reason and clears rows", MappingFailureClearsRows),
            ("partial mapping retains only the healthy field family", PartialMappingRetainsHealthyFamily),
            ("partial polling report preserves a healthy adapter row", PartialPollingReportPreservesHealthyAdapter),
            ("expired snapshot becomes stale", ExpiredSnapshotBecomesStale),
            ("overlapping collection is suppressed", OverlappingCollectionIsSuppressed),
            ("polling output remains non-authorizing", OutputRemainsNonAuthorizing),
            ("collection metrics count success and failure", CollectionMetricsAreRetained),
            ("polling report is sanitized and non-authorizing", PollingReportIsSanitized),
            ("recovered final sample cannot hide a partial run", RecoveredFinalSampleDoesNotPassSustainedGate)
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

    private static void RequiresStableSamples()
    {
        DateTime now = DateTime.Parse("2026-10-10T12:00:00Z").ToUniversalTime();
        using (WindowsGpuPollingProvider provider = Provider(delegate { return Success("topology-a", false); }, delegate { return now; }))
        {
            Assert(provider.CollectOnce(), "First collection did not run.");
            WindowsGpuPollingSnapshot first = provider.GetSnapshot();
            Assert(first.Status == "WARMING_UP" && first.Adapters.Count == 0 && first.ConsecutiveStableSamples == 1, "First sample was promoted.");
            Assert(provider.CollectOnce(), "Second collection did not run.");
            WindowsGpuPollingSnapshot second = provider.GetSnapshot();
            Assert(second.Status == "READY_FOR_VALIDATION" && second.Adapters.Count == 2 && second.ConsecutiveStableSamples == 2, "Stable pair did not reach the research boundary.");
        }
    }

    private static void ReorderPreservesTopology()
    {
        DateTime now = DateTime.UtcNow;
        int call = 0;
        using (WindowsGpuPollingProvider provider = Provider(delegate
        {
            call++;
            return Success("same-topology", call > 1);
        }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            Assert(snapshot.Status == "READY_FOR_VALIDATION" && snapshot.Adapters.Count == 2, "Reordered rows reset a stable identity set.");
            Assert(snapshot.Adapters[0].DisplayIndex == 0 && snapshot.Adapters[1].DisplayIndex == 1, "Published rows were not normalized by display index.");
        }
    }

    private static void TopologyChangeRequiresRevalidation()
    {
        DateTime now = DateTime.UtcNow;
        Queue<WindowsGpuLiveProbeResult> results = new Queue<WindowsGpuLiveProbeResult>(new[]
        {
            Success("topology-a", false), Success("topology-a", false),
            Success("topology-b", false), Success("topology-b", false)
        });
        using (WindowsGpuPollingProvider provider = Provider(delegate { return results.Dequeue(); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            Assert(provider.GetSnapshot().Status == "READY_FOR_VALIDATION", "Initial topology did not stabilize.");
            provider.CollectOnce();
            WindowsGpuPollingSnapshot changed = provider.GetSnapshot();
            Assert(changed.Status == "TOPOLOGY_CHANGED" && changed.Adapters.Count == 0 && changed.ReasonCodes.Contains("topology-revalidation-required"), "Changed topology retained trusted rows.");
            provider.CollectOnce();
            Assert(provider.GetSnapshot().Status == "READY_FOR_VALIDATION", "Changed topology did not recover after a stable pair.");
        }
    }

    private static void CollectorFailureClearsRows()
    {
        DateTime now = DateTime.UtcNow;
        int call = 0;
        using (WindowsGpuPollingProvider provider = Provider(delegate
        {
            call++;
            if (call <= 2) return Success("topology-a", false);
            throw new InvalidOperationException("fixture failure");
        }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot failed = provider.GetSnapshot();
            Assert(failed.Status == "UNAVAILABLE" && failed.Adapters.Count == 0 && failed.ReasonCodes.Contains("collector-failed"), "Collector failure retained trusted data.");
        }
    }

    private static void MappingFailureClearsRows()
    {
        DateTime now = DateTime.UtcNow;
        int call = 0;
        using (WindowsGpuPollingProvider provider = Provider(delegate
        {
            call++;
            return call <= 2 ? Success("topology-a", false) : Blocked("counter-adapter-not-in-inventory");
        }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot failed = provider.GetSnapshot();
            Assert(failed.Status == "UNAVAILABLE" && failed.Adapters.Count == 0 && failed.ReasonCodes.Contains("counter-adapter-not-in-inventory"), "Mapping failure was hidden or retained rows.");
        }
    }

    private static void PartialMappingRetainsHealthyFamily()
    {
        DateTime now = DateTime.UtcNow;
        using (WindowsGpuPollingProvider provider = Provider(delegate { return PartialMemory("topology-a"); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            Assert(snapshot.Status == "PARTIAL_READY_FOR_VALIDATION", "Stable partial evidence was not labeled explicitly.");
            Assert(!snapshot.EngineLoadMappingChecksPass && snapshot.DedicatedMemoryMappingChecksPass, "Per-field polling state is wrong.");
            Assert(snapshot.Adapters.Count == 2 && snapshot.Adapters[0].EngineLoadPercent == -1 && snapshot.Adapters[0].DedicatedMemoryBytes >= 0, "Healthy memory rows were discarded.");
            Assert(snapshot.SuccessfulMappingCollectionCount == 0 && snapshot.SuccessfulEngineLoadCollectionCount == 0 && snapshot.SuccessfulDedicatedMemoryCollectionCount == 2 && snapshot.PartialMappingCollectionCount == 2 && snapshot.UnavailableCollectionCount == 0, "Partial collection counters are wrong.");
            Assert(snapshot.FailureReasonCounts.ContainsKey("pdh-engine-data-invalid") && snapshot.FailureReasonCounts["pdh-engine-data-invalid"] == 2, "Partial failure histogram is wrong.");
            Assert(!snapshot.CanUseInHud, "Partial polling evidence authorized HUD use.");
        }
    }

    private static void PartialPollingReportPreservesHealthyAdapter()
    {
        DateTime now = DateTime.UtcNow;
        using (WindowsGpuPollingProvider provider = Provider(delegate { return PartialAdapterEngine("topology-a"); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            WindowsGpuPollingReportDocument report = WindowsGpuPollingBenchmark.Create(snapshot, now, 60, 2000, 4000, 0.1);
            Assert(report.FinalStatus == "PARTIAL_READY_FOR_VALIDATION" && report.Adapters.Length == 2, "Adapter-scoped partial result became unavailable.");
            Assert(!report.Adapters[0].EngineLoadAvailable && !report.Adapters[0].DedicatedMemoryAvailable, "Failed adapter exposed a field.");
            Assert(report.Adapters[1].EngineLoadAvailable && report.Adapters[1].DedicatedMemoryAvailable, "Polling report erased the healthy adapter.");
            Assert(report.Adapters[0].EngineLoadPercent == -1 && report.Adapters[0].DedicatedMemoryBytes == -1 &&
                report.Adapters[1].EngineLoadPercent == 20 && report.Adapters[1].DedicatedMemoryBytes == 20, "Polling report changed adapter-scoped values.");
            Assert(!report.EngineLoadReadyForValidation && !report.DedicatedMemoryReadyForValidation && !report.MappingReadyForValidation && !report.CanUseInHud, "Adapter-scoped partial report weakened a gate.");
            Assert(report.PartialMappingCollections == 2 && report.UnavailableCollections == 0, "Healthy sibling adapter was counted as fully unavailable.");
        }
    }

    private static void ExpiredSnapshotBecomesStale()
    {
        DateTime now = DateTime.Parse("2026-10-10T12:00:00Z").ToUniversalTime();
        using (WindowsGpuPollingProvider provider = Provider(delegate { return Success("topology-a", false); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            now = now.AddSeconds(9);
            WindowsGpuPollingSnapshot stale = provider.GetSnapshot();
            Assert(stale.Status == "STALE" && stale.Adapters.Count == 0 && stale.ReasonCodes.Contains("sample-stale"), "Expired data remained publishable.");
        }
    }

    private static void OverlappingCollectionIsSuppressed()
    {
        DateTime now = DateTime.UtcNow;
        using (ManualResetEventSlim entered = new ManualResetEventSlim(false))
        using (ManualResetEventSlim release = new ManualResetEventSlim(false))
        using (WindowsGpuPollingProvider provider = Provider(delegate
        {
            entered.Set();
            if (!release.Wait(TimeSpan.FromSeconds(5)))
                throw new TimeoutException("fixture release timed out");
            return Success("topology-a", false);
        }, delegate { return now; }))
        {
            Task<bool> first = Task.Run(delegate { return provider.CollectOnce(); });
            Assert(entered.Wait(TimeSpan.FromSeconds(5)), "Fixture collector did not start.");
            Assert(!provider.CollectOnce(), "Overlapping collection was allowed.");
            release.Set();
            Assert(first.Result, "Original collection did not complete.");
            Assert(provider.GetSnapshot().SuppressedOverlapCount == 1, "Suppressed overlap was not recorded.");
        }
    }

    private static void OutputRemainsNonAuthorizing()
    {
        DateTime now = DateTime.UtcNow;
        using (WindowsGpuPollingProvider provider = Provider(delegate { return Success("topology-a", false); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            Assert(!snapshot.CanUseInHud && !snapshot.HardwareWrites && !snapshot.NetworkAccess && !snapshot.ElevationRequested && !snapshot.RawAdapterIdentifiersIncluded, "Polling weakened a safety boundary.");
        }
    }

    private static void CollectionMetricsAreRetained()
    {
        DateTime now = DateTime.UtcNow;
        int call = 0;
        using (WindowsGpuPollingProvider provider = Provider(delegate
        {
            call++;
            return call <= 2 ? Success("topology-a", false) : Blocked("fixture-unavailable");
        }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            Assert(snapshot.CompletedCollectionCount == 3, "Completed collection count is wrong.");
            Assert(snapshot.SuccessfulMappingCollectionCount == 2 && snapshot.UnavailableCollectionCount == 1, "Success/failure counts are wrong.");
            Assert(snapshot.SuccessfulEngineLoadCollectionCount == 2 && snapshot.SuccessfulDedicatedMemoryCollectionCount == 2 && snapshot.PartialMappingCollectionCount == 0, "Per-field success counts are wrong.");
            Assert(snapshot.FailureReasonCounts.ContainsKey("fixture-unavailable") && snapshot.FailureReasonCounts["fixture-unavailable"] == 1, "Failure reason histogram is wrong.");
            Assert(snapshot.LastCollectionDurationMilliseconds >= 0 && snapshot.MaximumCollectionDurationMilliseconds >= snapshot.LastCollectionDurationMilliseconds, "Collection duration metrics are invalid.");
        }
    }

    private static void PollingReportIsSanitized()
    {
        DateTime now = DateTime.UtcNow;
        using (WindowsGpuPollingProvider provider = Provider(delegate { return Success("private-fingerprint", false); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            WindowsGpuPollingReportDocument report = WindowsGpuPollingBenchmark.Create(snapshot, now, 600, 2000, 600000, 0.25);
            string json = WindowsGpuPollingBenchmark.Serialize(report);
            Assert(report.SchemaVersion == 3, "Polling report schema was not advanced for per-field evidence.");
            Assert(report.CounterProvider == "injected-fixture", "Polling report omitted its explicit counter provider.");
            Assert(report.EngineLoadReadyForValidation && report.DedicatedMemoryReadyForValidation, "Polling report omitted per-field readiness.");
            Assert(json.Contains("live-windows-polling-read-only", StringComparison.Ordinal), "Polling report omitted its source boundary.");
            Assert(json.Contains("\"normalizedProcessCpuPercent\":0.25", StringComparison.Ordinal), "Polling report omitted normalized process CPU.");
            Assert(!json.Contains("private-fingerprint", StringComparison.Ordinal) && !json.Contains("luid_", StringComparison.OrdinalIgnoreCase) && !json.Contains("pid_", StringComparison.OrdinalIgnoreCase), "Polling report exposed internal identity.");
            Assert(!report.CanUseInHud && !report.HardwareWrites && !report.NetworkAccess && !report.ElevationRequested && !report.RawAdapterIdentifiersIncluded, "Polling report weakened a safety boundary.");
        }
    }

    private static void RecoveredFinalSampleDoesNotPassSustainedGate()
    {
        DateTime now = DateTime.UtcNow;
        Queue<WindowsGpuLiveProbeResult> results = new Queue<WindowsGpuLiveProbeResult>(new[]
        {
            PartialMemory("topology-a"), Success("topology-a", false)
        });
        using (WindowsGpuPollingProvider provider = Provider(delegate { return results.Dequeue(); }, delegate { return now; }))
        {
            provider.CollectOnce();
            provider.CollectOnce();
            WindowsGpuPollingSnapshot snapshot = provider.GetSnapshot();
            Assert(snapshot.Status == "READY_FOR_VALIDATION", "Fixture did not recover to a complete final sample.");
            WindowsGpuPollingReportDocument report = WindowsGpuPollingBenchmark.Create(snapshot, now, 60, 2000, 4000, 0.1);
            Assert(!report.MappingReadyForValidation && !report.EngineLoadReadyForValidation, "A recovered final sample hid an earlier engine failure.");
            Assert(report.DedicatedMemoryReadyForValidation, "A fully successful memory family did not retain sustained readiness.");
        }
    }

    private static WindowsGpuPollingProvider Provider(Func<WindowsGpuLiveProbeResult> collector, Func<DateTime> clock)
    {
        return new WindowsGpuPollingProvider(collector, clock, TimeSpan.FromSeconds(8), 2);
    }

    private static WindowsGpuLiveProbeResult Success(string fingerprint, bool reverse)
    {
        List<WindowsGpuMappedMetric> adapters = new List<WindowsGpuMappedMetric>
        {
            new WindowsGpuMappedMetric { DisplayIndex = 0, Name = "GPU A", EngineLoadPercent = 10, DedicatedMemoryBytes = 10, DedicatedMemoryCapacityBytes = 100 },
            new WindowsGpuMappedMetric { DisplayIndex = 1, Name = "GPU B", EngineLoadPercent = 20, DedicatedMemoryBytes = 20, DedicatedMemoryCapacityBytes = 100 }
        };
        if (reverse) adapters.Reverse();
        return new WindowsGpuLiveProbeResult
        {
            ProbeStatus = "MAPPING_AVAILABLE",
            MappingChecksPass = true,
            EngineLoadMappingChecksPass = true,
            DedicatedMemoryMappingChecksPass = true,
            InternalTopologyFingerprint = fingerprint,
            Adapters = adapters
        };
    }

    private static WindowsGpuLiveProbeResult PartialMemory(string fingerprint)
    {
        return new WindowsGpuLiveProbeResult
        {
            ProbeStatus = "PARTIAL_MAPPING_AVAILABLE",
            MappingChecksPass = false,
            EngineLoadMappingChecksPass = false,
            DedicatedMemoryMappingChecksPass = true,
            InternalTopologyFingerprint = fingerprint,
            ReasonCodes = new List<string> { "pdh-engine-data-invalid", "engine-counter-missing" },
            Adapters = new List<WindowsGpuMappedMetric>
            {
                new WindowsGpuMappedMetric { DisplayIndex = 0, Name = "GPU A", EngineLoadPercent = -1, DedicatedMemoryBytes = 10, DedicatedMemoryCapacityBytes = 100 },
                new WindowsGpuMappedMetric { DisplayIndex = 1, Name = "GPU B", EngineLoadPercent = -1, DedicatedMemoryBytes = 20, DedicatedMemoryCapacityBytes = 100 }
            }
        };
    }

    private static WindowsGpuLiveProbeResult PartialAdapterEngine(string fingerprint)
    {
        return new WindowsGpuLiveProbeResult
        {
            ProbeStatus = "PARTIAL_MAPPING_AVAILABLE",
            MappingChecksPass = false,
            EngineLoadMappingChecksPass = false,
            DedicatedMemoryMappingChecksPass = false,
            InternalTopologyFingerprint = fingerprint,
            ReasonCodes = new List<string>
            {
                "pdh-engine-data-invalid",
                "pdh-engine-data-invalid-adapter-0",
                "pdh-memory-data-invalid",
                "pdh-memory-data-invalid-adapter-0"
            },
            Adapters = new List<WindowsGpuMappedMetric>
            {
                new WindowsGpuMappedMetric { DisplayIndex = 0, Name = "GPU A", EngineLoadPercent = -1, DedicatedMemoryBytes = -1, DedicatedMemoryCapacityBytes = 100 },
                new WindowsGpuMappedMetric { DisplayIndex = 1, Name = "GPU B", EngineLoadPercent = 20, DedicatedMemoryBytes = 20, DedicatedMemoryCapacityBytes = 100 }
            }
        };
    }

    private static WindowsGpuLiveProbeResult Blocked(string reason)
    {
        return new WindowsGpuLiveProbeResult
        {
            ProbeStatus = "BLOCKED",
            MappingChecksPass = false,
            ReasonCodes = new List<string> { reason }
        };
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}
