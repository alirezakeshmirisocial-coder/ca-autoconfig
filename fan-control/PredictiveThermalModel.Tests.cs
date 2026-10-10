using System;
using System.Collections.Generic;
using CA.FanControl;

namespace CA.FanControlTests
{
    public static class PredictiveTests
    {
        private static readonly List<string> Passed = new List<string>();
        private static void Assert(bool c, string message) { if (!c) throw new Exception(message); }
        private static void Case(string name, Action test) { test(); Passed.Add("PASS predictive: " + name); }
        private static void Near(double a, double b, double tolerance, string message) { Assert(Math.Abs(a - b) <= tolerance, message + ": " + a + " vs " + b); }
        private static DeviceProfile Profile()
        {
            return new DeviceProfile { EvidenceKey = "synthetic-predictive-v2", Model = "Synthetic RC plant, not hardware",
                LimitsVerified = true, FanCount = 2, FanMinPercent = 30, FanMaxPercent = 90,
                CoreLimitC = 95, HotspotLimitC = 110, MemoryLimitC = 110, HotspotExpected = true, MemoryExpected = true,
                PowerMinW = 100, PowerMaxW = 350 };
        }
        private static double Resistance(int channel, double fan)
        {
            // Independent two-segment ground truth, not the fitter or interpolator under test.
            double[][] values = { new[] { 0.12, 0.09, 0.065 }, new[] { 0.16, 0.12, 0.095 }, new[] { 0.14, 0.11, 0.09 } };
            int segment = fan <= 60 ? 0 : 1;
            return values[channel][segment] + (values[channel][segment + 1] - values[channel][segment]) * (fan - (40 + 20 * segment)) / 20;
        }
        private static double Eq(int channel, ThermalSample s)
        {
            double[] offset = { 2, 4, 3 }, coupling = { 0.015, 0.02, 0.02 };
            return s.Ambient + offset[channel] + Resistance(channel, s.Fan) * s.Power + coupling[channel] * s.Other;
        }
        private static List<ThermalSample> Trace(double ambient, bool constantOther = false)
        {
            List<ThermalSample> data = new List<ThermalSample>();
            double[] temperatures = new double[3], taus = { 40, 60, 90 };
            ThermalSample prior = new ThermalSample { Ambient = ambient, Fan = 60, Power = 200, Other = 150 };
            for (int j = 0; j < 3; j++) temperatures[j] = Eq(j, prior);
            double[] powers = { 140, 220, 280, 180 }, others = { 0, 150, 300 };
            for (double t = 0; t <= 2520; t += 2)
            {
                if (t > 0) for (int j = 0; j < 3; j++) temperatures[j] = Eq(j, prior) + (temperatures[j] - Eq(j, prior)) * Math.Exp(-2 / taus[j]);
                ThermalSample s = new ThermalSample { Time = t, Ambient = ambient, Fan = 60, Power = 200, Other = 150,
                    Core = temperatures[0], Hotspot = temperatures[1], Memory = temperatures[2], HasHotspot = true, HasMemory = true };
                if (t >= 420)
                {
                    s.Fan = 40 + 20 * ((int)((t - 420) / 150) % 3);
                    s.Power = powers[(int)((t - 420) / 60) % powers.Length];
                    s.Other = others[(int)((t - 420) / 110) % others.Length];
                    if (constantOther) s.Other = 150;
                }
                data.Add(s); prior = s;
            }
            return data;
        }
        private static Reading R(double v, double t) { return new Reading(v, t); }
        private static Snapshot SnapshotOf(ThermalSample s)
        {
            return new Snapshot { NowSeconds = s.Time, CoreC = R(s.Core, s.Time), HotspotC = s.HasHotspot ? R(s.Hotspot, s.Time) : null,
                MemoryC = s.HasMemory ? R(s.Memory, s.Time) : null, ManualAmbientC = R(s.Ambient, s.Time),
                InletC = R(s.Ambient + 0.02 * (s.Power + s.Other), s.Time), BoardPowerW = R(s.Power, s.Time),
                CurrentPowerLimitW = R(300, s.Time), OtherHeatW = R(s.Other, s.Time), Fans = new[] {
                    new FanReading { IntendedPercent = R(s.Fan, s.Time), Rpm = R(1600, s.Time), RpmIsPhysical = true },
                    new FanReading { IntendedPercent = R(s.Fan, s.Time), Rpm = R(1600, s.Time), RpmIsPhysical = true } } };
        }
        private static Recommendation Replay(DeviceProfile p, List<ThermalSample> trace)
        {
            Recommendation r = null;
            foreach (ThermalSample s in trace)
            {
                r = AdaptiveFanPolicy.Evaluate(p, SnapshotOf(s), r == null ? null : r.Next);
                Assert(!r.CanApply, "Public path must stay simulation only.");
                if (!r.Next.CalibrationComplete && r.State != ControlState.Emergency) Assert(!r.FanPercent.HasValue && !r.PowerLimitW.HasValue, "No numeric advice before identification.");
                if (r.FanPercent.HasValue) Assert(r.FanPercent >= p.FanMinPercent && r.FanPercent <= p.FanMaxPercent, "Fan bounds.");
                if (r.PowerLimitW.HasValue) Assert(r.PowerLimitW >= p.PowerMinW && r.PowerLimitW <= 300, "Power bounds and existing cap.");
            }
            return r;
        }
        public static string[] RunAll()
        {
            Passed.Clear(); List<ThermalSample> training = Trace(25);
            CalibrationReport accepted = ThermalIdentification.Fit(Profile().EvidenceKey, training);
            Case("recover known RC plant and independent junction dynamics", delegate {
                Assert(accepted.Accepted, accepted.Detail);
                Near(accepted.CoreTimeConstantSeconds, 40, 0, "Recover core time constant");
                Near(accepted.Model.Channels[1].Tau, 60, 0, "Recover hotspot time constant");
                Near(accepted.Model.Channels[2].Tau, 90, 0, "Recover memory time constant");
                Near(accepted.Model.Channels[0].Coupling, 0.015, 0.00001, "Identify neighbor coupling");
                Assert(accepted.ValidationRmseC < 0.001 && accepted.ValidationMaxErrorC < 0.001, "Held-out free-run accuracy for exact RC data.");
            });
            Case("interpolation stays monotone, bounded and exact at knots", delegate {
                ThermalChannel c = accepted.Model.Channels[0];
                for (double u = 40; u <= 80; u += 0.25) Near(c.Resistance(u), Resistance(0, u), 0.00001, "Interpolated resistance");
                bool threw = false; try { c.Resistance(90); } catch (ArgumentOutOfRangeException) { threw = true; }
                Assert(threw, "A cubic/linear extrapolation must never invent cooling outside observed fans.");
            });
            Case("elapsed time and a flat trace are not calibration", delegate {
                List<ThermalSample> flat = new List<ThermalSample>();
                for (int i = 0; i < 700; i++) { ThermalSample s = training[0]; s.Time = i * 2; flat.Add(s); }
                CalibrationReport r = ThermalIdentification.Fit("flat", flat);
                Assert(!r.Accepted && r.Detail.Contains("fan coverage"), "Flat data cannot identify fan response.");
                Recommendation policy = Replay(Profile(), flat);
                Assert(policy.Next.ObservationComplete && !policy.Next.CalibrationComplete && !policy.FanPercent.HasValue,
                    "Public API must separate a stable observation from model calibration.");
            });
            Case("confounded neighbor power is rejected", delegate {
                List<ThermalSample> correlated = new List<ThermalSample>();
                foreach (ThermalSample point in training) { ThermalSample s = point; s.Other = 2 * s.Power; correlated.Add(s); }
                CalibrationReport r = ThermalIdentification.Fit("correlated", correlated);
                Assert(!r.Accepted, "Rank-deficient power/coupling inputs cannot produce a trusted model.");
            });
            Case("held-out corruption cannot be hidden by fitting", delegate {
                List<ThermalSample> changed = new List<ThermalSample>(training);
                int split = (int)(changed.Count * 0.7);
                for (int i = split; i < changed.Count; i++) { ThermalSample s = changed[i]; s.Memory += 8; changed[i] = s; }
                CalibrationReport r = ThermalIdentification.Fit("changed", changed);
                Assert(!r.Accepted, "An accurate training fit must fail on inaccurate held-out memory predictions.");
            });
            Case("outlier resistance does not weaken validation limits", delegate {
                List<ThermalSample> noisy = new List<ThermalSample>(training);
                ThermalSample point = noisy[350]; point.Core += 1.5; noisy[350] = point;
                CalibrationReport r = ThermalIdentification.Fit("noisy", noisy);
                Assert(r.Accepted && r.ValidationMaxErrorC < 1, r.Detail);
                Near(r.CoreTimeConstantSeconds, 40, 0, "Sparse training spike should not alter selected time constant.");
            });
            Case("cold-room model refuses hot-room extrapolation", delegate {
                Assert(!accepted.Model.Supports(40, 60, 220, 150), "Ambient change must collect new evidence.");
                Assert(!accepted.Model.Supports(25, 60, 350, 150), "Unknown power range rejected.");
                Assert(!accepted.Model.Supports(25, 60, 220, 700), "Unknown multi-GPU heat rejected.");
            });
            Case("quantized temperature telemetry retains bounded held-out predictions", delegate {
                List<ThermalSample> quantized = new List<ThermalSample>(training);
                for (int i = 0; i < quantized.Count; i++)
                {
                    ThermalSample s = quantized[i]; s.Core = Math.Round(s.Core); s.Hotspot = Math.Round(s.Hotspot);
                    s.Memory = Math.Round(s.Memory); quantized[i] = s;
                }
                CalibrationReport r = ThermalIdentification.Fit("quantized", quantized);
                Assert(r.Accepted, "Integer telemetry: " + r.Detail);
                Assert(r.ValidationRmseC < 2 && r.ValidationMaxErrorC < 4, "Quantized measurements still need accurate free-run predictions.");
            });
            Case("unexcited neighbor heat stays fixed in the calibration domain", delegate {
                CalibrationReport r = ThermalIdentification.Fit("fixed-other", Trace(25, true));
                Assert(r.Accepted, r.Detail);
                Near(r.Model.Channels[0].Coupling, 0, 0, "Do not invent an unidentified coupling coefficient");
                Assert(r.Model.Supports(25, 60, 220, 150) && !r.Model.Supports(25, 60, 220, 300), "A fixed-neighbor model cannot predict a newly active second GPU.");
            });
            Case("optimizer accounts for 40 C ambient and vendor bounds", delegate {
                CalibrationReport hot = ThermalIdentification.Fit("hot", Trace(40)); Assert(hot.Accepted, hot.Detail);
                ThermalSample coolNow = training[0]; coolNow.Fan = 40; coolNow.Power = 220; coolNow.Other = 150;
                coolNow.Core = Eq(0, coolNow); coolNow.Hotspot = Eq(1, coolNow); coolNow.Memory = Eq(2, coolNow);
                ThermalSample hotNow = coolNow; hotNow.Ambient = 40;
                hotNow.Core = Eq(0, hotNow); hotNow.Hotspot = Eq(1, hotNow); hotNow.Memory = Eq(2, hotNow);
                double[] limits = { 78, 93, 89 };
                PredictiveChoice coldChoice = PredictiveOptimization.Choose(accepted.Model, Profile(), coolNow, 300, 40, 40, 42, limits);
                PredictiveChoice hotChoice = PredictiveOptimization.Choose(hot.Model, Profile(), hotNow, 300, 40, 40, 42, limits);
                Assert(coldChoice != null && hotChoice != null, "Feasible candidates should be found.");
                Assert(hotChoice.Power < coldChoice.Power && hotChoice.Fan <= 42, "Hot room should favor less heat within the reachable fan envelope.");
                Assert(hotChoice.CoreUpper <= limits[0] && hotChoice.HotspotUpper <= limits[1] && hotChoice.MemoryUpper <= limits[2], "Every junction envelope must be feasible.");
                Assert(hotChoice.Power >= Profile().PowerMinW, "Vendor minimum respected.");
            });
            Case("no feasible point yields no fabricated solution", delegate {
                ThermalSample now = training[0]; now.Core = 79;
                PredictiveChoice choice = PredictiveOptimization.Choose(accepted.Model, Profile(), now, 300, 60, 60, 62, new[] { 78.0, 93, 89 });
                Assert(choice == null, "Time-zero upper bound already violates ceiling; cannot claim a solution.");
            });
            Case("public integration identifies before enabling advice", delegate {
                Recommendation r = Replay(Profile(), training);
                Assert(r.Next.ObservationComplete && r.Next.CalibrationComplete && r.Calibration.Accepted, "Calibration: " + string.Join(" | ", r.Reasons));
                Assert(r.FanPercent.HasValue && r.ForecastCoreUpperC.HasValue && r.OptimizationCost.HasValue, "Public advice includes tested predictions and objective.");
                Assert(r.ModelConfidence >= 0.75 && r.ModelConfidence <= 0.95, "Evidence score bounded.");
            });
            Case("drift revokes calibration before renewed optimization", delegate {
                DeviceProfile p = Profile(); Recommendation r = Replay(p, training);
                ThermalSample last = training[training.Count - 1]; bool revoked = false;
                // A persistent 6 C sensor/thermal-model discrepancy is under emergency ceilings, but fails the learned envelope.
                for (int i = 1; i <= 20; i++)
                {
                    ThermalSample s = last; s.Time += i * 2; s.Core += 6; s.Hotspot += 6;
                    r = AdaptiveFanPolicy.Evaluate(p, SnapshotOf(s), r.Next);
                    if (!r.Next.CalibrationComplete) revoked = true;
                }
                Assert(revoked && !r.FanPercent.HasValue, "Sustained model drift must remove numeric advice.");
            });
            Case("public emergency remains immediate before identification", delegate {
                ThermalSample s = training[0]; s.Core = 90; s.Hotspot = 100;
                Recommendation r = AdaptiveFanPolicy.Evaluate(Profile(), SnapshotOf(s), null);
                Assert(r.State == ControlState.Emergency && r.StopWorkload && !r.FanPercent.HasValue, "No calibration wait for emergency alarms.");
            });
            Case("public repeated evaluation is deterministic and pure", delegate {
                DeviceProfile p = Profile(); Recommendation r = Replay(p, training);
                ThermalSample next = training[training.Count - 1]; next.Time += 2;
                int count = r.Next.Samples.Count; double prediction = r.Next.DriftPrediction[0];
                Recommendation a = AdaptiveFanPolicy.Evaluate(p, SnapshotOf(next), r.Next), b = AdaptiveFanPolicy.Evaluate(p, SnapshotOf(next), r.Next);
                Assert(a.FanPercent == b.FanPercent && a.PowerLimitW == b.PowerLimitW && a.OptimizationCost == b.OptimizationCost, "Same inputs, same solution.");
                Assert(r.Next.Samples.Count == count && r.Next.DriftPrediction[0] == prediction, "Calibration history and drift state must be copied.");
            });
            Case("public calibrated emergency overrides optimization", delegate {
                DeviceProfile p = Profile(); Recommendation r = Replay(p, training);
                ThermalSample s = training[training.Count - 1]; s.Time += 2; s.Core = 90; s.Hotspot = 100;
                r = AdaptiveFanPolicy.Evaluate(p, SnapshotOf(s), r.Next);
                Assert(r.State == ControlState.Emergency && r.StopWorkload && r.FanPercent == p.FanMaxPercent,
                    "An emergency must override interpolation bounds and normal fan slew with the verified vendor maximum.");
                Assert(!r.Next.CalibrationComplete && r.Next.ThermalModel == null && !r.PowerLimitW.HasValue, "Emergency revokes normal predictive advice.");
            });
            Case("public sensor loss removes fitted model and forecasts", delegate {
                DeviceProfile p = Profile(); Recommendation r = Replay(p, training);
                ThermalSample s = training[training.Count - 1]; s.Time += 2; Snapshot snapshot = SnapshotOf(s); snapshot.MemoryC = null;
                r = AdaptiveFanPolicy.Evaluate(p, snapshot, r.Next);
                Assert(r.State == ControlState.SensorFault && !r.Next.CalibrationComplete && r.Next.ThermalModel == null
                    && !r.FanPercent.HasValue && !r.ForecastCoreUpperC.HasValue, "Fault state cannot carry a stale prediction into the UI.");
            });
            return Passed.ToArray();
        }
    }
}
