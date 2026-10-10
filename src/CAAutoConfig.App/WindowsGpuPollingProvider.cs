using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

namespace CA.SystemOverlay
{
    internal sealed class WindowsGpuPollingSnapshot
    {
        public string Status = "NOT_STARTED";
        public DateTime CapturedUtc;
        public int ConsecutiveStableSamples;
        public int SuppressedOverlapCount;
        public int CompletedCollectionCount;
        public int SuccessfulMappingCollectionCount;
        public int SuccessfulEngineLoadCollectionCount;
        public int SuccessfulDedicatedMemoryCollectionCount;
        public int PartialMappingCollectionCount;
        public int UnavailableCollectionCount;
        public long LastCollectionDurationMilliseconds;
        public long MaximumCollectionDurationMilliseconds;
        public Dictionary<string, int> FailureReasonCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        public bool CanUseInHud;
        public bool EngineLoadMappingChecksPass;
        public bool DedicatedMemoryMappingChecksPass;
        public bool HardwareWrites;
        public bool NetworkAccess;
        public bool ElevationRequested;
        public bool RawAdapterIdentifiersIncluded;
        public List<string> ReasonCodes = new List<string>();
        public List<WindowsGpuMappedMetric> Adapters = new List<WindowsGpuMappedMetric>();
    }

    // Research-only coordinator. It intentionally has no path into MetricSnapshot
    // or the HUD. A future integration requires explicit cross-hardware evidence.
    internal sealed class WindowsGpuPollingProvider : IDisposable
    {
        private readonly Func<WindowsGpuLiveProbeResult> _collector;
        private readonly Func<DateTime> _clock;
        private readonly TimeSpan _staleAfter;
        private readonly int _requiredStableSamples;
        private readonly object _sync = new object();
        private Timer _timer;
        private int _collecting;
        private int _suppressedOverlapCount;
        private int _completedCollectionCount;
        private int _successfulMappingCollectionCount;
        private int _successfulEngineLoadCollectionCount;
        private int _successfulDedicatedMemoryCollectionCount;
        private int _partialMappingCollectionCount;
        private int _unavailableCollectionCount;
        private long _lastCollectionDurationMilliseconds;
        private long _maximumCollectionDurationMilliseconds;
        private readonly Dictionary<string, int> _failureReasonCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        private string _topologyFingerprint = String.Empty;
        private int _stableSamples;
        private WindowsGpuPollingSnapshot _latest = new WindowsGpuPollingSnapshot();

        internal WindowsGpuPollingProvider()
            : this(WindowsGpuLiveProbe.Run, delegate { return DateTime.UtcNow; }, TimeSpan.FromSeconds(8), 2)
        {
        }

        internal WindowsGpuPollingProvider(
            Func<WindowsGpuLiveProbeResult> collector,
            Func<DateTime> clock,
            TimeSpan staleAfter,
            int requiredStableSamples)
        {
            if (collector == null)
                throw new ArgumentNullException("collector");
            if (clock == null)
                throw new ArgumentNullException("clock");
            if (staleAfter <= TimeSpan.Zero)
                throw new ArgumentOutOfRangeException("staleAfter");
            if (requiredStableSamples < 2 || requiredStableSamples > 10)
                throw new ArgumentOutOfRangeException("requiredStableSamples");
            _collector = collector;
            _clock = clock;
            _staleAfter = staleAfter;
            _requiredStableSamples = requiredStableSamples;
        }

        internal void Start(int intervalMilliseconds)
        {
            if (intervalMilliseconds < 1000 || intervalMilliseconds > 60000)
                throw new ArgumentOutOfRangeException("intervalMilliseconds");
            lock (_sync)
            {
                if (_timer != null)
                    throw new InvalidOperationException("Windows GPU polling has already started.");
                _timer = new Timer(delegate { CollectOnce(); }, null, 0, intervalMilliseconds);
            }
        }

        internal bool CollectOnce()
        {
            if (Interlocked.CompareExchange(ref _collecting, 1, 0) != 0)
            {
                Interlocked.Increment(ref _suppressedOverlapCount);
                return false;
            }

            try
            {
                Stopwatch duration = Stopwatch.StartNew();
                WindowsGpuLiveProbeResult probe;
                try
                {
                    probe = _collector();
                }
                catch
                {
                    probe = null;
                }
                DateTime capturedUtc = _clock().ToUniversalTime();
                duration.Stop();
                lock (_sync)
                {
                    Update(probe, capturedUtc);
                    _completedCollectionCount++;
                    if (probe != null && probe.MappingChecksPass)
                        _successfulMappingCollectionCount++;
                    if (probe != null && probe.EngineLoadMappingChecksPass)
                        _successfulEngineLoadCollectionCount++;
                    if (probe != null && probe.DedicatedMemoryMappingChecksPass)
                        _successfulDedicatedMemoryCollectionCount++;
                    if (probe != null && !probe.MappingChecksPass &&
                        (probe.EngineLoadMappingChecksPass || probe.DedicatedMemoryMappingChecksPass))
                        _partialMappingCollectionCount++;
                    if (probe == null || (!probe.EngineLoadMappingChecksPass && !probe.DedicatedMemoryMappingChecksPass))
                        _unavailableCollectionCount++;
                    if (probe == null)
                    {
                        RecordFailureReason("collector-failed");
                    }
                    else if (!probe.MappingChecksPass)
                    {
                        foreach (string reason in probe.ReasonCodes)
                            RecordFailureReason(reason);
                    }
                    if (String.Equals(_latest.Status, "TOPOLOGY_CHANGED", StringComparison.Ordinal))
                        RecordFailureReason("topology-revalidation-required");
                    _lastCollectionDurationMilliseconds = duration.ElapsedMilliseconds;
                    _maximumCollectionDurationMilliseconds = Math.Max(_maximumCollectionDurationMilliseconds, duration.ElapsedMilliseconds);
                    ApplyCollectionMetrics(_latest);
                }
                return true;
            }
            finally
            {
                Interlocked.Exchange(ref _collecting, 0);
            }
        }

        internal WindowsGpuPollingSnapshot GetSnapshot()
        {
            lock (_sync)
            {
                WindowsGpuPollingSnapshot copy = Clone(_latest);
                copy.SuppressedOverlapCount = Volatile.Read(ref _suppressedOverlapCount);
                ApplyCollectionMetrics(copy);
                DateTime now = _clock().ToUniversalTime();
                if (copy.CapturedUtc != default(DateTime) && now >= copy.CapturedUtc && now - copy.CapturedUtc > _staleAfter)
                {
                    copy.Status = "STALE";
                    copy.ReasonCodes.Clear();
                    copy.ReasonCodes.Add("sample-stale");
                    copy.Adapters.Clear();
                    copy.CanUseInHud = false;
                    copy.EngineLoadMappingChecksPass = false;
                    copy.DedicatedMemoryMappingChecksPass = false;
                }
                return copy;
            }
        }

        private void Update(WindowsGpuLiveProbeResult probe, DateTime capturedUtc)
        {
            WindowsGpuPollingSnapshot next = NewSafeSnapshot(capturedUtc);
            if (probe == null)
            {
                _stableSamples = 0;
                next.Status = "UNAVAILABLE";
                next.ReasonCodes.Add("collector-failed");
                _latest = next;
                return;
            }
            bool hasEngine = probe.EngineLoadMappingChecksPass;
            bool hasMemory = probe.DedicatedMemoryMappingChecksPass;
            if ((!hasEngine && !hasMemory) || String.IsNullOrWhiteSpace(probe.InternalTopologyFingerprint))
            {
                _stableSamples = 0;
                next.Status = "UNAVAILABLE";
                foreach (string reason in probe.ReasonCodes)
                    AddReason(next.ReasonCodes, reason);
                if (next.ReasonCodes.Count == 0)
                    next.ReasonCodes.Add("mapping-unavailable");
                _latest = next;
                return;
            }

            bool topologyChanged = !String.IsNullOrEmpty(_topologyFingerprint) &&
                !String.Equals(_topologyFingerprint, probe.InternalTopologyFingerprint, StringComparison.Ordinal);
            if (topologyChanged)
            {
                _topologyFingerprint = probe.InternalTopologyFingerprint;
                _stableSamples = 1;
                next.Status = "TOPOLOGY_CHANGED";
                next.ConsecutiveStableSamples = _stableSamples;
                next.ReasonCodes.Add("topology-revalidation-required");
                _latest = next;
                return;
            }

            if (String.IsNullOrEmpty(_topologyFingerprint))
                _topologyFingerprint = probe.InternalTopologyFingerprint;
            _stableSamples++;
            next.ConsecutiveStableSamples = _stableSamples;
            next.EngineLoadMappingChecksPass = hasEngine;
            next.DedicatedMemoryMappingChecksPass = hasMemory;
            if (_stableSamples < _requiredStableSamples)
            {
                next.Status = "WARMING_UP";
                next.ReasonCodes.Add("stable-samples-insufficient");
                _latest = next;
                return;
            }

            next.Status = hasEngine && hasMemory ? "READY_FOR_VALIDATION" : "PARTIAL_READY_FOR_VALIDATION";
            foreach (string reason in probe.ReasonCodes)
                AddReason(next.ReasonCodes, reason);
            next.Adapters = CloneAdapters(probe.Adapters);
            _latest = next;
        }

        private WindowsGpuPollingSnapshot NewSafeSnapshot(DateTime capturedUtc)
        {
            return new WindowsGpuPollingSnapshot
            {
                CapturedUtc = capturedUtc,
                SuppressedOverlapCount = Volatile.Read(ref _suppressedOverlapCount),
                CanUseInHud = false,
                HardwareWrites = false,
                NetworkAccess = false,
                ElevationRequested = false,
                RawAdapterIdentifiersIncluded = false
            };
        }

        private static WindowsGpuPollingSnapshot Clone(WindowsGpuPollingSnapshot source)
        {
            return new WindowsGpuPollingSnapshot
            {
                Status = source.Status,
                CapturedUtc = source.CapturedUtc,
                ConsecutiveStableSamples = source.ConsecutiveStableSamples,
                SuppressedOverlapCount = source.SuppressedOverlapCount,
                CompletedCollectionCount = source.CompletedCollectionCount,
                SuccessfulMappingCollectionCount = source.SuccessfulMappingCollectionCount,
                SuccessfulEngineLoadCollectionCount = source.SuccessfulEngineLoadCollectionCount,
                SuccessfulDedicatedMemoryCollectionCount = source.SuccessfulDedicatedMemoryCollectionCount,
                PartialMappingCollectionCount = source.PartialMappingCollectionCount,
                UnavailableCollectionCount = source.UnavailableCollectionCount,
                LastCollectionDurationMilliseconds = source.LastCollectionDurationMilliseconds,
                MaximumCollectionDurationMilliseconds = source.MaximumCollectionDurationMilliseconds,
                FailureReasonCounts = new Dictionary<string, int>(source.FailureReasonCounts, StringComparer.Ordinal),
                CanUseInHud = false,
                EngineLoadMappingChecksPass = source.EngineLoadMappingChecksPass,
                DedicatedMemoryMappingChecksPass = source.DedicatedMemoryMappingChecksPass,
                HardwareWrites = false,
                NetworkAccess = false,
                ElevationRequested = false,
                RawAdapterIdentifiersIncluded = false,
                ReasonCodes = new List<string>(source.ReasonCodes),
                Adapters = CloneAdapters(source.Adapters)
            };
        }

        private static List<WindowsGpuMappedMetric> CloneAdapters(List<WindowsGpuMappedMetric> source)
        {
            List<WindowsGpuMappedMetric> clone = new List<WindowsGpuMappedMetric>();
            foreach (WindowsGpuMappedMetric adapter in source)
            {
                clone.Add(new WindowsGpuMappedMetric
                {
                    DisplayIndex = adapter.DisplayIndex,
                    Name = adapter.Name,
                    DriverVersion = adapter.DriverVersion,
                    EngineLoadPercent = adapter.EngineLoadPercent,
                    DedicatedMemoryBytes = adapter.DedicatedMemoryBytes,
                    DedicatedMemoryCapacityBytes = adapter.DedicatedMemoryCapacityBytes
                });
            }
            clone.Sort(delegate(WindowsGpuMappedMetric left, WindowsGpuMappedMetric right)
            {
                return left.DisplayIndex.CompareTo(right.DisplayIndex);
            });
            return clone;
        }

        private static void AddReason(List<string> reasons, string reason)
        {
            if (!String.IsNullOrWhiteSpace(reason) && !reasons.Contains(reason))
                reasons.Add(reason);
        }

        private void ApplyCollectionMetrics(WindowsGpuPollingSnapshot snapshot)
        {
            snapshot.CompletedCollectionCount = _completedCollectionCount;
            snapshot.SuccessfulMappingCollectionCount = _successfulMappingCollectionCount;
            snapshot.SuccessfulEngineLoadCollectionCount = _successfulEngineLoadCollectionCount;
            snapshot.SuccessfulDedicatedMemoryCollectionCount = _successfulDedicatedMemoryCollectionCount;
            snapshot.PartialMappingCollectionCount = _partialMappingCollectionCount;
            snapshot.UnavailableCollectionCount = _unavailableCollectionCount;
            snapshot.LastCollectionDurationMilliseconds = _lastCollectionDurationMilliseconds;
            snapshot.MaximumCollectionDurationMilliseconds = _maximumCollectionDurationMilliseconds;
            snapshot.SuppressedOverlapCount = Volatile.Read(ref _suppressedOverlapCount);
            snapshot.FailureReasonCounts = new Dictionary<string, int>(_failureReasonCounts, StringComparer.Ordinal);
        }

        private void RecordFailureReason(string reason)
        {
            if (String.IsNullOrWhiteSpace(reason))
                reason = "unknown-failure";
            int count;
            _failureReasonCounts.TryGetValue(reason, out count);
            _failureReasonCounts[reason] = count + 1;
        }

        public void Dispose()
        {
            Timer timer;
            lock (_sync)
            {
                timer = _timer;
                _timer = null;
            }
            if (timer != null)
            {
                using (ManualResetEvent stopped = new ManualResetEvent(false))
                {
                    if (timer.Dispose(stopped))
                        stopped.WaitOne(TimeSpan.FromSeconds(10));
                }
            }
        }
    }
}
