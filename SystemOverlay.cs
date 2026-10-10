using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace CA.SystemOverlay
{
    internal sealed class OverlaySettings
    {
        public string TargetDeviceName { get; set; }
        public bool HasCustomPosition { get; set; }
        public int PositionX { get; set; }
        public int PositionY { get; set; }
        public double Opacity { get; set; }
        public int HotkeyModifiers { get; set; }
        public int HotkeyKey { get; set; }

        public OverlaySettings()
        {
            TargetDeviceName = String.Empty;
            Opacity = 0.82;
            HotkeyModifiers = 3; // Alt + Control
            HotkeyKey = (int)Keys.L;
        }

        public OverlaySettings Clone()
        {
            return new OverlaySettings
            {
                TargetDeviceName = TargetDeviceName,
                HasCustomPosition = HasCustomPosition,
                PositionX = PositionX,
                PositionY = PositionY,
                Opacity = Opacity,
                HotkeyModifiers = HotkeyModifiers,
                HotkeyKey = HotkeyKey
            };
        }
    }

    internal sealed class SettingsStore
    {
        private readonly string _path;
        private readonly JavaScriptSerializer _serializer = new JavaScriptSerializer();

        public SettingsStore(string path)
        {
            _path = path;
        }

        public OverlaySettings Load(string fallbackTargetDeviceName, double fallbackOpacity)
        {
            OverlaySettings settings = null;
            try
            {
                if (File.Exists(_path))
                    settings = _serializer.Deserialize<OverlaySettings>(File.ReadAllText(_path));
            }
            catch
            {
                settings = null;
            }

            if (settings == null)
                settings = new OverlaySettings();
            if (String.IsNullOrWhiteSpace(settings.TargetDeviceName))
                settings.TargetDeviceName = fallbackTargetDeviceName ?? String.Empty;
            settings.Opacity = Math.Max(0.58, Math.Min(0.95, settings.Opacity <= 0 ? fallbackOpacity : settings.Opacity));
            if (settings.HotkeyKey <= 0)
                settings.HotkeyKey = (int)Keys.L;
            if ((settings.HotkeyModifiers & 0x000F) == 0)
                settings.HotkeyModifiers = 3;
            return settings;
        }

        public void Save(OverlaySettings settings)
        {
            string directory = Path.GetDirectoryName(_path);
            if (!String.IsNullOrEmpty(directory))
                Directory.CreateDirectory(directory);
            string temporary = _path + ".tmp";
            File.WriteAllText(temporary, _serializer.Serialize(settings), new UTF8Encoding(false));
            if (File.Exists(_path))
            {
                string backup = _path + ".bak";
                File.Replace(temporary, _path, backup, true);
                try { File.Delete(backup); }
                catch { }
            }
            else
            {
                File.Move(temporary, _path);
            }
        }
    }

    internal sealed class DriveMetric
    {
        public string Name;
        public int UsedPercent;
    }

    internal sealed class GpuMetric
    {
        public int Index;
        public string Uuid;
        public string Name;
        public int LoadPercent;
        public int MemoryControllerPercent;
        public int VramPercent;
        public double PowerDrawWatts;
        public double PowerLimitWatts;
        public double DefaultPowerLimitWatts;
        public double MinimumPowerLimitWatts;
        public double MaximumPowerLimitWatts;
        public double SuggestedPowerLimitWatts;
        public int TemperatureC;
        public int ClockMHz;
    }

    internal sealed class MetricSnapshot
    {
        public int CpuPercent = -1;
        public int RamPercent = -1;
        public List<DriveMetric> Drives = new List<DriveMetric>();
        public List<GpuMetric> Gpus = new List<GpuMetric>();
        public bool GpuLimitsHealthy;
        public string GpuLimitDetail = "CHECKING";
        public DateTime CapturedUtc = DateTime.UtcNow;
    }

    public static class PowerAdvisor
    {
        public static double CalculateStartingPoint(double minimumWatts, double currentLimitWatts, double defaultLimitWatts)
        {
            if (minimumWatts <= 0 || defaultLimitWatts <= 0 || minimumWatts > defaultLimitWatts)
                return -1;
            double candidate = Math.Round((defaultLimitWatts * 0.75) / 5.0, MidpointRounding.AwayFromZero) * 5.0;
            candidate = Math.Max(minimumWatts, Math.Min(defaultLimitWatts, candidate));
            if (currentLimitWatts >= minimumWatts && currentLimitWatts < defaultLimitWatts)
                candidate = Math.Min(candidate, currentLimitWatts);
            return candidate;
        }
    }

    internal sealed class MetricsProvider : IDisposable
    {
        private readonly string _nvidiaSmi;
        private readonly string _gpuStatePath;
        private readonly DateTime _bootUtc;
        private System.Threading.Timer _timer;
        private MetricSnapshot _latest = new MetricSnapshot();
        private int _collecting;
        private ulong _previousIdle;
        private ulong _previousTotal;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private sealed class MemoryStatusEx
        {
            public uint Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
            public uint MemoryLoad;
            public ulong TotalPhysical;
            public ulong AvailablePhysical;
            public ulong TotalPageFile;
            public ulong AvailablePageFile;
            public ulong TotalVirtual;
            public ulong AvailableVirtual;
            public ulong AvailableExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx status);

        public MetricsProvider(string nvidiaSmi, string gpuStatePath)
        {
            _nvidiaSmi = nvidiaSmi;
            _gpuStatePath = gpuStatePath;
            _bootUtc = ReadBootTimeUtc();
            PrimeCpuCounter();
        }

        public MetricSnapshot Latest
        {
            get { return _latest; }
        }

        public void Start(int intervalMilliseconds)
        {
            int interval = Math.Max(1000, intervalMilliseconds);
            _timer = new System.Threading.Timer(Collect, null, 0, interval);
        }

        private void Collect(object ignored)
        {
            if (Interlocked.Exchange(ref _collecting, 1) != 0)
                return;

            try
            {
                MetricSnapshot next = new MetricSnapshot();
                next.CpuPercent = ReadCpuPercent();
                next.RamPercent = ReadRamPercent();
                next.Drives = ReadDrives();
                ReadGpuMetrics(next);
                next.CapturedUtc = DateTime.UtcNow;
                _latest = next;
            }
            catch
            {
                MetricSnapshot failed = _latest;
                failed.GpuLimitsHealthy = false;
                failed.GpuLimitDetail = "METRICS UNAVAILABLE";
                _latest = failed;
            }
            finally
            {
                Interlocked.Exchange(ref _collecting, 0);
            }
        }

        private void PrimeCpuCounter()
        {
            FileTime idle;
            FileTime kernel;
            FileTime user;
            if (GetSystemTimes(out idle, out kernel, out user))
            {
                _previousIdle = ToUInt64(idle);
                _previousTotal = ToUInt64(kernel) + ToUInt64(user);
            }
        }

        private int ReadCpuPercent()
        {
            FileTime idle;
            FileTime kernel;
            FileTime user;
            if (!GetSystemTimes(out idle, out kernel, out user))
                return -1;

            ulong idleNow = ToUInt64(idle);
            ulong totalNow = ToUInt64(kernel) + ToUInt64(user);
            ulong idleDelta = idleNow - _previousIdle;
            ulong totalDelta = totalNow - _previousTotal;
            _previousIdle = idleNow;
            _previousTotal = totalNow;
            if (totalDelta == 0)
                return 0;
            double busy = 100.0 * (1.0 - ((double)idleDelta / totalDelta));
            return ClampPercent((int)Math.Round(busy));
        }

        private static int ReadRamPercent()
        {
            MemoryStatusEx status = new MemoryStatusEx();
            if (!GlobalMemoryStatusEx(status) || status.TotalPhysical == 0)
                return -1;
            double used = 1.0 - ((double)status.AvailablePhysical / status.TotalPhysical);
            return ClampPercent((int)Math.Round(used * 100.0));
        }

        private static List<DriveMetric> ReadDrives()
        {
            List<DriveMetric> result = new List<DriveMetric>();
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                try
                {
                    if (!drive.IsReady || drive.DriveType != DriveType.Fixed)
                        continue;
                    if (drive.TotalSize < 8L * 1024L * 1024L * 1024L)
                        continue;
                    int used = ClampPercent((int)Math.Round(100.0 * (1.0 - ((double)drive.AvailableFreeSpace / drive.TotalSize))));
                    result.Add(new DriveMetric { Name = drive.Name.TrimEnd('\\'), UsedPercent = used });
                }
                catch
                {
                    // A drive can disappear while Windows is enumerating it. Skip that sample.
                }
            }
            result.Sort(delegate(DriveMetric a, DriveMetric b) { return StringComparer.OrdinalIgnoreCase.Compare(a.Name, b.Name); });
            return result;
        }

        private void ReadGpuMetrics(MetricSnapshot snapshot)
        {
            if (!File.Exists(_nvidiaSmi))
            {
                snapshot.GpuLimitsHealthy = false;
                snapshot.GpuLimitDetail = "NVIDIA-SMI MISSING";
                return;
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = _nvidiaSmi;
            startInfo.Arguments = "--query-gpu=index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,temperature.gpu,clocks.gr --format=csv,noheader,nounits";
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            string output;
            using (Process process = Process.Start(startInfo))
            {
                if (!process.WaitForExit(2500))
                {
                    try { process.Kill(); }
                    catch { }
                    snapshot.GpuLimitsHealthy = false;
                    snapshot.GpuLimitDetail = "GPU QUERY TIMEOUT";
                    return;
                }
                output = process.StandardOutput.ReadToEnd();
                if (process.ExitCode != 0)
                {
                    snapshot.GpuLimitsHealthy = false;
                    snapshot.GpuLimitDetail = "GPU DATA UNAVAILABLE";
                    return;
                }
            }

            string[] lines = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string line in lines)
            {
                string[] parts = line.Split(',');
                if (parts.Length < 14)
                    continue;
                int index;
                double memoryUsed;
                double memoryTotal;
                double powerDraw;
                double powerLimit;
                double defaultPowerLimit;
                double minimumPowerLimit;
                double maximumPowerLimit;
                if (!Int32.TryParse(parts[0].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out index))
                    continue;
                if (!Double.TryParse(parts[5].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out memoryUsed))
                    memoryUsed = 0;
                if (!Double.TryParse(parts[6].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out memoryTotal))
                    memoryTotal = 0;
                if (!Double.TryParse(parts[7].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out powerDraw))
                    powerDraw = 0;
                if (!Double.TryParse(parts[8].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out powerLimit))
                    powerLimit = 0;
                if (!Double.TryParse(parts[9].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out defaultPowerLimit))
                    defaultPowerLimit = 0;
                if (!Double.TryParse(parts[10].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out minimumPowerLimit))
                    minimumPowerLimit = 0;
                if (!Double.TryParse(parts[11].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out maximumPowerLimit))
                    maximumPowerLimit = 0;

                GpuMetric gpu = new GpuMetric();
                gpu.Index = index;
                gpu.Uuid = parts[1].Trim();
                gpu.Name = ShortGpuName(parts[2].Trim());
                gpu.LoadPercent = ParsePercent(parts[3]);
                gpu.MemoryControllerPercent = ParsePercent(parts[4]);
                gpu.VramPercent = memoryTotal <= 0 ? 0 : ClampPercent((int)Math.Round(100.0 * memoryUsed / memoryTotal));
                gpu.PowerDrawWatts = powerDraw;
                gpu.PowerLimitWatts = powerLimit;
                gpu.DefaultPowerLimitWatts = defaultPowerLimit;
                gpu.MinimumPowerLimitWatts = minimumPowerLimit;
                gpu.MaximumPowerLimitWatts = maximumPowerLimit;
                gpu.SuggestedPowerLimitWatts = CalculateSafeStartingPoint(gpu);
                int temperatureC;
                gpu.TemperatureC = Int32.TryParse(parts[12].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out temperatureC) ? temperatureC : -1;
                int clockMHz;
                gpu.ClockMHz = Int32.TryParse(parts[13].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out clockMHz) ? clockMHz : -1;
                snapshot.Gpus.Add(gpu);
            }
            snapshot.Gpus.Sort(delegate(GpuMetric a, GpuMetric b) { return a.Index.CompareTo(b.Index); });

            VerifyAppliedLimits(snapshot);
        }

        private sealed class ExpectedGpuLimit
        {
            public int Index;
            public int MaxClockMHz;
            public double PowerLimitWatts;
        }

        private void VerifyAppliedLimits(MetricSnapshot snapshot)
        {
            string reason;
            List<ExpectedGpuLimit> expected;
            if (!TryReadAppliedLimits(out expected, out reason))
            {
                snapshot.GpuLimitsHealthy = false;
                snapshot.GpuLimitDetail = reason;
                return;
            }

            foreach (ExpectedGpuLimit target in expected)
            {
                GpuMetric actual = snapshot.Gpus.Find(delegate(GpuMetric gpu) { return gpu.Index == target.Index; });
                if (actual == null)
                {
                    snapshot.GpuLimitsHealthy = false;
                    snapshot.GpuLimitDetail = "PROFILE GPU IS MISSING";
                    return;
                }
                if (Math.Abs(actual.PowerLimitWatts - target.PowerLimitWatts) > 0.6)
                {
                    snapshot.GpuLimitsHealthy = false;
                    snapshot.GpuLimitDetail = "NOT APPLIED · POWER LIMIT";
                    return;
                }
                if (target.MaxClockMHz > 0 && (actual.ClockMHz < 0 || actual.ClockMHz > target.MaxClockMHz + 30))
                {
                    snapshot.GpuLimitsHealthy = false;
                    snapshot.GpuLimitDetail = "NOT APPLIED · CLOCK LIMIT";
                    return;
                }
            }

            snapshot.GpuLimitsHealthy = expected.Count > 0;
            if (expected.Count > 0 && AllTargetsMatch(expected))
            {
                snapshot.GpuLimitDetail = String.Format(
                    CultureInfo.InvariantCulture,
                    "ACTIVE · {0} MHz / {1:0} W",
                    expected[0].MaxClockMHz,
                    expected[0].PowerLimitWatts);
            }
            else
            {
                snapshot.GpuLimitDetail = "ACTIVE · PROFILE VERIFIED";
            }
        }

        private static bool AllTargetsMatch(List<ExpectedGpuLimit> targets)
        {
            if (targets.Count == 0)
                return false;
            ExpectedGpuLimit first = targets[0];
            foreach (ExpectedGpuLimit target in targets)
            {
                if (target.MaxClockMHz != first.MaxClockMHz || Math.Abs(target.PowerLimitWatts - first.PowerLimitWatts) > 0.5)
                    return false;
            }
            return true;
        }

        private bool TryReadAppliedLimits(out List<ExpectedGpuLimit> expected, out string reason)
        {
            expected = new List<ExpectedGpuLimit>();
            reason = "NOT APPLIED THIS BOOT";
            try
            {
                if (!File.Exists(_gpuStatePath))
                    return false;
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> state = serializer.DeserializeObject(File.ReadAllText(_gpuStatePath)) as Dictionary<string, object>;
                if (state == null || !state.ContainsKey("status") || !String.Equals(Convert.ToString(state["status"], CultureInfo.InvariantCulture), "applied", StringComparison.OrdinalIgnoreCase))
                {
                    reason = "LIMIT STATE IS NOT APPLIED";
                    return false;
                }
                string timestampValue = state.ContainsKey("timestampUtc") ? Convert.ToString(state["timestampUtc"], CultureInfo.InvariantCulture) : String.Empty;
                DateTime appliedUtc;
                if (!DateTime.TryParse(timestampValue, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out appliedUtc))
                {
                    reason = "LIMIT STATE INVALID";
                    return false;
                }
                appliedUtc = appliedUtc.ToUniversalTime();
                if (appliedUtc < _bootUtc.AddMinutes(-2))
                    return false;

                object resultsObject;
                object[] results = state.TryGetValue("results", out resultsObject) ? resultsObject as object[] : null;
                if (results == null || results.Length == 0)
                {
                    reason = "LIMIT PROFILE IS EMPTY";
                    return false;
                }
                foreach (object resultObject in results)
                {
                    Dictionary<string, object> result = resultObject as Dictionary<string, object>;
                    if (result == null)
                        continue;
                    int index = ReadInt(result, "index", -1);
                    int maxClock = ReadInt(result, "maxGraphicsClockMHz", -1);
                    double powerLimit = ReadDouble(result, "powerLimitWatts", -1);
                    if (index >= 0 && maxClock > 0 && powerLimit > 0)
                        expected.Add(new ExpectedGpuLimit { Index = index, MaxClockMHz = maxClock, PowerLimitWatts = powerLimit });
                }
                if (expected.Count == 0)
                {
                    reason = "LIMIT PROFILE IS INVALID";
                    return false;
                }
                return true;
            }
            catch
            {
                reason = "LIMIT STATE UNREADABLE";
                return false;
            }
        }

        private static int ReadInt(Dictionary<string, object> values, string key, int fallback)
        {
            object value;
            int parsed;
            return values.TryGetValue(key, out value) && Int32.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                ? parsed
                : fallback;
        }

        private static double ReadDouble(Dictionary<string, object> values, string key, double fallback)
        {
            object value;
            double parsed;
            return values.TryGetValue(key, out value) && Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed)
                ? parsed
                : fallback;
        }

        private static double CalculateSafeStartingPoint(GpuMetric gpu)
        {
            return PowerAdvisor.CalculateStartingPoint(gpu.MinimumPowerLimitWatts, gpu.PowerLimitWatts, gpu.DefaultPowerLimitWatts);
        }

        private static DateTime ReadBootTimeUtc()
        {
            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher("SELECT LastBootUpTime FROM Win32_OperatingSystem"))
                using (ManagementObjectCollection results = searcher.Get())
                {
                    foreach (ManagementObject item in results)
                    {
                        string value = Convert.ToString(item["LastBootUpTime"], CultureInfo.InvariantCulture);
                        if (!String.IsNullOrEmpty(value))
                            return ManagementDateTimeConverter.ToDateTime(value).ToUniversalTime();
                    }
                }
            }
            catch { }
            return DateTime.UtcNow.AddDays(-1);
        }

        private static string ShortGpuName(string name)
        {
            const string prefix = "NVIDIA GeForce ";
            if (name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                return name.Substring(prefix.Length);
            return name;
        }

        private static int ParsePercent(string value)
        {
            int parsed;
            return Int32.TryParse(value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                ? ClampPercent(parsed)
                : 0;
        }

        private static int ClampPercent(int value)
        {
            return Math.Max(0, Math.Min(100, value));
        }

        private static ulong ToUInt64(FileTime value)
        {
            return ((ulong)value.High << 32) | value.Low;
        }

        public void Dispose()
        {
            if (_timer != null)
                _timer.Dispose();
        }
    }

    internal sealed class MonitorMapControl : Control
    {
        private readonly Screen[] _screens;
        private float _uiScale;
        private readonly Dictionary<string, Rectangle> _hitAreas = new Dictionary<string, Rectangle>(StringComparer.OrdinalIgnoreCase);
        private string _selectedDeviceName;

        public event EventHandler SelectedMonitorChanged;

        public MonitorMapControl(string selectedDeviceName)
            : this(selectedDeviceName, 1.0f)
        {
        }

        public MonitorMapControl(string selectedDeviceName, float uiScale)
        {
            _screens = Screen.AllScreens;
            _uiScale = Math.Max(1.0f, uiScale);
            _selectedDeviceName = selectedDeviceName ?? String.Empty;
            DoubleBuffered = true;
            TabStop = true;
            AccessibleName = "Monitor selection map";
            AccessibleRole = AccessibleRole.List;
            BackColor = Color.FromArgb(14, 17, 22);
            ForeColor = Color.FromArgb(235, 240, 246);
            Cursor = Cursors.Hand;
        }

        public void ApplyUiScale(float scale)
        {
            _uiScale = Math.Max(1.0f, scale);
            Invalidate();
        }

        public string SelectedDeviceName
        {
            get { return _selectedDeviceName; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            _hitAreas.Clear();
            if (_screens.Length == 0)
                return;

            Rectangle virtualBounds = _screens[0].Bounds;
            foreach (Screen screen in _screens)
                virtualBounds = Rectangle.Union(virtualBounds, screen.Bounds);

            int padding = S(22);
            float usableWidth = Math.Max(1, ClientSize.Width - padding * 2);
            float usableHeight = Math.Max(1, ClientSize.Height - padding * 2);
            float scale = Math.Min(usableWidth / Math.Max(1, virtualBounds.Width), usableHeight / Math.Max(1, virtualBounds.Height));
            float mapWidth = virtualBounds.Width * scale;
            float mapHeight = virtualBounds.Height * scale;
            float originX = (ClientSize.Width - mapWidth) / 2.0f;
            float originY = (ClientSize.Height - mapHeight) / 2.0f;

            using (Font nameFont = new Font("Segoe UI Semibold", 8.25f, FontStyle.Bold, GraphicsUnit.Point))
            using (Font detailFont = new Font("Segoe UI", 6.75f, FontStyle.Regular, GraphicsUnit.Point))
            {
                foreach (Screen screen in _screens)
                {
                    Rectangle rect = new Rectangle(
                        (int)Math.Round(originX + (screen.Bounds.Left - virtualBounds.Left) * scale),
                        (int)Math.Round(originY + (screen.Bounds.Top - virtualBounds.Top) * scale),
                        Math.Max(S(56), (int)Math.Round(screen.Bounds.Width * scale)),
                        Math.Max(S(38), (int)Math.Round(screen.Bounds.Height * scale)));
                    _hitAreas[screen.DeviceName] = rect;
                    bool selected = String.Equals(screen.DeviceName, _selectedDeviceName, StringComparison.OrdinalIgnoreCase);
                    Color fill = selected ? Color.FromArgb(30, 76, 99) : Color.FromArgb(31, 36, 45);
                    Color border = selected ? Color.FromArgb(100, 184, 224) : Color.FromArgb(76, 86, 101);
                    using (SolidBrush fillBrush = new SolidBrush(fill))
                    using (Pen borderPen = new Pen(border, selected ? Math.Max(2.0f, _uiScale) : Math.Max(1.0f, _uiScale * 0.75f)))
                    {
                        e.Graphics.FillRectangle(fillBrush, rect);
                        e.Graphics.DrawRectangle(borderPen, rect);
                    }

                    string name = FriendlyDisplayName(screen.DeviceName);
                    string detail = String.Format(CultureInfo.InvariantCulture, "{0} × {1}{2}", screen.Bounds.Width, screen.Bounds.Height, screen.Primary ? "  PRIMARY" : String.Empty);
                    TextRenderer.DrawText(e.Graphics, name, nameFont, new Rectangle(rect.X + S(8), rect.Y + S(7), rect.Width - S(16), S(16)), ForeColor, TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
                    if (rect.Height >= S(48))
                        TextRenderer.DrawText(e.Graphics, detail, detailFont, new Rectangle(rect.X + S(8), rect.Y + S(24), rect.Width - S(16), S(16)), Color.FromArgb(166, 177, 190), TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
                }
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            foreach (KeyValuePair<string, Rectangle> item in _hitAreas)
            {
                if (!item.Value.Contains(e.Location))
                    continue;
                if (!String.Equals(_selectedDeviceName, item.Key, StringComparison.OrdinalIgnoreCase))
                {
                    _selectedDeviceName = item.Key;
                    Invalidate();
                    if (SelectedMonitorChanged != null)
                        SelectedMonitorChanged(this, EventArgs.Empty);
                }
                break;
            }
        }

        public static string FriendlyDisplayName(string deviceName)
        {
            if (String.IsNullOrWhiteSpace(deviceName))
                return "DISPLAY";
            return deviceName.Replace("\\\\.\\", String.Empty).ToUpperInvariant();
        }

        private int S(int value)
        {
            return Math.Max(1, (int)Math.Round(value * _uiScale));
        }
    }

    internal sealed class HotkeyCaptureBox : TextBox
    {
        public int HotkeyModifiers { get; private set; }
        public int HotkeyKey { get; private set; }

        [DllImport("user32.dll")]
        private static extern short GetKeyState(int virtualKey);

        public HotkeyCaptureBox(int modifiers, int key)
        {
            ReadOnly = true;
            ShortcutsEnabled = false;
            BackColor = Color.FromArgb(31, 36, 45);
            ForeColor = Color.FromArgb(235, 240, 246);
            BorderStyle = BorderStyle.FixedSingle;
            Font = new Font("Segoe UI", 10.0f, FontStyle.Regular, GraphicsUnit.Point);
            HotkeyModifiers = modifiers;
            HotkeyKey = key;
            UpdateText();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            e.SuppressKeyPress = true;
            e.Handled = true;
            if (e.KeyCode == Keys.Back || e.KeyCode == Keys.Delete)
            {
                HotkeyModifiers = 0;
                HotkeyKey = 0;
                UpdateText();
                return;
            }
            if (e.KeyCode == Keys.ControlKey || e.KeyCode == Keys.ShiftKey || e.KeyCode == Keys.Menu || e.KeyCode == Keys.LWin || e.KeyCode == Keys.RWin)
                return;

            int modifiers = 0;
            if (e.Control) modifiers |= 2;
            if (e.Alt) modifiers |= 1;
            if (e.Shift) modifiers |= 4;
            if ((GetKeyState(0x5B) & 0x8000) != 0 || (GetKeyState(0x5C) & 0x8000) != 0) modifiers |= 8;
            if (modifiers == 0)
                return;

            HotkeyModifiers = modifiers;
            HotkeyKey = (int)e.KeyCode;
            UpdateText();
        }

        private void UpdateText()
        {
            Text = FormatHotkey(HotkeyModifiers, HotkeyKey);
            SelectionStart = Text.Length;
        }

        public static string FormatHotkey(int modifiers, int key)
        {
            if (modifiers == 0 || key == 0)
                return "Press a shortcut";
            List<string> parts = new List<string>();
            if ((modifiers & 2) != 0) parts.Add("Ctrl");
            if ((modifiers & 1) != 0) parts.Add("Alt");
            if ((modifiers & 4) != 0) parts.Add("Shift");
            if ((modifiers & 8) != 0) parts.Add("Win");
            parts.Add(((Keys)key).ToString());
            return String.Join(" + ", parts.ToArray());
        }
    }

    internal sealed class SettingsForm : Form
    {
        private readonly OverlaySettings _working;
        private readonly MetricsProvider _metrics;
        private readonly MonitorMapControl _monitorMap;
        private readonly HotkeyCaptureBox _hotkey;
        private readonly NumericUpDown _opacity;
        private readonly Label _selectionSummary;
        private readonly Label _advisor;
        private readonly System.Windows.Forms.Timer _refreshTimer;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativePoint
        {
            public int X;
            public int Y;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);

        [DllImport("shcore.dll")]
        private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

        public OverlaySettings ResultSettings
        {
            get { return _working.Clone(); }
        }

        public SettingsForm(OverlaySettings settings, MetricsProvider metrics, string hotkeyStatus)
        {
            _working = settings.Clone();
            _metrics = metrics;
            Text = "CA HUD settings";
            ClientSize = new Size(700, 680);
            StartPosition = FormStartPosition.Manual;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            BackColor = Color.FromArgb(18, 21, 27);
            ForeColor = Color.FromArgb(235, 240, 246);
            Font = new Font("Segoe UI", 9.0f, FontStyle.Regular, GraphicsUnit.Point);
            AutoScaleMode = AutoScaleMode.None;

            Label title = NewLabel("HUD placement and controls", 24, 20, 640, 34, 18.0f, FontStyle.Bold, ForeColor);
            Controls.Add(title);
            Controls.Add(NewLabel("Choose a display, then unlock and drag the HUD for precise placement.", 26, 55, 630, 22, 9.5f, FontStyle.Regular, Color.FromArgb(166, 177, 190)));

            Controls.Add(NewLabel("DISPLAY", 26, 92, 120, 18, 8.5f, FontStyle.Bold, Color.FromArgb(154, 166, 181)));
            _monitorMap = new MonitorMapControl(_working.TargetDeviceName);
            _monitorMap.Location = new Point(26, 115);
            _monitorMap.Size = new Size(648, 178);
            _monitorMap.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            _monitorMap.SelectedMonitorChanged += MonitorSelectionChanged;
            Controls.Add(_monitorMap);

            _selectionSummary = NewLabel(SelectedMonitorSummary(), 26, 301, 420, 22, 9.0f, FontStyle.Regular, Color.FromArgb(196, 205, 216));
            Controls.Add(_selectionSummary);
            Button resetPosition = NewButton("Reset to lower-left", 510, 297, 164, 30, false);
            resetPosition.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            resetPosition.Click += delegate { _working.HasCustomPosition = false; _selectionSummary.Text = SelectedMonitorSummary() + " · default position"; };
            Controls.Add(resetPosition);

            AddRule(26, 342, 648);
            Controls.Add(NewLabel("LOCK SHORTCUT", 26, 361, 180, 18, 8.5f, FontStyle.Bold, Color.FromArgb(154, 166, 181)));
            _hotkey = new HotkeyCaptureBox(_working.HotkeyModifiers, _working.HotkeyKey);
            _hotkey.Location = new Point(214, 356);
            _hotkey.Size = new Size(230, 28);
            Controls.Add(_hotkey);
            Controls.Add(NewLabel("Unlocks the HUD for dragging; press it again to restore click-through mode.", 214, 389, 460, 20, 8.5f, FontStyle.Regular, Color.FromArgb(132, 145, 162)));
            if (!String.IsNullOrWhiteSpace(hotkeyStatus))
                Controls.Add(NewLabel(hotkeyStatus, 214, 409, 460, 20, 8.5f, FontStyle.Regular, Color.FromArgb(242, 91, 91)));

            Controls.Add(NewLabel("OPACITY", 26, 426, 180, 18, 8.5f, FontStyle.Bold, Color.FromArgb(154, 166, 181)));
            _opacity = new NumericUpDown();
            _opacity.Location = new Point(214, 421);
            _opacity.Size = new Size(92, 28);
            _opacity.Minimum = 58;
            _opacity.Maximum = 95;
            _opacity.Value = (decimal)Math.Round(_working.Opacity * 100.0);
            _opacity.BackColor = Color.FromArgb(31, 36, 45);
            _opacity.ForeColor = ForeColor;
            _opacity.BorderStyle = BorderStyle.FixedSingle;
            _opacity.TextAlign = HorizontalAlignment.Right;
            Controls.Add(_opacity);
            Controls.Add(NewLabel("%", 312, 425, 24, 20, 9.0f, FontStyle.Regular, Color.FromArgb(166, 177, 190)));

            AddRule(26, 468, 648);
            Controls.Add(NewLabel("READ-ONLY POWER ADVISOR", 26, 486, 260, 18, 8.5f, FontStyle.Bold, Color.FromArgb(154, 166, 181)));
            _advisor = NewLabel(BuildPowerAdvisor(_metrics.Latest), 26, 511, 648, 66, 9.0f, FontStyle.Regular, Color.FromArgb(214, 221, 230));
            _advisor.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(_advisor);
            Controls.Add(NewLabel("Starting points stay inside NVIDIA's reported range and never exceed the default. Benchmark your real AI workload before applying a change.", 26, 585, 480, 34, 8.2f, FontStyle.Regular, Color.FromArgb(132, 145, 162)));

            Button cancel = NewButton("Cancel", 500, 628, 82, 34, false);
            cancel.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
            cancel.DialogResult = DialogResult.Cancel;
            Controls.Add(cancel);
            Button save = NewButton("Save", 590, 628, 84, 34, true);
            save.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
            save.Click += SaveClicked;
            Controls.Add(save);
            AcceptButton = save;
            CancelButton = cancel;

            _refreshTimer = new System.Windows.Forms.Timer();
            _refreshTimer.Interval = 2000;
            _refreshTimer.Tick += delegate { _advisor.Text = BuildPowerAdvisor(_metrics.Latest); };
            _refreshTimer.Start();
            ApplyDisplayScale();
        }

        private void MonitorSelectionChanged(object sender, EventArgs e)
        {
            if (!String.Equals(_working.TargetDeviceName, _monitorMap.SelectedDeviceName, StringComparison.OrdinalIgnoreCase))
            {
                _working.TargetDeviceName = _monitorMap.SelectedDeviceName;
                _working.HasCustomPosition = false;
            }
            _selectionSummary.Text = SelectedMonitorSummary() + " · default position";
        }

        private string SelectedMonitorSummary()
        {
            foreach (Screen screen in Screen.AllScreens)
            {
                if (String.Equals(screen.DeviceName, _monitorMap == null ? _working.TargetDeviceName : _monitorMap.SelectedDeviceName, StringComparison.OrdinalIgnoreCase))
                    return String.Format(CultureInfo.InvariantCulture, "{0} · {1} × {2}{3}", MonitorMapControl.FriendlyDisplayName(screen.DeviceName), screen.Bounds.Width, screen.Bounds.Height, screen.Primary ? " · primary" : String.Empty);
            }
            return "Selected display is currently disconnected";
        }

        private void SaveClicked(object sender, EventArgs e)
        {
            if (_hotkey.HotkeyModifiers == 0 || _hotkey.HotkeyKey == 0)
            {
                MessageBox.Show(this, "Press a shortcut containing Ctrl, Alt, Shift, or Win.", "Shortcut required", MessageBoxButtons.OK, MessageBoxIcon.Information);
                _hotkey.Focus();
                return;
            }
            _working.TargetDeviceName = _monitorMap.SelectedDeviceName;
            _working.Opacity = (double)_opacity.Value / 100.0;
            _working.HotkeyModifiers = _hotkey.HotkeyModifiers;
            _working.HotkeyKey = _hotkey.HotkeyKey;
            DialogResult = DialogResult.OK;
            Close();
        }

        private static string BuildPowerAdvisor(MetricSnapshot snapshot)
        {
            if (snapshot == null || snapshot.Gpus.Count == 0)
                return "Collecting GPU power data. Reopen settings in a few seconds.";
            List<string> lines = new List<string>();
            foreach (GpuMetric gpu in snapshot.Gpus)
            {
                string suggestion = gpu.SuggestedPowerLimitWatts > 0
                    ? String.Format(CultureInfo.InvariantCulture, "starting point {0:0} W", gpu.SuggestedPowerLimitWatts)
                    : "range unavailable";
                lines.Add(String.Format(
                    CultureInfo.InvariantCulture,
                    "GPU {0} · {1} — {2:0} W now / {3:0} W cap / {4:0} W default · {5}",
                    gpu.Index,
                    gpu.Name,
                    gpu.PowerDrawWatts,
                    gpu.PowerLimitWatts,
                    gpu.DefaultPowerLimitWatts,
                    suggestion));
            }
            return String.Join(Environment.NewLine, lines.ToArray());
        }

        private Label NewLabel(string text, int x, int y, int width, int height, float size, FontStyle style, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Location = new Point(x, y);
            label.Size = new Size(width, height);
            label.Font = new Font("Segoe UI", size, style, GraphicsUnit.Point);
            label.ForeColor = color;
            label.BackColor = Color.Transparent;
            return label;
        }

        private Button NewButton(string text, int x, int y, int width, int height, bool primary)
        {
            Button button = new Button();
            button.Text = text;
            button.Location = new Point(x, y);
            button.Size = new Size(width, height);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.BorderColor = Color.FromArgb(76, 86, 101);
            button.BackColor = primary ? Color.FromArgb(73, 145, 181) : Color.FromArgb(31, 36, 45);
            button.ForeColor = Color.White;
            button.Font = new Font("Segoe UI Semibold", 9.0f, FontStyle.Bold, GraphicsUnit.Point);
            button.Cursor = Cursors.Hand;
            return button;
        }

        private void AddRule(int x, int y, int width)
        {
            Panel line = new Panel();
            line.Location = new Point(x, y);
            line.Size = new Size(width, 1);
            line.BackColor = Color.FromArgb(46, 53, 64);
            line.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(line);
        }

        private void ApplyDisplayScale()
        {
            Screen target = null;
            foreach (Screen screen in Screen.AllScreens)
            {
                if (String.Equals(screen.DeviceName, _working.TargetDeviceName, StringComparison.OrdinalIgnoreCase))
                {
                    target = screen;
                    break;
                }
            }
            if (target == null)
                target = Screen.PrimaryScreen;
            if (target == null)
                return;

            float scale = 1.0f;
            try
            {
                NativePoint point = new NativePoint { X = target.Bounds.Left + 1, Y = target.Bounds.Top + 1 };
                IntPtr monitor = MonitorFromPoint(point, 2);
                uint dpiX;
                uint dpiY;
                if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out dpiX, out dpiY) == 0 && dpiX >= 96)
                    scale = Math.Max(1.0f, Math.Min(3.0f, dpiX / 96.0f));
            }
            catch { }

            float fit = Math.Min((target.WorkingArea.Width - 60.0f) / 700.0f, (target.WorkingArea.Height - 60.0f) / 680.0f);
            scale = Math.Max(1.0f, Math.Min(scale, fit));
            if (scale > 1.01f)
            {
                _monitorMap.ApplyUiScale(scale);
                foreach (Control control in Controls)
                    ResetAnchors(control);
                ClientSize = new Size((int)Math.Round(700 * scale), (int)Math.Round(680 * scale));
                foreach (Control control in Controls)
                    ScaleControlBounds(control, scale);
            }
            Location = new Point(
                target.WorkingArea.Left + Math.Max(0, (target.WorkingArea.Width - Width) / 2),
                target.WorkingArea.Top + Math.Max(0, (target.WorkingArea.Height - Height) / 2));
        }

        private static void ScaleControlBounds(Control control, float scale)
        {
            control.Location = new Point((int)Math.Round(control.Left * scale), (int)Math.Round(control.Top * scale));
            control.Size = new Size((int)Math.Round(control.Width * scale), (int)Math.Round(control.Height * scale));
            if (control.Font != null)
            {
                float fontScale = Math.Min(1.35f, 1.0f + ((scale - 1.0f) * 0.30f));
                control.Font = new Font(control.Font.FontFamily, control.Font.Size * fontScale, control.Font.Style, control.Font.Unit);
            }
            foreach (Control child in control.Controls)
            {
                child.Location = new Point((int)Math.Round(child.Left * scale), (int)Math.Round(child.Top * scale));
                child.Size = new Size((int)Math.Round(child.Width * scale), (int)Math.Round(child.Height * scale));
            }
        }

        private static void ResetAnchors(Control control)
        {
            control.Anchor = AnchorStyles.Top | AnchorStyles.Left;
            foreach (Control child in control.Controls)
                ResetAnchors(child);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _refreshTimer != null)
                _refreshTimer.Dispose();
            base.Dispose(disposing);
        }
    }

    internal sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        private const int WmHotkey = 0x0312;
        private const int HotkeyId = 0x4341;
        private const int ModNoRepeat = 0x4000;
        private int _modifiers;
        private int _key;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr window, int id, int modifiers, int virtualKey);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr window, int id);

        public event EventHandler Triggered;

        public HotkeyWindow()
        {
            CreateHandle(new CreateParams());
        }

        public bool TryConfigure(int modifiers, int key)
        {
            int previousModifiers = _modifiers;
            int previousKey = _key;
            if (_key != 0)
                UnregisterHotKey(Handle, HotkeyId);
            if (RegisterHotKey(Handle, HotkeyId, modifiers | ModNoRepeat, key))
            {
                _modifiers = modifiers;
                _key = key;
                return true;
            }
            if (previousKey != 0)
                RegisterHotKey(Handle, HotkeyId, previousModifiers | ModNoRepeat, previousKey);
            _modifiers = previousModifiers;
            _key = previousKey;
            return false;
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmHotkey && message.WParam.ToInt32() == HotkeyId && Triggered != null)
                Triggered(this, EventArgs.Empty);
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            if (_key != 0)
                UnregisterHotKey(Handle, HotkeyId);
            DestroyHandle();
        }
    }

    internal sealed class OverlayForm : Form
    {
        private const int LogicalWidth = 324;
        private const int LogicalHeight = 332;
        private const int WsExToolWindow = 0x80;
        private const int WsExLayered = 0x80000;
        private const int WsExNoActivate = 0x08000000;
        private const int WmNcHitTest = 0x0084;
        private const int WmMouseActivate = 0x0021;
        private const int HtTransparent = -1;
        private const int HtClient = 1;
        private const int MaNoActivate = 3;

        private readonly MetricsProvider _metrics;
        private readonly Screen _screen;
        private readonly OverlaySettings _settings;
        private readonly float _scale;
        private readonly System.Windows.Forms.Timer _paintTimer;
        private readonly Font _titleFont = new Font("Segoe UI Semibold", 12.0f, FontStyle.Bold, GraphicsUnit.Pixel);
        private readonly Font _statusFont = new Font("Segoe UI", 10.0f, FontStyle.Regular, GraphicsUnit.Pixel);
        private readonly Font _sectionFont = new Font("Segoe UI Semibold", 10.0f, FontStyle.Bold, GraphicsUnit.Pixel);
        private readonly Font _bodyFont = new Font("Segoe UI", 11.0f, FontStyle.Regular, GraphicsUnit.Pixel);
        private readonly Font _metricFont = new Font("Segoe UI Semibold", 11.0f, FontStyle.Bold, GraphicsUnit.Pixel);
        private readonly Font _smallFont = new Font("Segoe UI", 9.0f, FontStyle.Regular, GraphicsUnit.Pixel);
        private readonly Color _surface = Color.FromArgb(18, 21, 27);
        private readonly Color _text = Color.FromArgb(235, 240, 246);
        private readonly Color _muted = Color.FromArgb(154, 166, 181);
        private readonly Color _quiet = Color.FromArgb(132, 145, 162);
        private readonly Color _rule = Color.FromArgb(46, 53, 64);
        private readonly Color _track = Color.FromArgb(40, 47, 58);
        private readonly Color _accent = Color.FromArgb(100, 184, 224);
        private readonly Color _healthy = Color.FromArgb(73, 204, 137);
        private readonly Color _danger = Color.FromArgb(242, 91, 91);
        private readonly Color _warning = Color.FromArgb(232, 175, 82);
        private bool _locked = true;
        private bool _dragging;
        private Point _dragPointerOrigin;
        private Point _dragWindowOrigin;

        public event EventHandler SettingsRequested;
        public event EventHandler PositionCommitted;
        public event EventHandler LockStateChanged;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativePoint
        {
            public int X;
            public int Y;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);

        [DllImport("shcore.dll")]
        private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

        public OverlayForm(Screen screen, MetricsProvider metrics, OverlaySettings settings)
        {
            _screen = screen;
            _metrics = metrics;
            _settings = settings;
            _scale = ReadScale(screen);
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.Manual;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            ControlBox = false;
            BackColor = _surface;
            ClientSize = new Size(Scale(LogicalWidth), Scale(LogicalHeight));
            Opacity = Math.Max(0.58, Math.Min(0.95, settings.Opacity));
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            AccessibleName = "CA hardware status";
            AccessibleRole = AccessibleRole.StaticText;
            PositionOnScreen();
            ApplyRoundedRegion();

            _paintTimer = new System.Windows.Forms.Timer();
            _paintTimer.Interval = 1000;
            _paintTimer.Tick += delegate { Invalidate(); };
            _paintTimer.Start();
        }

        public bool IsLocked
        {
            get { return _locked; }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams parameters = base.CreateParams;
                parameters.ExStyle |= WsExToolWindow | WsExLayered | WsExNoActivate;
                return parameters;
            }
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmMouseActivate)
            {
                message.Result = new IntPtr(MaNoActivate);
                return;
            }
            if (message.Msg == WmNcHitTest && _locked)
            {
                long value = message.LParam.ToInt64();
                Point screenPoint = new Point(unchecked((short)(value & 0xFFFF)), unchecked((short)((value >> 16) & 0xFFFF)));
                Point clientPoint = PointToClient(screenPoint);
                message.Result = new IntPtr(LockBoundsPhysical().Contains(clientPoint) ? HtClient : HtTransparent);
                return;
            }
            base.WndProc(ref message);
        }

        public void ToggleLock()
        {
            _locked = !_locked;
            Cursor = _locked ? Cursors.Default : Cursors.SizeAll;
            Invalidate();
            if (LockStateChanged != null)
                LockStateChanged(this, EventArgs.Empty);
        }

        public void PositionOnScreen()
        {
            Rectangle area = _screen.WorkingArea;
            int margin = Scale(14);
            int x = _settings.HasCustomPosition ? area.Left + _settings.PositionX : area.Left + margin;
            int y = _settings.HasCustomPosition ? area.Top + _settings.PositionY : area.Bottom - Height - margin;
            x = Math.Max(area.Left, Math.Min(area.Right - Width, x));
            y = Math.Max(area.Top, Math.Min(area.Bottom - Height, y));
            Location = new Point(x, y);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left && LockBoundsPhysical().Contains(e.Location))
            {
                ToggleLock();
                return;
            }
            if (!_locked && e.Button == MouseButtons.Right)
            {
                if (SettingsRequested != null)
                    SettingsRequested(this, EventArgs.Empty);
                return;
            }
            if (!_locked && e.Button == MouseButtons.Left)
            {
                _dragging = true;
                _dragPointerOrigin = Cursor.Position;
                _dragWindowOrigin = Location;
                Capture = true;
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!_locked)
                Cursor = LockBoundsPhysical().Contains(e.Location) ? Cursors.Hand : Cursors.SizeAll;
            if (!_dragging)
                return;
            Point pointer = Cursor.Position;
            Rectangle area = _screen.WorkingArea;
            int x = _dragWindowOrigin.X + pointer.X - _dragPointerOrigin.X;
            int y = _dragWindowOrigin.Y + pointer.Y - _dragPointerOrigin.Y;
            x = Math.Max(area.Left, Math.Min(area.Right - Width, x));
            y = Math.Max(area.Top, Math.Min(area.Bottom - Height, y));
            Location = new Point(x, y);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (!_dragging)
                return;
            _dragging = false;
            Capture = false;
            Rectangle area = _screen.WorkingArea;
            _settings.HasCustomPosition = true;
            _settings.PositionX = Left - area.Left;
            _settings.PositionY = Top - area.Top;
            if (PositionCommitted != null)
                PositionCommitted(this, EventArgs.Empty);
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            base.OnMouseDoubleClick(e);
            if (!_locked && SettingsRequested != null)
                SettingsRequested(this, EventArgs.Empty);
        }

        private Rectangle LockBoundsPhysical()
        {
            return new Rectangle(Scale(268), Scale(10), Scale(40), Scale(22));
        }

        private void ApplyRoundedRegion()
        {
            using (GraphicsPath path = RoundedRectangle(new Rectangle(0, 0, Width, Height), Scale(14)))
                Region = new Region(path);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.ScaleTransform(_scale, _scale);
            DrawOverlay(e.Graphics);
        }

        private void DrawOverlay(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            MetricSnapshot snapshot = _metrics.Latest;
            AccessibleDescription = BuildAccessibleSummary(snapshot) + (_locked ? " HUD locked." : " HUD unlocked for editing.");

            using (SolidBrush surface = new SolidBrush(_surface))
                g.FillRectangle(surface, new Rectangle(0, 0, LogicalWidth, LogicalHeight));

            Color stateColor = snapshot.GpuLimitsHealthy ? _healthy : _danger;
            using (SolidBrush statusBrush = new SolidBrush(stateColor))
                g.FillEllipse(statusBrush, 16, 15, 10, 10);
            DrawText(g, "GPU LIMITS", _titleFont, _text, 34, 9);
            DrawText(g, snapshot.GpuLimitDetail, _statusFont, stateColor, 34, 24);
            DrawLockControl(g);
            DrawRule(g, 43);

            int y = 54;
            DrawCpuIcon(g, new Rectangle(16, y + 2, 14, 14), _muted);
            DrawMetricRow(g, "CPU", snapshot.CpuPercent, y, _accent);
            y += 31;
            DrawRamIcon(g, new Rectangle(16, y + 2, 14, 14), _muted);
            DrawMetricRow(g, "RAM", snapshot.RamPercent, y, MetricColor(snapshot.RamPercent));
            y += 34;

            DrawDiskIcon(g, new Rectangle(16, y + 1, 14, 14), _muted);
            DrawText(g, "STORAGE", _sectionFont, _muted, 39, y);
            y += 20;
            int driveCount = Math.Min(3, snapshot.Drives.Count);
            if (driveCount == 0)
            {
                DrawText(g, "Collecting drive data", _smallFont, _quiet, 39, y);
                y += 23;
            }
            else
            {
                for (int i = 0; i < driveCount; i++)
                {
                    DriveMetric drive = snapshot.Drives[i];
                    DrawCompactMetric(g, drive.Name, drive.UsedPercent, y, MetricColor(drive.UsedPercent));
                    y += 23;
                }
            }

            y += 2;
            DrawRule(g, y);
            y += 9;
            int gpuCount = Math.Min(2, snapshot.Gpus.Count);
            if (gpuCount == 0)
            {
                DrawGpuIcon(g, new Rectangle(16, y + 1, 16, 13), _muted);
                DrawText(g, "Waiting for NVIDIA metrics", _bodyFont, _muted, 41, y);
            }
            else
            {
                for (int i = 0; i < gpuCount; i++)
                {
                    DrawGpuRow(g, snapshot.Gpus[i], y);
                    y += 43;
                }
            }

            string footer = _locked ? "2s live  ·  click-through" : "EDIT MODE  ·  drag  ·  right-click settings";
            DrawText(g, footer, _smallFont, _locked ? _quiet : _accent, 16, LogicalHeight - 18);
        }

        private void DrawLockControl(Graphics g)
        {
            Rectangle bounds = new Rectangle(268, 10, 40, 22);
            Color fill = _locked ? Color.FromArgb(31, 36, 45) : Color.FromArgb(38, 86, 108);
            Color border = _locked ? Color.FromArgb(76, 86, 101) : _accent;
            using (GraphicsPath path = RoundedRectangle(bounds, 11))
            using (SolidBrush fillBrush = new SolidBrush(fill))
            using (Pen borderPen = new Pen(border, 1.0f))
            {
                g.FillPath(fillBrush, path);
                g.DrawPath(borderPen, path);
            }
            Rectangle body = new Rectangle(284, 19, 8, 7);
            using (Pen iconPen = new Pen(_locked ? _muted : _text, 1.25f))
            {
                g.DrawRectangle(iconPen, body);
                if (_locked)
                    g.DrawArc(iconPen, 284, 14, 8, 10, 180, 180);
                else
                    g.DrawArc(iconPen, 288, 14, 8, 10, 180, 180);
            }
        }

        private void DrawMetricRow(Graphics g, string label, int value, int y, Color color)
        {
            DrawText(g, label, _bodyFont, _text, 40, y);
            DrawRightText(g, FormatPercent(value), _metricFont, _text, 307, y);
            DrawBar(g, new Rectangle(40, y + 20, 267, 4), value, color);
        }

        private void DrawCompactMetric(Graphics g, string label, int value, int y, Color color)
        {
            DrawText(g, label, _bodyFont, _text, 40, y);
            DrawBar(g, new Rectangle(79, y + 7, 184, 4), value, color);
            DrawRightText(g, FormatPercent(value), _metricFont, _text, 307, y - 1);
        }

        private void DrawGpuRow(Graphics g, GpuMetric gpu, int y)
        {
            DrawGpuIcon(g, new Rectangle(16, y + 2, 16, 13), _muted);
            DrawText(g, String.Format(CultureInfo.InvariantCulture, "GPU {0}  ·  {1}", gpu.Index, gpu.Name), _bodyFont, _text, 41, y);
            string values = String.Format(CultureInfo.InvariantCulture, "CUDA/SM {0}%  ·  VRAM {1}%  ·  {2:0}/{3:0} W  ·  {4}°", gpu.LoadPercent, gpu.VramPercent, gpu.PowerDrawWatts, gpu.PowerLimitWatts, gpu.TemperatureC);
            DrawText(g, values, _smallFont, _muted, 41, y + 17);
            DrawBar(g, new Rectangle(41, y + 34, 266, 4), gpu.LoadPercent, _accent);
        }

        private void DrawBar(Graphics g, Rectangle bounds, int value, Color color)
        {
            using (GraphicsPath trackPath = RoundedRectangle(bounds, 2))
            using (SolidBrush trackBrush = new SolidBrush(_track))
                g.FillPath(trackBrush, trackPath);
            int safeValue = Math.Max(0, Math.Min(100, value));
            if (safeValue <= 0)
                return;
            Rectangle fill = new Rectangle(bounds.X, bounds.Y, Math.Max(3, bounds.Width * safeValue / 100), bounds.Height);
            using (GraphicsPath fillPath = RoundedRectangle(fill, 2))
            using (SolidBrush fillBrush = new SolidBrush(color))
                g.FillPath(fillBrush, fillPath);
        }

        private void DrawRule(Graphics g, int y)
        {
            using (Pen pen = new Pen(_rule, 1.0f))
                g.DrawLine(pen, 16, y, LogicalWidth - 16, y);
        }

        private int Scale(int value)
        {
            return Math.Max(1, (int)Math.Round(value * _scale));
        }

        private static float ReadScale(Screen screen)
        {
            try
            {
                NativePoint point = new NativePoint { X = screen.Bounds.Left + 1, Y = screen.Bounds.Top + 1 };
                IntPtr monitor = MonitorFromPoint(point, 2);
                uint dpiX;
                uint dpiY;
                if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out dpiX, out dpiY) == 0 && dpiX >= 96)
                    return Math.Max(1.0f, Math.Min(3.0f, dpiX / 96.0f));
            }
            catch { }
            return 1.0f;
        }

        private static void DrawText(Graphics g, string value, Font font, Color color, float x, float y)
        {
            using (SolidBrush brush = new SolidBrush(color))
                g.DrawString(value, font, brush, x, y, StringFormat.GenericTypographic);
        }

        private static void DrawRightText(Graphics g, string value, Font font, Color color, float right, float y)
        {
            SizeF size = g.MeasureString(value, font, Int32.MaxValue, StringFormat.GenericTypographic);
            DrawText(g, value, font, color, right - size.Width, y);
        }

        private void DrawCpuIcon(Graphics g, Rectangle r, Color color)
        {
            using (Pen pen = new Pen(color, 1.2f))
            {
                g.DrawRectangle(pen, r);
                g.DrawRectangle(pen, r.X + 4, r.Y + 4, r.Width - 8, r.Height - 8);
                for (int i = 0; i < 3; i++)
                {
                    int offset = 3 + i * 4;
                    g.DrawLine(pen, r.X + offset, r.Y - 2, r.X + offset, r.Y);
                    g.DrawLine(pen, r.X + offset, r.Bottom, r.X + offset, r.Bottom + 2);
                }
            }
        }

        private void DrawRamIcon(Graphics g, Rectangle r, Color color)
        {
            using (Pen pen = new Pen(color, 1.2f))
            {
                g.DrawRectangle(pen, r.X, r.Y + 2, r.Width, r.Height - 4);
                for (int i = 0; i < 3; i++)
                    g.DrawRectangle(pen, r.X + 3 + i * 4, r.Y + 5, 2, 3);
                for (int i = 0; i < 4; i++)
                    g.DrawLine(pen, r.X + 2 + i * 4, r.Bottom - 2, r.X + 2 + i * 4, r.Bottom);
            }
        }

        private void DrawDiskIcon(Graphics g, Rectangle r, Color color)
        {
            using (Pen pen = new Pen(color, 1.2f))
            {
                g.DrawEllipse(pen, r);
                g.DrawEllipse(pen, r.X + 5, r.Y + 5, 4, 4);
                g.DrawLine(pen, r.X + 9, r.Y + 9, r.Right - 1, r.Bottom - 1);
            }
        }

        private void DrawGpuIcon(Graphics g, Rectangle r, Color color)
        {
            using (Pen pen = new Pen(color, 1.2f))
            {
                g.DrawRectangle(pen, r);
                g.DrawEllipse(pen, r.X + 4, r.Y + 3, 7, 7);
                g.DrawLine(pen, r.Right, r.Y + 3, r.Right + 2, r.Y + 3);
                g.DrawLine(pen, r.Right, r.Bottom - 3, r.Right + 2, r.Bottom - 3);
            }
        }

        private Color MetricColor(int value)
        {
            if (value >= 82) return _warning;
            return _accent;
        }

        private static string BuildAccessibleSummary(MetricSnapshot snapshot)
        {
            List<string> parts = new List<string>();
            parts.Add("GPU limits " + (snapshot.GpuLimitsHealthy ? "active" : "not applied") + ".");
            parts.Add("CPU " + FormatPercent(snapshot.CpuPercent) + ".");
            parts.Add("RAM " + FormatPercent(snapshot.RamPercent) + ".");
            foreach (DriveMetric drive in snapshot.Drives)
                parts.Add("Drive " + drive.Name + " used " + FormatPercent(drive.UsedPercent) + ".");
            foreach (GpuMetric gpu in snapshot.Gpus)
                parts.Add(String.Format(CultureInfo.InvariantCulture, "GPU {0} load {1} percent, VRAM {2} percent, power {3:0} of {4:0} watts, temperature {5} degrees.", gpu.Index, gpu.LoadPercent, gpu.VramPercent, gpu.PowerDrawWatts, gpu.PowerLimitWatts, gpu.TemperatureC));
            return String.Join(" ", parts.ToArray());
        }

        private static string FormatPercent(int value)
        {
            return value < 0 ? "--%" : String.Format(CultureInfo.InvariantCulture, "{0}%", value);
        }

        private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
        {
            int diameter = radius * 2;
            GraphicsPath path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _paintTimer.Dispose();
                _titleFont.Dispose();
                _statusFont.Dispose();
                _sectionFont.Dispose();
                _bodyFont.Dispose();
                _metricFont.Dispose();
                _smallFont.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    internal sealed class OverlayContext : ApplicationContext
    {
        private readonly MetricsProvider _metrics;
        private readonly SettingsStore _settingsStore;
        private readonly Control _dispatcher;
        private readonly HotkeyWindow _hotkeyWindow;
        private readonly NotifyIcon _trayIcon;
        private readonly ToolStripMenuItem _visibilityMenu;
        private readonly ToolStripMenuItem _lockMenu;
        private readonly EventWaitHandle _settingsRequestEvent;
        private readonly System.Threading.Timer _settingsRequestTimer;
        private OverlaySettings _settings;
        private OverlayForm _form;
        private bool _hudVisible = true;
        private bool _settingsOpen;
        private string _hotkeyStatus = String.Empty;

        public OverlayContext(string nvidiaSmi, string gpuStatePath, string settingsPath, int intervalMilliseconds, double opacity, string targetDeviceName, bool openSettingsOnStart)
        {
            _dispatcher = new Control();
            _dispatcher.CreateControl();
            _settingsStore = new SettingsStore(settingsPath);
            _settings = _settingsStore.Load(targetDeviceName, opacity);
            if (String.IsNullOrWhiteSpace(_settings.TargetDeviceName) && Screen.PrimaryScreen != null)
                _settings.TargetDeviceName = Screen.PrimaryScreen.DeviceName;

            _metrics = new MetricsProvider(nvidiaSmi, gpuStatePath);
            _metrics.Start(intervalMilliseconds);
            _settingsRequestEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\CA-SystemOverlay-OpenSettings");
            _settingsRequestTimer = new System.Threading.Timer(PollSettingsRequest, null, 500, 500);
            _hotkeyWindow = new HotkeyWindow();
            _hotkeyWindow.Triggered += delegate { ToggleLock(); };
            if (!_hotkeyWindow.TryConfigure(_settings.HotkeyModifiers, _settings.HotkeyKey))
                _hotkeyStatus = "That shortcut is already used by another application.";

            ContextMenuStrip trayMenu = new ContextMenuStrip();
            trayMenu.Font = new Font("Segoe UI", 9.0f);
            ToolStripMenuItem settingsMenu = new ToolStripMenuItem("Display, shortcut & power…");
            settingsMenu.Click += delegate { OpenSettings(); };
            trayMenu.Items.Add(settingsMenu);
            trayMenu.Items.Add(new ToolStripSeparator());
            _visibilityMenu = new ToolStripMenuItem();
            _visibilityMenu.Click += delegate { ToggleVisibility(); };
            trayMenu.Items.Add(_visibilityMenu);
            _lockMenu = new ToolStripMenuItem();
            _lockMenu.Click += delegate { ToggleLock(); };
            trayMenu.Items.Add(_lockMenu);
            trayMenu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem exitMenu = new ToolStripMenuItem("Exit CA HUD");
            exitMenu.Click += delegate { ExitThread(); };
            trayMenu.Items.Add(exitMenu);

            _trayIcon = new NotifyIcon();
            _trayIcon.Icon = SystemIcons.Shield;
            _trayIcon.Text = "CA AutoConfig";
            _trayIcon.Visible = true;
            _trayIcon.ContextMenuStrip = trayMenu;
            _trayIcon.DoubleClick += delegate { OpenSettings(); };

            BuildWindow();
            UpdateTrayMenu();
            SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
            if (openSettingsOnStart)
                _dispatcher.BeginInvoke(new MethodInvoker(OpenSettings));
        }

        private void BuildWindow()
        {
            if (_form != null)
            {
                _form.Close();
                _form.Dispose();
                _form = null;
            }
            if (!_hudVisible)
                return;

            Screen target = null;
            foreach (Screen screen in Screen.AllScreens)
            {
                if (String.Equals(screen.DeviceName, _settings.TargetDeviceName, StringComparison.OrdinalIgnoreCase))
                {
                    target = screen;
                    break;
                }
            }
            if (target == null)
                return;

            _form = new OverlayForm(target, _metrics, _settings);
            _form.SettingsRequested += delegate { OpenSettings(); };
            _form.PositionCommitted += delegate { SaveSettings(); };
            _form.LockStateChanged += delegate { UpdateTrayMenu(); };
            _form.Show();
        }

        private void OpenSettings()
        {
            if (_settingsOpen)
                return;
            _settingsOpen = true;
            try
            {
            while (true)
            {
                using (SettingsForm form = new SettingsForm(_settings, _metrics, _hotkeyStatus))
                {
                    if (form.ShowDialog() != DialogResult.OK)
                        return;
                    OverlaySettings candidate = form.ResultSettings;
                    if (!_hotkeyWindow.TryConfigure(candidate.HotkeyModifiers, candidate.HotkeyKey))
                    {
                        _hotkeyStatus = "That shortcut is already used by another application. Choose another combination.";
                        MessageBox.Show(_hotkeyStatus, "Shortcut unavailable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        _settings = candidate;
                        continue;
                    }
                    _hotkeyStatus = String.Empty;
                    _settings = candidate;
                    SaveSettings();
                    BuildWindow();
                    UpdateTrayMenu();
                    return;
                }
            }
            }
            finally
            {
                _settingsOpen = false;
            }
        }

        private void PollSettingsRequest(object ignored)
        {
            try
            {
                if (_settingsRequestEvent.WaitOne(0) && !_dispatcher.IsDisposed)
                    _dispatcher.BeginInvoke(new MethodInvoker(OpenSettings));
            }
            catch { }
        }

        private void SaveSettings()
        {
            try
            {
                _settingsStore.Save(_settings);
            }
            catch (Exception error)
            {
                _hotkeyStatus = "Settings could not be saved: " + error.Message;
            }
        }

        private void ToggleVisibility()
        {
            _hudVisible = !_hudVisible;
            BuildWindow();
            UpdateTrayMenu();
        }

        private void ToggleLock()
        {
            if (_form == null)
            {
                if (!_hudVisible)
                {
                    _hudVisible = true;
                    BuildWindow();
                }
                if (_form == null)
                    return;
            }
            _form.ToggleLock();
            UpdateTrayMenu();
        }

        private void UpdateTrayMenu()
        {
            _visibilityMenu.Text = _hudVisible ? "Hide HUD" : "Show HUD";
            bool locked = _form == null || _form.IsLocked;
            _lockMenu.Text = (locked ? "Unlock HUD" : "Lock HUD") + "  (" + HotkeyCaptureBox.FormatHotkey(_settings.HotkeyModifiers, _settings.HotkeyKey) + ")";
            _lockMenu.Enabled = _form != null || !_hudVisible;
        }

        private void DisplaySettingsChanged(object sender, EventArgs e)
        {
            if (!_dispatcher.IsDisposed)
                _dispatcher.BeginInvoke(new MethodInvoker(BuildWindow));
        }

        protected override void ExitThreadCore()
        {
            _trayIcon.Visible = false;
            base.ExitThreadCore();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
                if (_form != null)
                    _form.Dispose();
                _trayIcon.Dispose();
                _hotkeyWindow.Dispose();
                _settingsRequestTimer.Dispose();
                _settingsRequestEvent.Dispose();
                _dispatcher.Dispose();
                _metrics.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    public static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        public static bool RequestSettings()
        {
            try
            {
                using (EventWaitHandle request = EventWaitHandle.OpenExisting("Local\\CA-SystemOverlay-OpenSettings"))
                {
                    request.Set();
                    return true;
                }
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return false;
            }
        }

        public static void Run(string nvidiaSmi, string gpuStatePath, string settingsPath, int intervalMilliseconds, double opacity, string targetDeviceName, bool openSettingsOnStart)
        {
            bool created;
            using (Mutex singleton = new Mutex(true, "Local\\CA-SystemOverlay", out created))
            {
                if (!created)
                    return;
                SetProcessDPIAware();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (OverlayContext context = new OverlayContext(nvidiaSmi, gpuStatePath, settingsPath, intervalMilliseconds, opacity, targetDeviceName, openSettingsOnStart))
                    Application.Run(context);
            }
        }
    }
}
