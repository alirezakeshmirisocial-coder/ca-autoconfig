using System;
using System.Collections.Generic;
using System.Threading;

namespace CA.SystemOverlay
{
    internal sealed class WindowsGpuPollingSnapshot
    {
        public string Status = "NOT_STARTED";
        public DateTime CapturedUtc;
        public int ConsecutiveStableSamples;
        public int SuppressedOverlapCount;
        public bool CanUseInHud;
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
                lock (_sync)
                {
                    Update(probe, capturedUtc);
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
                DateTime now = _clock().ToUniversalTime();
                if (copy.CapturedUtc != default(DateTime) && now >= copy.CapturedUtc && now - copy.CapturedUtc > _staleAfter)
                {
                    copy.Status = "STALE";
                    copy.ReasonCodes.Clear();
                    copy.ReasonCodes.Add("sample-stale");
                    copy.Adapters.Clear();
                    copy.CanUseInHud = false;
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
            if (!probe.MappingChecksPass || String.IsNullOrWhiteSpace(probe.InternalTopologyFingerprint))
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
            if (_stableSamples < _requiredStableSamples)
            {
                next.Status = "WARMING_UP";
                next.ReasonCodes.Add("stable-samples-insufficient");
                _latest = next;
                return;
            }

            next.Status = "READY_FOR_VALIDATION";
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
                CanUseInHud = false,
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

        public void Dispose()
        {
            Timer timer;
            lock (_sync)
            {
                timer = _timer;
                _timer = null;
            }
            if (timer != null)
                timer.Dispose();
        }
    }
}
