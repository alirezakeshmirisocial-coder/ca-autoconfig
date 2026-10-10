using System;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace CA.SystemOverlay
{
    internal static class DesktopEntryPoint
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string nvidiaSmi = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "nvidia-smi.exe");
            string gpuState = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CAGpuLimits", "gpu-limits-state.json");
            string settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CAAutoConfig", "settings.json");
            string targetDisplay = String.Empty;
            string smokeResult = String.Empty;
            string windowsGpuProbeResult = String.Empty;
            string windowsGpuPollResult = String.Empty;
            string windowsGpuProvider = "wmi";
            bool windowsGpuProviderSpecified = false;
            int windowsGpuPollSeconds = 60;
            int windowsGpuPollMilliseconds = 2000;
            bool windowsGpuPollOptionSpecified = false;
            int pollMilliseconds = 2000;
            double opacity = 0.82;
            bool openSettings = false;

            try
            {
                for (int index = 0; index < args.Length; index++)
                {
                    string argument = args[index];
                    if (String.Equals(argument, "--open-settings", StringComparison.OrdinalIgnoreCase))
                    {
                        openSettings = true;
                    }
                    else if (String.Equals(argument, "--settings", StringComparison.OrdinalIgnoreCase))
                    {
                        settings = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(argument, "--nvidia-smi", StringComparison.OrdinalIgnoreCase))
                    {
                        nvidiaSmi = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(argument, "--gpu-state", StringComparison.OrdinalIgnoreCase))
                    {
                        gpuState = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(argument, "--display", StringComparison.OrdinalIgnoreCase))
                    {
                        targetDisplay = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(argument, "--poll-ms", StringComparison.OrdinalIgnoreCase))
                    {
                        pollMilliseconds = Int32.Parse(ReadValue(args, ref index, argument), CultureInfo.InvariantCulture);
                    }
                    else if (String.Equals(argument, "--opacity", StringComparison.OrdinalIgnoreCase))
                    {
                        opacity = Double.Parse(ReadValue(args, ref index, argument), CultureInfo.InvariantCulture);
                    }
                    else if (String.Equals(argument, "--smoke-test-result", StringComparison.OrdinalIgnoreCase))
                    {
                        smokeResult = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(argument, "--windows-gpu-probe-result", StringComparison.OrdinalIgnoreCase))
                    {
                        windowsGpuProbeResult = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(argument, "--windows-gpu-poll-result", StringComparison.OrdinalIgnoreCase))
                    {
                        windowsGpuPollResult = ReadValue(args, ref index, argument);
                        windowsGpuPollOptionSpecified = true;
                    }
                    else if (String.Equals(argument, "--windows-gpu-poll-seconds", StringComparison.OrdinalIgnoreCase))
                    {
                        windowsGpuPollSeconds = Int32.Parse(ReadValue(args, ref index, argument), CultureInfo.InvariantCulture);
                        windowsGpuPollOptionSpecified = true;
                    }
                    else if (String.Equals(argument, "--windows-gpu-poll-ms", StringComparison.OrdinalIgnoreCase))
                    {
                        windowsGpuPollMilliseconds = Int32.Parse(ReadValue(args, ref index, argument), CultureInfo.InvariantCulture);
                        windowsGpuPollOptionSpecified = true;
                    }
                    else if (String.Equals(argument, "--windows-gpu-provider", StringComparison.OrdinalIgnoreCase))
                    {
                        windowsGpuProvider = ReadValue(args, ref index, argument).ToLowerInvariant();
                        windowsGpuProviderSpecified = true;
                    }
                    else
                    {
                        throw new ArgumentException("Unknown argument: " + argument);
                    }
                }

                if (pollMilliseconds < 1000 || pollMilliseconds > 60000)
                    throw new ArgumentOutOfRangeException("pollMilliseconds", "--poll-ms must be between 1000 and 60000.");
                if (opacity < 0.58 || opacity > 0.95)
                    throw new ArgumentOutOfRangeException("opacity", "--opacity must be between 0.58 and 0.95.");
                if (windowsGpuPollOptionSpecified && String.IsNullOrWhiteSpace(windowsGpuPollResult))
                    throw new ArgumentException("--windows-gpu-poll-result is required with Windows GPU polling options.");
                if (windowsGpuProviderSpecified && String.IsNullOrWhiteSpace(windowsGpuProbeResult) && String.IsNullOrWhiteSpace(windowsGpuPollResult))
                    throw new ArgumentException("--windows-gpu-provider is only valid with a Windows GPU probe or polling benchmark.");
                if (!String.Equals(windowsGpuProvider, "wmi", StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(windowsGpuProvider, "pdh", StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("--windows-gpu-provider must be 'wmi' or 'pdh'.");
                if (!String.IsNullOrWhiteSpace(windowsGpuProbeResult) && !String.IsNullOrWhiteSpace(windowsGpuPollResult))
                    throw new ArgumentException("Choose either the one-shot Windows GPU probe or the polling benchmark, not both.");
                if (windowsGpuPollSeconds < 10 || windowsGpuPollSeconds > 3600)
                    throw new ArgumentOutOfRangeException("windowsGpuPollSeconds", "--windows-gpu-poll-seconds must be between 10 and 3600.");
                if (windowsGpuPollMilliseconds < 1000 || windowsGpuPollMilliseconds > 60000)
                    throw new ArgumentOutOfRangeException("windowsGpuPollMilliseconds", "--windows-gpu-poll-ms must be between 1000 and 60000.");

                if (!String.IsNullOrWhiteSpace(smokeResult))
                    return DesktopSmokeTest.Run(smokeResult);
                if (!String.IsNullOrWhiteSpace(windowsGpuProbeResult))
                    return WindowsGpuLiveReport.Write(windowsGpuProbeResult, windowsGpuProvider);
                if (!String.IsNullOrWhiteSpace(windowsGpuPollResult))
                    return WindowsGpuPollingBenchmark.Write(windowsGpuPollResult, windowsGpuPollSeconds, windowsGpuPollMilliseconds, windowsGpuProvider);
                if (openSettings && Program.RequestSettings())
                    return 0;

                Program.Run(nvidiaSmi, gpuState, settings, pollMilliseconds, opacity, targetDisplay, openSettings);
                return 0;
            }
            catch (Exception error)
            {
                MessageBox.Show(error.Message, "CA AutoConfig", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
        }

        private static string ReadValue(string[] args, ref int index, string argument)
        {
            index++;
            if (index >= args.Length || String.IsNullOrWhiteSpace(args[index]))
                throw new ArgumentException("Missing value for " + argument + ".");
            return args[index];
        }
    }

    internal static class DesktopSmokeTest
    {
        internal static int Run(string resultPath)
        {
            string temporaryRoot = Path.Combine(Path.GetTempPath(), "ca-desktop-smoke-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(temporaryRoot);
                string settingsPath = Path.Combine(temporaryRoot, "settings.json");
                SettingsStore store = new SettingsStore(settingsPath);
                OverlaySettings expected = new OverlaySettings
                {
                    TargetDeviceName = "\\\\.\\DISPLAY_TEST",
                    HasCustomPosition = true,
                    PositionX = 41,
                    PositionY = 83,
                    Opacity = 0.74,
                    HotkeyModifiers = 6,
                    HotkeyKey = (int)Keys.H
                };
                store.Save(expected);
                OverlaySettings actual = store.Load(String.Empty, 0.82);
                if (actual.SchemaVersion != OverlaySettings.CurrentSchemaVersion ||
                    actual.TargetDeviceName != expected.TargetDeviceName ||
                    actual.PositionX != expected.PositionX ||
                    actual.PositionY != expected.PositionY ||
                    actual.HotkeyModifiers != expected.HotkeyModifiers ||
                    actual.HotkeyKey != expected.HotkeyKey)
                    throw new InvalidOperationException("Compiled settings round-trip failed.");

                string resultDirectory = Path.GetDirectoryName(Path.GetFullPath(resultPath));
                if (!String.IsNullOrEmpty(resultDirectory))
                    Directory.CreateDirectory(resultDirectory);
                File.WriteAllText(resultPath,
                    "{\"status\":\"passed\",\"schemaVersion\":" + OverlaySettings.CurrentSchemaVersion.ToString(CultureInfo.InvariantCulture) + ",\"hardwareWrites\":false}",
                    new UTF8Encoding(false));
                return 0;
            }
            catch (Exception error)
            {
                try
                {
                    File.WriteAllText(resultPath,
                        "{\"status\":\"failed\",\"message\":\"" + Escape(error.Message) + "\",\"hardwareWrites\":false}",
                        new UTF8Encoding(false));
                }
                catch { }
                return 1;
            }
            finally
            {
                try { Directory.Delete(temporaryRoot, true); }
                catch { }
            }
        }

        private static string Escape(string value)
        {
            return (value ?? String.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }
    }
}
