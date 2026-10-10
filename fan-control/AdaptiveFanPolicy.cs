// Simulation only. C# 5 / Windows PowerShell 5.1 Add-Type compatible.
// No device, process, network, clock, registry, or file access is present.
using System;
using System.Collections.Generic;

namespace CA.FanControl
{
    public enum ControlState { VendorAuto, Observing, Calibrating, Tracking, HeatLimited, Cooldown, SensorFault, FanFault, Emergency }

    public sealed class Reading
    {
        public double Value;
        public double AtSeconds;
        public double Confidence = 1;
        public Reading(double value, double atSeconds) { Value = value; AtSeconds = atSeconds; }
    }

    public sealed class FanReading
    {
        public Reading IntendedPercent;
        public Reading Rpm;
        // A value expressed in RPM is NOT sufficient: provenance must establish physical tachometry.
        public bool RpmIsPhysical;
        public bool SpinExpected;
    }

    public sealed class DeviceProfile
    {
        // Exact device/board/VBIOS/driver/topology/configuration revision, not just a product family.
        public string EvidenceKey;
        public string Model;
        public bool LimitsVerified;
        public int FanCount;
        public double FanMinPercent;
        public double FanMaxPercent;
        public double MinSpinningRpm = 200;
        public double? CoreLimitC;
        public double? HotspotLimitC;
        public double? MemoryLimitC;
        public bool HotspotExpected;
        public bool MemoryExpected;
        public double PowerMinW;
        public double PowerMaxW;
        public double AcousticPreferencePercent = 75;
        public CleanReference CleanBaseline;
    }

    public sealed class CleanReference
    {
        public double EffectiveResistanceCPerW;
        public double FanPercent;
        public double BoardPowerW;
        public double OtherHeatW;
        public double AmbientC;
    }

    public sealed class Snapshot
    {
        // Monotonic session time, supplied by caller. A session restart requires a new Memory.
        public double NowSeconds;
        public Reading CoreC;
        public Reading HotspotC;
        public Reading MemoryC;
        public Reading BoardPowerW;
        public Reading CurrentPowerLimitW;
        public Reading ManualAmbientC;
        public Reading AmbientSensorC;
        public Reading InletC;
        // Sum of other GPUs and estimated CPU/other chassis heat; zero must be explicit.
        public Reading OtherHeatW;
        public FanReading[] Fans;
        public bool ThermalThrottle;
        public bool AcknowledgeFault;
    }

    internal sealed class Plateau
    {
        public double Fan, Power, Other, Ambient, Core, Hotspot, Memory, Inlet;
        public bool HasHotspot, HasMemory, HasInlet;
        public Plateau Copy() { return (Plateau)MemberwiseClone(); }
    }

    public sealed class Memory
    {
        public ControlState State { get; internal set; }
        public bool CalibrationComplete { get; internal set; }
        public bool ObservationComplete { get; internal set; }
        public double ObservedSeconds { get; internal set; }
        public double StableSeconds { get; internal set; }
        internal string Key;
        internal double LastNow = double.NaN, LastCoreAt = double.NaN;
        internal double LastCore, LastHotspot, LastMemory, FilteredCore;
        internal bool SeenHotspot, SeenMemory, SeenInlet;
        internal int ValidSamples;
        internal double LastFanChange = double.NegativeInfinity;
        internal double VirtualFan = double.NaN;
        internal double RecoverySeconds, StallSeconds, DegradedSeconds, LastPlateauAt = double.NegativeInfinity;
        internal double CoolSeconds;
        internal bool FanFaultLatched, EmergencyLatched;
        internal Plateau Anchor;
        internal List<Plateau> Plateaus = new List<Plateau>();
        internal List<ThermalSample> Samples = new List<ThermalSample>();
        internal ThermalModel ThermalModel;
        internal CalibrationReport FitReport;
        internal double LastFitTime = double.NegativeInfinity, DriftAnchorTime, ModelBadSeconds;
        internal double[] DriftPrediction;
        public Memory() { State = ControlState.Observing; }
        internal Memory Copy()
        {
            Memory n = (Memory)MemberwiseClone();
            n.Anchor = Anchor == null ? null : Anchor.Copy();
            n.Plateaus = new List<Plateau>();
            foreach (Plateau p in Plateaus) n.Plateaus.Add(p.Copy());
            n.Samples = new List<ThermalSample>(Samples);
            n.DriftPrediction = DriftPrediction == null ? null : (double[])DriftPrediction.Clone();
            return n;
        }
    }

    public sealed class Recommendation
    {
        public Memory Next { get; internal set; }
        public ControlState State { get { return Next.State; } }
        public bool CanApply { get { return false; } }
        public string Mode { get { return "SimulationOnly"; } }
        public bool VendorAutoRecommended { get { return true; } }
        public double? FanPercent { get; internal set; }
        public double? PowerLimitW { get; internal set; }
        public bool ReduceWorkload { get; internal set; }
        public bool StopWorkload { get; internal set; }
        public bool MaintenanceSuggested { get; internal set; }
        public bool TargetInfeasibleAtMinimumPower { get; internal set; }
        public bool DiminishingFanReturns { get; internal set; }
        public double Confidence { get; internal set; }
        public double ModelConfidence { get; internal set; }
        public double? AmbientC { get; internal set; }
        public double? EffectiveResistanceCPerW { get; internal set; }
        public double? CaseResistanceCPerW { get; internal set; }
        public double? FanGainCPerPercent { get; internal set; }
        public double CoreRiseCPerSecond { get; internal set; }
        public double CoreEmergencyC { get; internal set; }
        public double HotspotEmergencyC { get; internal set; }
        public double MemoryEmergencyC { get; internal set; }
        public string[] Reasons { get; internal set; }
        public CalibrationReport Calibration { get; internal set; }
        public double? ForecastCoreUpperC { get; internal set; }
        public double? ForecastHotspotUpperC { get; internal set; }
        public double? ForecastMemoryUpperC { get; internal set; }
        public double? OptimizationCost { get; internal set; }
    }

    public static class AdaptiveFanPolicy
    {
        public const double SensorMaxAgeSeconds = 5;
        public const double ManualAmbientMaxAgeSeconds = 3600;
        public const double ObservationSeconds = 300;
        public const double SoakSeconds = 120;
        public const double RecoverySeconds = 120;
        public const double HysteresisC = 2;
        public const double FanRisePercentPerSecond = 1;
        public const double FanFallPercentPerSecond = 0.25;
        public const double TemperatureRiseWarningCPerSecond = 0.5;

        private static bool Finite(double x) { return !double.IsNaN(x) && !double.IsInfinity(x); }
        private static double Clamp(double x, double lo, double hi) { return Math.Max(lo, Math.Min(hi, x)); }
        private static bool Good(Reading r, double now, double lo, double hi, double age)
        {
            return r != null && Finite(r.Value) && Finite(r.AtSeconds) && Finite(r.Confidence)
                && r.Value >= lo && r.Value <= hi && r.AtSeconds <= now
                && now - r.AtSeconds <= age && r.Confidence >= 0.5 && r.Confidence <= 1;
        }
        private static bool Temp(Reading r, double now) { return Good(r, now, -20, 150, SensorMaxAgeSeconds); }
        private static double Ceiling(double fallback, double? vendor)
        {
            return vendor.HasValue && Finite(vendor.Value) && vendor.Value >= 40 && vendor.Value <= 150
                ? Math.Min(fallback, vendor.Value - 3) : fallback;
        }
        private static bool ValidLimit(double? v) { return v.HasValue && Finite(v.Value) && v.Value >= 40 && v.Value <= 150; }
        private static bool ProfileValid(DeviceProfile p, Memory m)
        {
            return p != null && p.LimitsVerified && !string.IsNullOrWhiteSpace(p.EvidenceKey)
                && !string.IsNullOrWhiteSpace(p.Model) && p.FanCount > 0 && p.FanCount <= 16
                && Finite(p.FanMinPercent) && Finite(p.FanMaxPercent)
                && p.FanMinPercent >= 0 && p.FanMaxPercent <= 100 && p.FanMaxPercent > p.FanMinPercent
                && Finite(p.MinSpinningRpm) && p.MinSpinningRpm > 0 && p.MinSpinningRpm <= 5000
                && ValidLimit(p.CoreLimitC) && (!(p.HotspotExpected || m.SeenHotspot) || ValidLimit(p.HotspotLimitC))
                && (!(p.MemoryExpected || m.SeenMemory) || ValidLimit(p.MemoryLimitC))
                && Finite(p.PowerMinW) && Finite(p.PowerMaxW) && p.PowerMinW > 0 && p.PowerMaxW >= p.PowerMinW
                && Finite(p.AcousticPreferencePercent) && p.AcousticPreferencePercent >= 0 && p.AcousticPreferencePercent <= 100;
        }
        private static void ResetCalibration(Memory m)
        {
            m.CalibrationComplete = false; m.ObservedSeconds = 0; m.StableSeconds = 0; m.ValidSamples = 0;
            m.Anchor = null; m.Plateaus.Clear(); m.VirtualFan = double.NaN;
            m.LastPlateauAt = double.NegativeInfinity; m.CoolSeconds = 0; m.DegradedSeconds = 0;
            m.ObservationComplete = false; m.Samples.Clear(); m.ThermalModel = null; m.FitReport = null;
            m.LastFitTime = double.NegativeInfinity; m.DriftPrediction = null; m.ModelBadSeconds = 0;
        }
        private static Recommendation Finish(Recommendation r, List<string> reasons, ControlState state)
        {
            r.Next.State = state; r.Next.ObservationComplete = r.Next.CalibrationComplete;
            r.Reasons = reasons.ToArray(); return r;
        }
        private static bool Similar(double a, double b, double abs, double relative)
        {
            return Math.Abs(a - b) <= Math.Max(abs, Math.Abs(b) * relative);
        }
        private static bool Stable(Plateau a, Plateau b)
        {
            return Similar(a.Core, b.Core, 1, 0) && Similar(a.Ambient, b.Ambient, 1, 0)
                && Similar(a.Power, b.Power, 5, 0.08) && Similar(a.Other, b.Other, 10, 0.08)
                && Similar(a.Fan, b.Fan, 3, 0) && a.HasInlet == b.HasInlet
                && (!a.HasInlet || Similar(a.Inlet, b.Inlet, 1, 0))
                && a.HasHotspot == b.HasHotspot && (!a.HasHotspot || Similar(a.Hotspot, b.Hotspot, 1, 0))
                && a.HasMemory == b.HasMemory && (!a.HasMemory || Similar(a.Memory, b.Memory, 1, 0));
        }
        private static double Slope(Reading r, double last, double dt)
        {
            return r == null || dt <= 0 ? 0 : (r.Value - last) / dt;
        }

        public static Recommendation Evaluate(DeviceProfile profile, Snapshot s, Memory previous)
        {
            return CalibratedFanController.Evaluate(profile, s, previous);
        }

        // Safety/observation reference branch; internal so callers cannot bypass predictive calibration.
        internal static Recommendation EvaluateGuard(DeviceProfile profile, Snapshot s, Memory previous)
        {
            if (s == null) throw new ArgumentNullException("s");
            if (profile == null) throw new ArgumentNullException("profile");
            Memory m = previous == null ? new Memory() : previous.Copy();
            m.CalibrationComplete = m.ObservationComplete;
            Recommendation r = new Recommendation { Next = m };
            List<string> reasons = new List<string>();
            bool keyChanged = m.Key != null && m.Key != profile.EvidenceKey;
            if (keyChanged)
            {
                // Configuration changes must not be a way to dismiss a latched incident.
                bool emergencyLatch = m.EmergencyLatched, fanLatch = m.FanFaultLatched;
                m = new Memory(); m.EmergencyLatched = emergencyLatch; m.FanFaultLatched = fanLatch;
                r.Next = m; reasons.Add("Device or configuration changed; observation restarted.");
            }
            m.Key = profile.EvidenceKey;
            double dt = double.IsNaN(m.LastNow) ? 0 : s.NowSeconds - m.LastNow;
            bool timeOk = Finite(s.NowSeconds) && s.NowSeconds >= 0 && (double.IsNaN(m.LastNow) || dt > 0);
            bool gap = dt > SensorMaxAgeSeconds;
            if (!timeOk || gap)
            {
                ResetCalibration(m);
                reasons.Add("Clock/order error or observation gap; discard calibration and request vendor auto.");
            }
            double advance = timeOk && !gap ? dt : 0;
            double now = s.NowSeconds;
            bool coreOk = Temp(s.CoreC, now);
            bool hotOk = Temp(s.HotspotC, now);
            bool memOk = Temp(s.MemoryC, now);
            bool hotRequired = profile.HotspotExpected || m.SeenHotspot || s.HotspotC != null;
            bool memRequired = profile.MemoryExpected || m.SeenMemory || s.MemoryC != null;
            bool inletOk = Good(s.InletC, now, -20, 80, SensorMaxAgeSeconds);
            bool inletRequired = m.SeenInlet || s.InletC != null;
            bool powerOk = Good(s.BoardPowerW, now, 0, 3000, SensorMaxAgeSeconds);
            bool otherOk = Good(s.OtherHeatW, now, 0, 20000, SensorMaxAgeSeconds);
            bool manualOk = Good(s.ManualAmbientC, now, -10, 60, ManualAmbientMaxAgeSeconds);
            bool ambientSensorOk = Good(s.AmbientSensorC, now, -10, 60, SensorMaxAgeSeconds);
            bool ambientOk = manualOk || ambientSensorOk;
            double ambient = ambientSensorOk ? s.AmbientSensorC.Value : manualOk ? s.ManualAmbientC.Value : 0;
            bool ambientConflict = manualOk && ambientSensorOk && Math.Abs(s.ManualAmbientC.Value - s.AmbientSensorC.Value) > 3;
            if (ambientConflict) ambient = Math.Max(s.ManualAmbientC.Value, s.AmbientSensorC.Value);
            if (ambientOk) r.AmbientC = ambient;
            if (hotOk) m.SeenHotspot = true;
            if (memOk) m.SeenMemory = true;
            if (inletOk) m.SeenInlet = true;
            bool supports = ProfileValid(profile, m);
            bool limitOk = Good(s.CurrentPowerLimitW, now, profile.PowerMinW, profile.PowerMaxW, SensorMaxAgeSeconds);
            r.CoreEmergencyC = Ceiling(85, profile.CoreLimitC);
            r.HotspotEmergencyC = Ceiling(100, profile.HotspotLimitC);
            r.MemoryEmergencyC = Ceiling(96, profile.MemoryLimitC);
            double coreWarn = r.CoreEmergencyC - 5, hotWarn = r.HotspotEmergencyC - 5, memWarn = r.MemoryEmergencyC - 5;
            double coreTarget = Math.Min(72, coreWarn - 4), hotTarget = Math.Min(88, hotWarn - 4), memTarget = Math.Min(86, memWarn - 4);
            bool freshCore = coreOk && (double.IsNaN(m.LastCoreAt) || s.CoreC.AtSeconds > m.LastCoreAt);
            bool sensorsOk = timeOk && !gap && freshCore && powerOk && otherOk && ambientOk
                && (!hotRequired || hotOk) && (!memRequired || memOk) && (!inletRequired || inletOk)
                && (!inletOk || s.InletC.Value >= ambient - 2) && (!coreOk || !ambientOk || s.CoreC.Value >= ambient - 3)
                && (!hotOk || !coreOk || s.HotspotC.Value >= s.CoreC.Value - 2);
            bool fansOk = s.Fans != null && s.Fans.Length == profile.FanCount && s.Fans.Length > 0;
            bool realTach = fansOk, spinningVerified = fansOk, stall = false;
            double fan = 0;
            if (fansOk)
            {
                foreach (FanReading f in s.Fans)
                {
                    bool intendedOk = f != null && Good(f.IntendedPercent, now, 0, 200, SensorMaxAgeSeconds);
                    if (!intendedOk) { fansOk = false; realTach = false; spinningVerified = false; continue; }
                    fan = Math.Max(fan, f.IntendedPercent.Value);
                    bool tachOk = f.RpmIsPhysical && Good(f.Rpm, now, 0, 20000, SensorMaxAgeSeconds);
                    if (!tachOk) realTach = false;
                    if (!tachOk || f.Rpm.Value < profile.MinSpinningRpm) spinningVerified = false;
                    bool expected = f.SpinExpected || f.IntendedPercent.Value >= Math.Max(20, profile.FanMinPercent);
                    if (expected && tachOk && f.Rpm.Value < profile.MinSpinningRpm) stall = true;
                }
            }
            m.StallSeconds = stall ? m.StallSeconds + advance : 0;
            if (m.StallSeconds >= 10) m.FanFaultLatched = true;
            bool warn = (coreOk && s.CoreC.Value >= coreWarn) || (hotOk && s.HotspotC.Value >= hotWarn) || (memOk && s.MemoryC.Value >= memWarn);
            double coreRise = freshCore && advance > 0 ? Slope(s.CoreC, m.LastCore, s.CoreC.AtSeconds - m.LastCoreAt) : 0;
            double hotRise = hotOk && advance > 0 && m.ValidSamples > 0 ? Slope(s.HotspotC, m.LastHotspot, advance) : 0;
            double memRise = memOk && advance > 0 && m.ValidSamples > 0 ? Slope(s.MemoryC, m.LastMemory, advance) : 0;
            r.CoreRiseCPerSecond = coreRise;
            bool rapidRise = Math.Max(coreRise, Math.Max(hotRise, memRise)) > TemperatureRiseWarningCPerSecond;
            bool approachingEmergency = (coreOk && s.CoreC.Value >= coreWarn && coreRise > 0 && s.CoreC.Value + 5 * coreRise >= r.CoreEmergencyC)
                || (hotOk && s.HotspotC.Value >= hotWarn && hotRise > 0 && s.HotspotC.Value + 5 * hotRise >= r.HotspotEmergencyC)
                || (memOk && s.MemoryC.Value >= memWarn && memRise > 0 && s.MemoryC.Value + 5 * memRise >= r.MemoryEmergencyC);
            bool emergency = s.ThermalThrottle || approachingEmergency
                || (coreOk && s.CoreC.Value >= r.CoreEmergencyC) || (hotOk && s.HotspotC.Value >= r.HotspotEmergencyC)
                || (memOk && s.MemoryC.Value >= r.MemoryEmergencyC);
            bool coolForRecovery = sensorsOk && fansOk && realTach && spinningVerified && !stall && coreOk && s.CoreC.Value < coreWarn - 3
                && (!hotRequired || s.HotspotC.Value < hotWarn - 3) && (!memRequired || s.MemoryC.Value < memWarn - 3);
            if (timeOk) m.LastNow = now;
            if (coreOk) { m.LastCore = s.CoreC.Value; m.LastCoreAt = s.CoreC.AtSeconds; }
            if (hotOk) m.LastHotspot = s.HotspotC.Value;
            if (memOk) m.LastMemory = s.MemoryC.Value;
            if (emergency) m.EmergencyLatched = true;
            if (m.EmergencyLatched || m.FanFaultLatched)
            {
                m.RecoverySeconds = !emergency && coolForRecovery ? m.RecoverySeconds + advance : 0;
                bool latchedEmergency = m.EmergencyLatched;
                if (m.RecoverySeconds >= RecoverySeconds && s.AcknowledgeFault)
                {
                    m.EmergencyLatched = false; m.FanFaultLatched = false; m.RecoverySeconds = 0;
                    ResetCalibration(m); reasons.Add("Fault acknowledged after healthy cooldown; full observation restarted.");
                    return Finish(r, reasons, ControlState.Observing);
                }
                if (latchedEmergency && supports && sensorsOk && realTach && !stall && !m.FanFaultLatched && m.CalibrationComplete)
                    r.FanPercent = profile.FanMaxPercent;
                // Emergency simulations may bypass ramp/dwell; alarms NEVER wait for calibration.
                r.StopWorkload = true; r.ReduceWorkload = true;
                r.Confidence = sensorsOk ? 0.9 : 0;
                reasons.Add(latchedEmergency ? "Thermal emergency: stop load, retain/request vendor auto, acknowledge only after cooling."
                    : "Physical fan stall: stop load, retain/request vendor auto, inspect the fan before acknowledgement.");
                if (m.FanFaultLatched) reasons.Add("Fan tach failure is latched; a higher fan command cannot prove cooling.");
                if (!sensorsOk) reasons.Add("Telemetry is also invalid; emergency/fan-fault latch remains active.");
                return Finish(r, reasons, latchedEmergency ? ControlState.Emergency : ControlState.FanFault);
            }
            if (!sensorsOk || !fansOk || (previous != null && previous.CalibrationComplete && !realTach))
            {
                ResetCalibration(m); m.RecoverySeconds = 0;
                r.ReduceWorkload = true; r.StopWorkload = warn;
                reasons.Add("Required telemetry is stale, missing, repeated, implausible, or lacks physical tach evidence; vendor auto fallback.");
                return Finish(r, reasons, ControlState.SensorFault);
            }
            if (m.State == ControlState.SensorFault)
            {
                m.RecoverySeconds = coolForRecovery ? m.RecoverySeconds + advance : 0;
                if (m.RecoverySeconds < RecoverySeconds)
                {
                    reasons.Add("Waiting for 120 seconds of healthy, cool telemetry before restarting observation.");
                    return Finish(r, reasons, ControlState.SensorFault);
                }
                m.RecoverySeconds = 0; ResetCalibration(m);
            }
            if (!supports)
            {
                ResetCalibration(m); r.ReduceWorkload = warn || rapidRise;
                reasons.Add("Verified device-specific limits are unavailable; numeric recommendations are disabled.");
                return Finish(r, reasons, ControlState.VendorAuto);
            }
            double confidence = Math.Min(s.CoreC.Confidence, Math.Min(s.BoardPowerW.Confidence, s.OtherHeatW.Confidence));
            confidence = Math.Min(confidence, ambientSensorOk ? s.AmbientSensorC.Confidence : Math.Min(0.9, s.ManualAmbientC.Confidence));
            if (hotOk) confidence = Math.Min(confidence, s.HotspotC.Confidence); else confidence -= 0.05;
            if (memOk) confidence = Math.Min(confidence, s.MemoryC.Confidence); else confidence -= 0.05;
            if (!inletOk) confidence -= 0.05; else confidence = Math.Min(confidence, s.InletC.Confidence);
            foreach (FanReading f in s.Fans)
            {
                confidence = Math.Min(confidence, f.IntendedPercent.Confidence);
                if (f.RpmIsPhysical && f.Rpm != null) confidence = Math.Min(confidence, f.Rpm.Confidence);
            }
            if (!realTach) { confidence = Math.Min(confidence, 0.6); reasons.Add("No verified physical tachometry: observation only."); }
            if (!spinningVerified && IsLoaded(s.BoardPowerW.Value, profile.PowerMaxW))
            { confidence = Math.Min(confidence, 0.6); reasons.Add("Loaded calibration requires every fan to demonstrate physical rotation."); }
            if (ambientConflict) { confidence = Math.Min(confidence, 0.6); reasons.Add("Ambient readings disagree by more than 3 C; using the warmer value and withholding recommendations."); }
            if (stall) { confidence = 0; reasons.Add("Fan spin-up/stall check pending; no numeric recommendation."); }
            if (!limitOk) { confidence = Math.Min(confidence, 0.6); reasons.Add("Current enforced power limit is unavailable or outside verified bounds."); }
            else confidence = Math.Min(confidence, s.CurrentPowerLimitW.Confidence);
            r.Confidence = Math.Round(Clamp(confidence, 0, 1), 6);
            if (r.Confidence < 0.75)
            {
                ResetCalibration(m); r.ReduceWorkload = warn || rapidRise;
                reasons.Add("Confidence too low; restart the uninterrupted observation period before numeric advice.");
                return Finish(r, reasons, ControlState.Calibrating);
            }
            Plateau point = new Plateau { Fan = fan, Power = s.BoardPowerW.Value, Other = s.OtherHeatW.Value, Ambient = ambient,
                Core = s.CoreC.Value, Hotspot = hotOk ? s.HotspotC.Value : 0, Memory = memOk ? s.MemoryC.Value : 0,
                Inlet = inletOk ? s.InletC.Value : ambient, HasInlet = inletOk, HasHotspot = hotOk, HasMemory = memOk };
            if (m.Anchor == null || !Stable(point, m.Anchor) || rapidRise || warn)
            { m.Anchor = point.Copy(); m.StableSeconds = 0; }
            else m.StableSeconds += advance;
            m.ObservedSeconds += advance; m.ValidSamples++;
            bool loaded = IsLoaded(point.Power, profile.PowerMaxW);
            if (m.StableSeconds >= SoakSeconds && loaded && !warn && r.Confidence >= 0.75 && now - m.LastPlateauAt >= SoakSeconds)
            {
                m.Plateaus.Add(point.Copy()); m.LastPlateauAt = now;
                if (m.Plateaus.Count > 32) m.Plateaus.RemoveAt(0);
            }
            if (m.ObservedSeconds >= ObservationSeconds && m.ValidSamples >= 30 && m.StableSeconds >= SoakSeconds
                && loaded && r.Confidence >= 0.75 && realTach)
                m.CalibrationComplete = true;
            if (point.Power > 30)
            {
                r.EffectiveResistanceCPerW = Math.Max(0, (point.Core - ambient) / point.Power);
                if (inletOk && point.Power + point.Other > 30)
                    r.CaseResistanceCPerW = Math.Max(0, (point.Inlet - ambient) / (point.Power + point.Other));
            }
            r.ModelConfidence = m.Plateaus.Count == 0 ? 0 : Math.Min(r.Confidence, m.Plateaus.Count >= 3 ? 0.8 : 0.55);
            List<double> gains = new List<double>();
            List<double> distinctFanLevels = new List<double>();
            for (int i = 0; i < m.Plateaus.Count; i++)
            {
                Plateau a = m.Plateaus[i];
                for (int j = i + 1; j < m.Plateaus.Count; j++)
                {
                    Plateau b = m.Plateaus[j];
                    if (Math.Abs(a.Fan - b.Fan) < 10 || !Similar(a.Power, b.Power, 5, 0.05)
                        || !Similar(a.Other, b.Other, 10, 0.05) || !Similar(a.Ambient, b.Ambient, 1, 0)) continue;
                    double gain = -((a.Core - a.Ambient) - (b.Core - b.Ambient)) / (a.Fan - b.Fan);
                    if (Finite(gain))
                    {
                        gains.Add(gain);
                        AddDistinctLevel(distinctFanLevels, a.Fan); AddDistinctLevel(distinctFanLevels, b.Fan);
                    }
                }
            }
            if (gains.Count >= 2 && distinctFanLevels.Count >= 3)
            {
                gains.Sort(); r.FanGainCPerPercent = gains[gains.Count / 2];
                r.DiminishingFanReturns = fan >= 70 && r.FanGainCPerPercent.Value <= 0.03;
            }
            CleanReference clean = profile.CleanBaseline;
            bool comparable = clean != null && Finite(clean.EffectiveResistanceCPerW) && clean.EffectiveResistanceCPerW > 0
                && Similar(point.Fan, clean.FanPercent, 5, 0) && Similar(point.Power, clean.BoardPowerW, 5, 0.1)
                && Similar(point.Other, clean.OtherHeatW, 20, 0.1) && Similar(ambient, clean.AmbientC, 3, 0);
            bool degraded = comparable && r.EffectiveResistanceCPerW.HasValue
                && r.EffectiveResistanceCPerW.Value >= clean.EffectiveResistanceCPerW * 1.25
                && point.Core - ambient - clean.EffectiveResistanceCPerW * point.Power >= 5;
            m.DegradedSeconds = degraded ? m.DegradedSeconds + advance : 0;
            r.MaintenanceSuggested = m.DegradedSeconds >= SoakSeconds;
            if (r.MaintenanceSuggested) reasons.Add("Cooling resistance has worsened at a matched operating point; inspect dust, airflow and cooler contact.");
            if (ambient >= 38) reasons.Add("Hot room: a smaller temperature-to-ambient budget limits cooling headroom.");
            if (r.CaseResistanceCPerW.HasValue && r.CaseResistanceCPerW.Value >= 0.04) reasons.Add("Elevated measured case resistance; inspect intake and exhaust airflow.");
            if (point.Other >= point.Power * 0.5 && point.Other >= 50) reasons.Add("Shared chassis heat is significant; evaluate all GPUs together.");
            if (r.DiminishingFanReturns) reasons.Add("Matched steady samples show little additional cooling from more fan speed.");
            if (rapidRise) reasons.Add("Temperature rise exceeds 0.5 C/s; suspend acoustic optimization and reduce load.");
            if (!hotOk || !memOk) reasons.Add("Some junction sensors are unsupported; core temperature cannot certify their safety.");
            bool aboveTarget = point.Core > coreTarget + HysteresisC || (hotOk && point.Hotspot > hotTarget + HysteresisC)
                || (memOk && point.Memory > memTarget + HysteresisC);
            bool heatLimited = warn || rapidRise || (aboveTarget && (ambient >= 38 || r.MaintenanceSuggested
                || (r.CaseResistanceCPerW.HasValue && r.CaseResistanceCPerW.Value >= 0.04)
                || point.Other >= Math.Max(50, point.Power * 0.5) || r.DiminishingFanReturns));
            r.ReduceWorkload = heatLimited;
            if (!m.CalibrationComplete || r.Confidence < 0.75)
            {
                reasons.Add("Observation/calibration incomplete or confidence too low; numeric recommendations withheld.");
                return Finish(r, reasons, m.ObservedSeconds < 60 ? ControlState.Observing : ControlState.Calibrating);
            }
            // Only the comfort branch uses filtering. Raw temperatures already passed the safety branch.
            if (double.IsNaN(m.VirtualFan)) { m.VirtualFan = Clamp(fan, profile.FanMinPercent, profile.FanMaxPercent); m.FilteredCore = point.Core; m.LastFanChange = now; }
            double filterMove = (point.Core - m.FilteredCore) * (1 - Math.Exp(-advance / 10));
            m.FilteredCore += Clamp(filterMove, -0.5 * advance, 0.5 * advance);
            double error = Math.Max(m.FilteredCore - coreTarget, Math.Max(hotOk ? point.Hotspot - hotTarget : -100, memOk ? point.Memory - memTarget : -100));
            bool belowTarget = point.Core < coreTarget - HysteresisC && (!hotOk || point.Hotspot < hotTarget - HysteresisC)
                && (!memOk || point.Memory < memTarget - HysteresisC);
            m.CoolSeconds = belowTarget && !rapidRise ? m.CoolSeconds + advance : 0;
            bool wasHot = m.State == ControlState.HeatLimited || m.State == ControlState.Cooldown;
            bool cooldown = wasHot && !heatLimited && m.CoolSeconds < SoakSeconds;
            // Hysteresis holds the previous simulated speed inside the dead band.
            double desired = m.VirtualFan;
            double acoustic = Clamp(profile.AcousticPreferencePercent, profile.FanMinPercent, profile.FanMaxPercent);
            if (warn) desired = profile.FanMaxPercent;
            else if (error > HysteresisC || rapidRise)
            {
                desired = Math.Min(acoustic, m.VirtualFan + 5);
                if (r.DiminishingFanReturns && !rapidRise) desired = m.VirtualFan;
                desired = Math.Max(m.VirtualFan, desired);
            }
            else if (belowTarget && !cooldown && m.CoolSeconds >= SoakSeconds && m.StableSeconds >= SoakSeconds)
                desired = Math.Max(profile.FanMinPercent, m.VirtualFan - 2);
            bool up = desired > m.VirtualFan;
            double dwell = up ? 30 : 60;
            if (now - m.LastFanChange >= dwell && desired != m.VirtualFan)
            {
                double delta = desired - m.VirtualFan;
                delta = Clamp(delta, -Math.Min(2, FanFallPercentPerSecond * advance), Math.Min(5, FanRisePercentPerSecond * advance));
                m.VirtualFan = Clamp(m.VirtualFan + delta, profile.FanMinPercent, profile.FanMaxPercent); m.LastFanChange = now;
            }
            r.FanPercent = m.VirtualFan;
            if (heatLimited && loaded)
            {
                double caseR = r.CaseResistanceCPerW.GetValueOrDefault(0);
                double budget = Budget(point.Core, coreTarget - 2, point, caseR);
                if (hotOk) budget = Math.Min(budget, Budget(point.Hotspot, hotTarget - 2, point, caseR));
                if (memOk) budget = Math.Min(budget, Budget(point.Memory, memTarget - 2, point, caseR));
                // Always suggest a real reduction relative to both measured draw and the current cap.
                double candidate = Math.Min(budget * 0.85, Math.Min(point.Power * 0.9, s.CurrentPowerLimitW.Value * 0.9));
                r.TargetInfeasibleAtMinimumPower = candidate < profile.PowerMinW;
                double bounded = Clamp(candidate, profile.PowerMinW, Math.Min(profile.PowerMaxW, s.CurrentPowerLimitW.Value));
                if (bounded < s.CurrentPowerLimitW.Value) r.PowerLimitW = Math.Floor(bounded * 10) / 10;
                if (r.PowerLimitW.HasValue && r.PowerLimitW.Value < profile.PowerMinW) r.PowerLimitW = profile.PowerMinW;
                if (r.TargetInfeasibleAtMinimumPower)
                {
                    r.StopWorkload = warn;
                    reasons.Add("Estimated target requires power below the vendor minimum; reduce/stop work or improve room/case cooling.");
                }
                reasons.Add("Power budget is a conservative local estimate, not a guarantee; re-observe after any external change.");
            }
            if (cooldown) reasons.Add("Heat-soak cooldown: hold fan until all supported temperatures remain below target for 120 seconds.");
            return Finish(r, reasons, heatLimited ? ControlState.HeatLimited : cooldown ? ControlState.Cooldown : ControlState.Tracking);
        }

        private static double Budget(double temperature, double target, Plateau p, double caseR)
        {
            // With no inlet, caseR=0 gives an effective same-operating-point ratio only.
            double gpuR = Math.Max(0.001, (temperature - p.Inlet) / p.Power);
            return Math.Max(0, (target - p.Ambient - caseR * p.Other) / (gpuR + caseR));
        }
        private static bool IsLoaded(double power, double maxPower) { return power >= Math.Max(30, maxPower * 0.15); }
        private static void AddDistinctLevel(List<double> levels, double candidate)
        {
            foreach (double level in levels) if (Math.Abs(level - candidate) < 10) return;
            levels.Add(candidate);
        }
    }
}
