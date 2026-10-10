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
            ("expired snapshot becomes stale", ExpiredSnapshotBecomesStale),
            ("overlapping collection is suppressed", OverlappingCollectionIsSuppressed),
            ("polling output remains non-authorizing", OutputRemainsNonAuthorizing)
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
            InternalTopologyFingerprint = fingerprint,
            Adapters = adapters
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
