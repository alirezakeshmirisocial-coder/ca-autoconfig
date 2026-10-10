using System;
using System.Collections.Generic;
using CA.FanControl;

namespace CA.FanControlTests
{
    // Synthetic boards and temperatures only. No real GPU is queried or configured.
    public static class PolicyTests
    {
        private static readonly List<string> Passed = new List<string>();
        private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
        private static void Near(double actual, double expected, double tolerance, string message)
        { Assert(Math.Abs(actual - expected) <= tolerance, message + " (actual " + actual + ", expected " + expected + ")"); }
        private static void Case(string name, Action test) { test(); Passed.Add("PASS " + name); }
        private static DeviceProfile Profile()
        {
            return new DeviceProfile { EvidenceKey = "synthetic-board-driver-topology-v1", Model = "Synthetic test GPU (not a hardware profile)",
                LimitsVerified = true, FanCount = 2, FanMinPercent = 30, FanMaxPercent = 90,
                CoreLimitC = 95, HotspotLimitC = 110, MemoryLimitC = 110, HotspotExpected = true, MemoryExpected = true,
                PowerMinW = 100, PowerMaxW = 350 };
        }
        private static Reading R(double value, double t) { return new Reading(value, t); }
        private static Snapshot Sample(double t, double core, double ambient, double inlet, double other, double fan)
        {
            return new Snapshot { NowSeconds = t, CoreC = R(core, t), HotspotC = R(82, t), MemoryC = R(84, t),
                BoardPowerW = R(250, t), CurrentPowerLimitW = R(300, t), ManualAmbientC = R(ambient, t),
                InletC = R(inlet, t), OtherHeatW = R(other, t), Fans = new[] {
                    new FanReading { IntendedPercent = R(fan, t), Rpm = R(fan == 0 ? 0 : 1600, t), RpmIsPhysical = true },
                    new FanReading { IntendedPercent = R(fan, t), Rpm = R(fan == 0 ? 0 : 1600, t), RpmIsPhysical = true } } };
        }
        private static Snapshot Normal(double t) { return Sample(t, 70, 25, 30, 0, 60); }
        private static Recommendation Run(DeviceProfile p, Func<double, Snapshot> sample, double end, Memory initial, double start)
        {
            Memory m = initial; Recommendation r = null;
            for (double t = start; t <= end; t += 2)
            {
                r = AdaptiveFanPolicy.Evaluate(p, sample(t), m); m = r.Next;
                Assert(!r.CanApply && r.VendorAutoRecommended, "Simulation may never authorize an application.");
                if (r.FanPercent.HasValue) Assert(r.FanPercent >= p.FanMinPercent && r.FanPercent <= p.FanMaxPercent, "Vendor fan bounds.");
                if (r.PowerLimitW.HasValue) Assert(r.PowerLimitW >= p.PowerMinW && r.PowerLimitW <= p.PowerMaxW, "Vendor power bounds.");
            }
            return r;
        }
        private static Recommendation Ready(DeviceProfile p) { return Run(p, Normal, 320, null, 0); }

        public static string[] RunAll()
        {
            Passed.Clear();
            Case("normal ambient: calibration gate and steady recommendation", delegate {
                DeviceProfile p = Profile();
                Recommendation early = Run(p, Normal, 298, null, 0);
                Assert(!early.Next.CalibrationComplete && !early.FanPercent.HasValue, "No numeric fan before 300 seconds.");
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, Normal(300), early.Next);
                Assert(r.Next.CalibrationComplete && r.State == ControlState.Tracking, "Stable warm observation should calibrate.");
                Near(r.FanPercent.Value, 60, 0.001, "Dead band holds fan.");
                Near(r.CaseResistanceCPerW.Value, 0.02, 0.0001, "Case estimate uses inlet and total power.");
                Assert(r.Confidence >= 0.75 && !r.PowerLimitW.HasValue, "Normal operation should not request power reduction.");
            });
            Case("40 C ambient: power reduction without futile maximum fan", delegate {
                DeviceProfile p = Profile();
                Recommendation r = Run(p, delegate(double t) { return Sample(t, 79, 40, 45, 0, 65); }, 340, null, 0);
                Assert(r.State == ControlState.HeatLimited && r.ReduceWorkload, "Hot-room cooling headroom.");
                Assert(r.PowerLimitW.HasValue && r.PowerLimitW < 220, "Power estimate must decrease heat at 40 C.");
                Assert(r.FanPercent < p.FanMaxPercent && r.AmbientC == 40, "Hot ambient alone must not force maximum fan.");
            });
            Case("poor ventilation: identify case resistance", delegate {
                DeviceProfile p = Profile();
                Recommendation r = Run(p, delegate(double t) { return Sample(t, 78, 25, 42, 0, 65); }, 320, null, 0);
                Assert(r.State == ControlState.HeatLimited && r.PowerLimitW.HasValue, "Poor ventilation needs heat reduction advice.");
                Near(r.CaseResistanceCPerW.Value, 17.0 / 250, 0.0001, "Case resistance is distinct from effective resistance.");
            });
            Case("dust/degradation: sustained comparable baseline only", delegate {
                DeviceProfile p = Profile(); p.CleanBaseline = new CleanReference { EffectiveResistanceCPerW = 0.14,
                    AmbientC = 25, FanPercent = 60, BoardPowerW = 250, OtherHeatW = 0 };
                Recommendation r = Run(p, delegate(double t) { return Sample(t, 77, 25, 31, 0, 60); }, 320, null, 0);
                Assert(r.MaintenanceSuggested && r.PowerLimitW.HasValue, "Sustained higher resistance should recommend inspection and less heat.");
                p.CleanBaseline.FanPercent = 90;
                r = Run(p, delegate(double t) { return Sample(t, 77, 25, 31, 0, 60); }, 320, null, 0);
                Assert(!r.MaintenanceSuggested, "Different fan settings cannot diagnose dust.");
            });
            Case("dual-GPU heat coupling and soak", delegate {
                DeviceProfile p = Profile();
                Recommendation transient = Run(p, delegate(double t) {
                    double rise = Math.Min(9, t / 40); return Sample(t, 70 + rise, 25, 35 + rise, 350, 65);
                }, 300, null, 0);
                Assert(!transient.Next.CalibrationComplete, "Slow shared heat soak must not be mistaken for equilibrium.");
                Recommendation r = Run(p, delegate(double t) { return Sample(t, 79, 25, 44, 350, 65); }, 500, transient.Next, 302);
                Assert(r.Next.CalibrationComplete && r.State == ControlState.HeatLimited && r.PowerLimitW.HasValue, "Dual-GPU heat must affect advice.");
                Near(r.CaseResistanceCPerW.Value, 19.0 / 600, 0.0001, "Other GPU heat must appear in denominator.");
            });
            Case("sensor loss: fallback and full re-observation", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); Snapshot broken = Normal(322); broken.CoreC = null;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, broken, ready.Next);
                Assert(r.State == ControlState.SensorFault && !r.FanPercent.HasValue && !r.Next.CalibrationComplete, "Missing core fails closed.");
                r = Run(p, Normal, 440, r.Next, 324);
                Assert(r.State == ControlState.SensorFault, "Recovery requires a healthy cooldown.");
                r = Run(p, Normal, 460, r.Next, 442);
                Assert(!r.Next.CalibrationComplete && !r.FanPercent.HasValue, "Recovery cannot skip five-minute re-observation.");
            });
            Case("stale optional junction telemetry is not silently ignored", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); Snapshot s = Normal(322); s.MemoryC.AtSeconds = 310;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(r.State == ControlState.SensorFault && !r.FanPercent.HasValue, "Stale VRAM must cause fallback.");
            });
            Case("physical fan stall: latch, stop load, no useless fan command", delegate {
                DeviceProfile p = Profile(); Recommendation r = Ready(p);
                r = Run(p, delegate(double t) { Snapshot s = Normal(t); s.Fans[1].Rpm.Value = 0; return s; }, 334, r.Next, 322);
                Assert(r.State == ControlState.FanFault && r.StopWorkload && !r.FanPercent.HasValue, "One stalled fan is enough.");
                r = Run(p, Normal, 480, r.Next, 336);
                Assert(r.State == ControlState.FanFault, "A fault requires acknowledgement even after tach recovery.");
                Snapshot good = Normal(482); good.AcknowledgeFault = true;
                r = AdaptiveFanPolicy.Evaluate(p, good, r.Next);
                Assert(r.State == ControlState.Observing && !r.Next.CalibrationComplete, "Acknowledgement restarts calibration.");
            });
            Case("zero-RPM idle is not a stall", delegate {
                DeviceProfile p = Profile();
                Recommendation r = Run(p, delegate(double t) {
                    Snapshot s = Sample(t, 40, 25, 27, 0, 0); s.HotspotC.Value = 48; s.MemoryC.Value = 45; s.BoardPowerW.Value = 20; return s;
                }, 320, null, 0);
                Assert(r.State != ControlState.FanFault && !r.Next.CalibrationComplete, "Zero RPM idle is allowed but cannot calibrate a load model.");
            });
            Case("intended RPM cannot substitute for physical tachometry", delegate {
                DeviceProfile p = Profile();
                Recommendation r = Run(p, delegate(double t) { Snapshot s = Normal(t); s.Fans[0].RpmIsPhysical = false; return s; }, 400, null, 0);
                Assert(!r.Next.CalibrationComplete && !r.FanPercent.HasValue && r.Confidence <= 0.6, "Intended RPM must not pass health gate.");
            });
            Case("core emergency overrides dwell and ramp, respects vendor maximum", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); Snapshot s = Normal(322); s.CoreC.Value = 86; s.HotspotC.Value = 95;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(r.State == ControlState.Emergency && r.StopWorkload, "Core emergency immediate.");
                Near(r.FanPercent.Value, p.FanMaxPercent, 0, "Emergency simulated fan bypasses ramp.");
                s = Normal(324); s.CoreC = null; r = AdaptiveFanPolicy.Evaluate(p, s, r.Next);
                Assert(r.State == ControlState.Emergency && r.StopWorkload && !r.FanPercent.HasValue, "Sensor loss cannot dismiss emergency.");
            });
            Case("hotspot and VRAM each independently trigger emergency", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); Snapshot s = Normal(322); s.HotspotC.Value = 100;
                Assert(AdaptiveFanPolicy.Evaluate(p, s, ready.Next).State == ControlState.Emergency, "Hotspot independent of core.");
                s = Normal(322); s.MemoryC.Value = 96;
                Assert(AdaptiveFanPolicy.Evaluate(p, s, ready.Next).State == ControlState.Emergency, "VRAM independent of core.");
            });
            Case("emergency alarms do not wait for calibration", delegate {
                DeviceProfile p = Profile(); Snapshot s = Normal(0); s.CoreC.Value = 87;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, null);
                Assert(r.State == ControlState.Emergency && r.StopWorkload && !r.FanPercent.HasValue, "Alert immediately, withhold uncalibrated numeric advice.");
            });
            Case("vendor thermal threshold always tightens application guard", delegate {
                DeviceProfile p = Profile(); p.CoreLimitC = 78; Snapshot s = Normal(0); s.CoreC.Value = 75;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, null);
                Near(r.CoreEmergencyC, 75, 0, "Vendor limit minus margin.");
                Assert(r.State == ControlState.Emergency, "Lower vendor ceiling has priority.");
            });
            Case("unknown limits stay in vendor auto", delegate {
                DeviceProfile p = Profile(); p.LimitsVerified = false;
                Recommendation r = Run(p, Normal, 400, null, 0);
                Assert(r.State == ControlState.VendorAuto && !r.FanPercent.HasValue, "Unverified model cannot produce setpoints.");
            });
            Case("temperature rise guard uses raw sensors", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); Snapshot s = Normal(322); s.CoreC.Value = 73;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(r.CoreRiseCPerSecond > 0.5 && r.State == ControlState.HeatLimited && r.ReduceWorkload, "Rapid heating must bypass comfort filtering.");
            });
            Case("fan hysteresis, dwell and slew boundaries", delegate {
                DeviceProfile p = Profile(); Recommendation r = Ready(p); double lastFan = r.FanPercent.Value;
                for (double t = 322; t <= 420; t += 2)
                {
                    Snapshot s = Normal(t); s.CoreC.Value = t % 4 == 0 ? 71 : 72;
                    Recommendation next = AdaptiveFanPolicy.Evaluate(p, s, r.Next);
                    Near(next.FanPercent.Value, lastFan, 0, "Noise within hysteresis must not chatter."); r = next;
                }
                r = AdaptiveFanPolicy.Evaluate(p, Sample(422, 76, 25, 30, 0, 60), r.Next);
                Assert(r.FanPercent.Value - lastFan <= 2, "Two seconds permits at most two percentage points upward.");
                lastFan = r.FanPercent.Value;
                r = AdaptiveFanPolicy.Evaluate(p, Sample(424, 76, 25, 30, 0, 60), r.Next);
                Near(r.FanPercent.Value, lastFan, 0, "30-second upward dwell.");
            });
            Case("ambient sensor conflict and manual expiry", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); Snapshot s = Normal(322); s.AmbientSensorC = R(40, 322); s.InletC.Value = 42;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(r.AmbientC == 40 && !r.FanPercent.HasValue && r.Confidence < 0.75, "Disagreeing ambient sources block numeric advice.");
                s = Normal(4000); s.ManualAmbientC.AtSeconds = 0;
                r = AdaptiveFanPolicy.Evaluate(p, s, null);
                Assert(r.State == ControlState.SensorFault, "Manual room reading expires instead of becoming an evergreen fact.");
            });
            Case("missing inlet cannot fabricate a case resistance", delegate {
                DeviceProfile p = Profile(); Recommendation r = Run(p, delegate(double t) { Snapshot s = Normal(t); s.InletC = null; return s; }, 320, null, 0);
                Assert(r.EffectiveResistanceCPerW.HasValue && !r.CaseResistanceCPerW.HasValue, "Core/ambient yields combined resistance only.");
            });
            Case("unsupported junction sensors lower confidence", delegate {
                DeviceProfile p = Profile(); p.HotspotExpected = false; p.MemoryExpected = false;
                Recommendation r = Run(p, delegate(double t) { Snapshot s = Normal(t); s.HotspotC = null; s.MemoryC = null; return s; }, 320, null, 0);
                Assert(r.Confidence < 0.9 && r.Confidence >= 0.75, "Unsupported sensors remain explicitly uncertain.");
            });
            Case("NaN, infinity, stale and future readings fail closed", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p);
                double[] bad = { double.NaN, double.PositiveInfinity, -100, 999 };
                foreach (double value in bad)
                {
                    Snapshot s = Normal(322); s.CoreC.Value = value;
                    Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                    Assert(r.State == ControlState.SensorFault && !r.FanPercent.HasValue, "Invalid temperature rejected.");
                }
                Snapshot future = Normal(322); future.CoreC.AtSeconds = 323;
                Assert(AdaptiveFanPolicy.Evaluate(p, future, ready.Next).State == ControlState.SensorFault, "Future sensor timestamp rejected.");
            });
            Case("clock gaps and cached samples invalidate calibration", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p);
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, Normal(340), ready.Next);
                Assert(r.State == ControlState.SensorFault && !r.Next.CalibrationComplete, "Long polling gap invalidates model.");
                Snapshot s = Normal(322); s.CoreC.AtSeconds = 320;
                r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(r.State == ControlState.SensorFault, "Replayed sample cannot count as observation.");
                r = AdaptiveFanPolicy.Evaluate(p, Normal(318), ready.Next);
                Assert(r.State == ControlState.SensorFault, "Clock cannot run backward.");
            });
            Case("power advice never increases an existing low cap", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p);
                Snapshot s = Sample(322, 79, 40, 45, 0, 65); s.CurrentPowerLimitW.Value = 120;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(r.PowerLimitW.HasValue && r.PowerLimitW <= 120 && r.PowerLimitW >= 100, "Existing lower cap must be respected.");
            });
            Case("thermal throttle is an immediate emergency", delegate {
                DeviceProfile p = Profile(); Snapshot s = Normal(0); s.ThermalThrottle = true;
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, null);
                Assert(r.State == ControlState.Emergency && r.StopWorkload, "Throttle is independent safety evidence.");
            });
            Case("deterministic replay leaves input memory unchanged", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); double before = ready.Next.ObservedSeconds;
                Snapshot s = Normal(322);
                Recommendation a = AdaptiveFanPolicy.Evaluate(p, s, ready.Next), b = AdaptiveFanPolicy.Evaluate(p, s, ready.Next);
                Assert(a.State == b.State && a.FanPercent == b.FanPercent && a.Confidence == b.Confidence, "Identical inputs produce identical advice.");
                Near(ready.Next.ObservedSeconds, before, 0, "Evaluation must not mutate caller memory.");
                Assert(!object.ReferenceEquals(a.Next, ready.Next), "Next state is separate from prior state.");
            });
            Case("device revision changes restart observation", delegate {
                DeviceProfile p = Profile(); Recommendation ready = Ready(p); p.EvidenceKey = "synthetic-revision-2";
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, Normal(322), ready.Next);
                Assert(!r.Next.CalibrationComplete && !r.FanPercent.HasValue, "Profile revision cannot reuse calibration.");
            });
            Case("confidence loss discards earlier calibration", delegate {
                DeviceProfile p = Profile(); Recommendation r = Ready(p); Snapshot s = Normal(322); s.BoardPowerW.Confidence = 0.6;
                r = AdaptiveFanPolicy.Evaluate(p, s, r.Next);
                Assert(!r.Next.CalibrationComplete && !r.FanPercent.HasValue, "Low confidence revokes numeric advice.");
                r = Run(p, Normal, 600, r.Next, 324);
                Assert(!r.Next.CalibrationComplete && !r.FanPercent.HasValue, "Good samples must accumulate a new full observation period.");
            });
            Case("loaded zero-RPM readings cannot pass calibration", delegate {
                DeviceProfile p = Profile(); Recommendation r = Run(p, delegate(double t) { return Sample(t, 70, 25, 30, 0, 0); }, 400, null, 0);
                Assert(!r.Next.CalibrationComplete && !r.FanPercent.HasValue && r.State != ControlState.FanFault,
                    "Unknown zero-fan behavior is not a proven stall or a proven cooling capability.");
            });
            Case("cooldown and slow downward fan ramp", delegate {
                DeviceProfile p = Profile(); Recommendation r = Run(p, delegate(double t) { return Sample(t, 79, 40, 45, 0, 65); }, 320, null, 0);
                double before = r.FanPercent.Value;
                Func<double, Snapshot> cool = delegate(double t) { Snapshot s = Sample(t, 60, 25, 30, 0, 65); s.HotspotC.Value = 75; s.MemoryC.Value = 75; return s; };
                r = Run(p, cool, 400, r.Next, 322);
                Assert(r.State == ControlState.Cooldown && r.FanPercent == before, "Residual heat needs a full cooldown before fan reduction.");
                r = Run(p, cool, 460, r.Next, 402);
                Assert(r.FanPercent < before && before - r.FanPercent <= 0.5, "Fan falls by no more than 0.25 percentage points/second.");
            });
            Case("diminishing fan returns need three distinct steady fan levels", delegate {
                DeviceProfile p = Profile();
                Func<double, Snapshot> trace = delegate(double t) {
                    double fan = t <= 320 ? 70 : t <= 620 ? 80 : 90;
                    return Sample(t, 76, 25, 30, 0, fan);
                };
                Recommendation r = Run(p, trace, 900, null, 0);
                Assert(r.DiminishingFanReturns && r.FanGainCPerPercent.HasValue && r.State == ControlState.HeatLimited,
                    "Three matched fan plateaus with no cooling gain should favor power reduction.");
                Assert(r.PowerLimitW.HasValue, "Diminishing cooling gain should produce a lower power budget.");
            });
            Case("vendor minimum power is never crossed when target infeasible", delegate {
                DeviceProfile p = Profile(); p.PowerMinW = 240;
                Recommendation r = Run(p, delegate(double t) { return Sample(t, 79, 40, 45, 0, 65); }, 320, null, 0);
                Assert(r.TargetInfeasibleAtMinimumPower && r.PowerLimitW == 240, "Infeasible budget must be disclosed and bounded.");
            });
            Case("emergency recovery requires cool dwell plus acknowledgement", delegate {
                DeviceProfile p = Profile(); Recommendation r = Ready(p); Snapshot s = Normal(322); s.MemoryC.Value = 96;
                r = AdaptiveFanPolicy.Evaluate(p, s, r.Next);
                r = Run(p, Normal, 450, r.Next, 324);
                Assert(r.State == ControlState.Emergency, "Cooling alone cannot dismiss an emergency.");
                p.EvidenceKey = "changed-during-incident";
                r = AdaptiveFanPolicy.Evaluate(p, Normal(452), r.Next);
                Assert(r.State == ControlState.Emergency, "A new configuration cannot dismiss an emergency.");
                r = Run(p, Normal, 580, r.Next, 454);
                s = Normal(582); s.AcknowledgeFault = true; r = AdaptiveFanPolicy.Evaluate(p, s, r.Next);
                Assert(r.State == ControlState.Observing && !r.Next.CalibrationComplete, "Acknowledged recovery restarts observation.");
            });
            Case("new ambient sensor can replace expired manual input", delegate {
                DeviceProfile p = Profile(); Snapshot s = Normal(4000); s.ManualAmbientC.AtSeconds = 0; s.AmbientSensorC = R(25, 4000);
                Recommendation r = AdaptiveFanPolicy.Evaluate(p, s, null);
                Assert(r.State == ControlState.Observing && r.AmbientC == 25, "A fresh ambient sensor provides an explicit fallback.");
            });
            Case("zero-RPM cannot clear a latched physical fan fault", delegate {
                DeviceProfile p = Profile(); Recommendation r = Ready(p);
                r = Run(p, delegate(double t) { Snapshot s = Normal(t); s.Fans[0].Rpm.Value = 0; return s; }, 334, r.Next, 322);
                r = Run(p, delegate(double t) {
                    Snapshot s = Sample(t, 40, 25, 27, 0, 0); s.BoardPowerW.Value = 20; s.HotspotC.Value = 48;
                    s.MemoryC.Value = 45; s.AcknowledgeFault = true; return s;
                }, 500, r.Next, 336);
                Assert(r.State == ControlState.FanFault && r.StopWorkload, "Fault recovery needs observed physical rotation.");
            });
            Case("confidence gate has a stable inclusive boundary", delegate {
                DeviceProfile p = Profile(); p.HotspotExpected = false; p.MemoryExpected = false;
                Recommendation r = Run(p, delegate(double t) {
                    Snapshot s = Normal(t); s.HotspotC = null; s.MemoryC = null; s.InletC = null; return s;
                }, 320, null, 0);
                Near(r.Confidence, 0.75, 0.000001, "Confidence deductions use a reproducible precision.");
                Assert(r.Next.CalibrationComplete && r.FanPercent.HasValue, "An exact 0.75 score passes the stated gate.");
            });
            return Passed.ToArray();
        }
    }
}
