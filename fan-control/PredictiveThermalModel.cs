// Deterministic, calibration-first modelling. No hardware or I/O APIs.
using System;
using System.Collections.Generic;

namespace CA.FanControl
{
    public sealed class CalibrationReport
    {
        public bool Accepted { get; internal set; }
        public string Detail { get; internal set; }
        public int TrainingIntervals { get; internal set; }
        public int ValidationIntervals { get; internal set; }
        public double ValidationRmseC { get; internal set; }
        public double ValidationMaxErrorC { get; internal set; }
        public double CoreTimeConstantSeconds { get; internal set; }
        public double EvidenceScore { get; internal set; }
        public double FanMinimum { get; internal set; }
        public double FanMaximum { get; internal set; }
        public double PowerMinimumW { get; internal set; }
        public double PowerMaximumW { get; internal set; }
        internal ThermalModel Model;
    }

    internal struct ThermalSample
    {
        public double Time, Ambient, Fan, Power, Other, Core, Hotspot, Memory;
        public bool HasHotspot, HasMemory;
        public double Temperature(int channel) { return channel == 0 ? Core : channel == 1 ? Hotspot : Memory; }
    }

    // Private arrays and no mutating methods: a fitted model can safely be shared by copied Memory.
    internal sealed class ThermalChannel
    {
        internal readonly double Tau, Offset, Coupling, Margin, Rmse, MaxError;
        private readonly double[] fans, resistances;
        internal ThermalChannel(double tau, double offset, double coupling, double[] knots, double[] resistance,
            double rmse, double maxError)
        {
            Tau = tau; Offset = offset; Coupling = coupling; fans = (double[])knots.Clone();
            resistances = (double[])resistance.Clone(); Rmse = rmse; MaxError = maxError;
            Margin = Math.Max(2, maxError + 1); // Empirical envelope plus sensor/model allowance; NOT a confidence interval.
        }
        internal double Resistance(double fan) { return PredictiveMath.Interpolate(fans, resistances, fan); }
        internal double Equilibrium(double ambient, double power, double other, double fan)
        { return ambient + Offset + Coupling * other + Resistance(fan) * power; }
        internal double Advance(double temperature, double seconds, double ambient, double power, double other, double fan)
        {
            double equilibrium = Equilibrium(ambient, power, other, fan);
            return equilibrium + (temperature - equilibrium) * Math.Exp(-seconds / Tau);
        }
    }

    internal sealed class ThermalModel
    {
        internal readonly string Key;
        internal readonly ThermalChannel[] Channels;
        internal readonly double MinFan, MaxFan, MinPower, MaxPower, MinOther, MaxOther, MinAmbient, MaxAmbient;
        internal readonly bool HasHotspot, HasMemory;
        internal ThermalModel(string key, ThermalChannel[] channels, double[] domain, bool hotspot, bool memory)
        {
            Key = key; Channels = (ThermalChannel[])channels.Clone();
            MinFan = domain[0]; MaxFan = domain[1]; MinPower = domain[2]; MaxPower = domain[3];
            MinOther = domain[4]; MaxOther = domain[5]; MinAmbient = domain[6]; MaxAmbient = domain[7];
            HasHotspot = hotspot; HasMemory = memory;
        }
        internal bool Supports(double ambient, double fan, double power, double other)
        {
            return PredictiveMath.Finite(ambient) && PredictiveMath.Finite(fan) && PredictiveMath.Finite(power) && PredictiveMath.Finite(other)
                && fan >= MinFan && fan <= MaxFan && power >= MinPower && power <= MaxPower
                && other >= MinOther - 1 && other <= MaxOther + 1 && ambient >= MinAmbient - 1 && ambient <= MaxAmbient + 1;
        }
    }

    internal static class PredictiveMath
    {
        internal static bool Finite(double x) { return !double.IsNaN(x) && !double.IsInfinity(x); }
        internal static double Clamp(double x, double min, double max) { return Math.Max(min, Math.Min(max, x)); }
        internal static double Interpolate(double[] x, double[] y, double value)
        {
            if (!Finite(value) || value < x[0] || value > x[x.Length - 1]) throw new ArgumentOutOfRangeException("value", "Extrapolation is disabled.");
            for (int i = 1; i < x.Length; i++)
                if (value <= x[i]) return y[i - 1] + (y[i] - y[i - 1]) * (value - x[i - 1]) / (x[i] - x[i - 1]);
            return y[y.Length - 1];
        }
        internal static double[] Basis(double fan, double[] knots)
        {
            double[] b = new double[3];
            int segment = fan <= knots[1] ? 0 : 1;
            double t = Clamp((fan - knots[segment]) / (knots[segment + 1] - knots[segment]), 0, 1);
            b[segment] = 1 - t; b[segment + 1] = t; return b;
        }
        // Column-scaled Householder QR. Avoid squaring the condition number via normal equations.
        // Rank screening rejects confounded inputs; regularization must not conceal missing excitation.
        internal static double[] Solve(List<double[]> rows, double[] y, double[] weights)
        {
            int n = rows.Count, p = rows[0].Length;
            double[] scale = new double[p];
            for (int i = 0; i < n; i++) for (int j = 0; j < p; j++) scale[j] += weights[i] * rows[i][j] * rows[i][j];
            for (int j = 0; j < p; j++) { scale[j] = Math.Sqrt(scale[j]); if (scale[j] < 1e-9) return null; }
            double[,] a = new double[n, p]; double[] rhs = new double[n];
            for (int i = 0; i < n; i++)
            {
                double rootWeight = Math.Sqrt(weights[i]); rhs[i] = rootWeight * y[i];
                for (int j = 0; j < p; j++) a[i, j] = rootWeight * rows[i][j] / scale[j];
            }
            for (int j = 0; j < p; j++)
            {
                double norm = 0; for (int i = j; i < n; i++) norm += a[i, j] * a[i, j]; norm = Math.Sqrt(norm);
                if (norm < 1e-3) return null;
                double alpha = a[j, j] >= 0 ? -norm : norm, normV = 0;
                double[] v = new double[n - j];
                for (int i = j; i < n; i++) { v[i - j] = a[i, j] - (i == j ? alpha : 0); normV += v[i - j] * v[i - j]; }
                for (int k = j; k < p; k++)
                {
                    double dot = 0; for (int i = j; i < n; i++) dot += v[i - j] * a[i, k];
                    for (int i = j; i < n; i++) a[i, k] -= 2 * dot / normV * v[i - j];
                }
                double dotY = 0; for (int i = j; i < n; i++) dotY += v[i - j] * rhs[i];
                for (int i = j; i < n; i++) rhs[i] -= 2 * dotY / normV * v[i - j];
            }
            double[] beta = new double[p];
            for (int j = p - 1; j >= 0; j--)
            { double value = rhs[j]; for (int k = j + 1; k < p; k++) value -= a[j, k] * beta[k]; beta[j] = value / a[j, j]; }
            for (int j = 0; j < p; j++) { beta[j] /= scale[j]; if (!Finite(beta[j])) return null; }
            return beta;
        }
        internal static double Dot(double[] a, double[] b) { double sum = 0; for (int i = 0; i < a.Length; i++) sum += a[i] * b[i]; return sum; }
    }

    internal static class ThermalIdentification
    {
        private static readonly double[] Taus = { 5, 8, 12, 18, 27, 40, 60, 90, 135, 200, 300, 450, 600 };
        internal static CalibrationReport Fit(string key, List<ThermalSample> data)
        {
            CalibrationReport report = new CalibrationReport { Detail = "Need at least 10 minutes and 300 valid samples with varied inputs." };
            if (data.Count < 300 || data[data.Count - 1].Time - data[0].Time < 600) return report;
            int split = (int)(data.Count * 0.7);
            report.TrainingIntervals = split - 1; report.ValidationIntervals = data.Count - split;
            double minFan = 100, maxFan = 0, minAmbient = 100, maxAmbient = -100, minOther = 1e9, maxOther = 0;
            for (int i = 0; i < data.Count; i++)
            {
                ThermalSample s = data[i];
                if (!Valid(s) || (i > 0 && (s.Time <= data[i - 1].Time || s.Time - data[i - 1].Time > 5))
                    || s.HasHotspot != data[0].HasHotspot || s.HasMemory != data[0].HasMemory)
                { report.Detail = "Invalid, discontinuous, or changing sensor coverage in calibration data."; return report; }
                if (i >= split) continue; // Validation values never select knots, parameters or the operating domain.
                minFan = Math.Min(minFan, s.Fan); maxFan = Math.Max(maxFan, s.Fan);
                minAmbient = Math.Min(minAmbient, s.Ambient); maxAmbient = Math.Max(maxAmbient, s.Ambient);
                minOther = Math.Min(minOther, s.Other); maxOther = Math.Max(maxOther, s.Other);
            }
            if (maxFan - minFan < 20) { report.Detail = "Insufficient fan coverage: need at least 20 percentage points across three levels."; return report; }
            double[] knots = { minFan, (minFan + maxFan) / 2, maxFan };
            int[] trainCount = new int[3], validationCount = new int[3];
            double[] lowP = { 1e9, 1e9, 1e9 }, highP = new double[3];
            double[] lowO = { 1e9, 1e9, 1e9 }, highO = new double[3];
            for (int i = 0; i < data.Count; i++)
            {
                ThermalSample s = data[i];
                int bin = (int)Math.Round((s.Fan - minFan) / (maxFan - minFan) * 2);
                if (bin < 0 || bin > 2 || Math.Abs(s.Fan - knots[bin]) > 5) continue;
                if (i < split)
                {
                    trainCount[bin]++; lowP[bin] = Math.Min(lowP[bin], s.Power); highP[bin] = Math.Max(highP[bin], s.Power);
                    lowO[bin] = Math.Min(lowO[bin], s.Other); highO[bin] = Math.Max(highO[bin], s.Other);
                }
                else validationCount[bin]++;
            }
            double commonLow = 0, commonHigh = double.PositiveInfinity, commonOtherLow = 0, commonOtherHigh = double.PositiveInfinity;
            for (int k = 0; k < 3; k++)
            {
                if (trainCount[k] < 30 || validationCount[k] < 10 || highP[k] - lowP[k] < 60)
                { report.Detail = "Each fan region needs training/held-out coverage and at least 60 W of independent power variation."; return report; }
                commonLow = Math.Max(commonLow, lowP[k]); commonHigh = Math.Min(commonHigh, highP[k]);
                commonOtherLow = Math.Max(commonOtherLow, lowO[k]); commonOtherHigh = Math.Min(commonOtherHigh, highO[k]);
            }
            if (commonHigh - commonLow < 60 || commonOtherLow > commonOtherHigh)
            { report.Detail = "Fan regions lack an overlapping tested power/neighbor-heat domain."; return report; }
            bool coupling = maxOther - minOther >= 30;
            ThermalChannel[] channels = new ThermalChannel[3];
            for (int channel = 0; channel < 3; channel++)
            {
                if (channel == 1 && !data[0].HasHotspot || channel == 2 && !data[0].HasMemory) continue;
                channels[channel] = FitChannel(data, split, channel, knots, coupling);
                if (channels[channel] == null)
                { report.Detail = "Channel " + channel + ": unidentifiable, nonphysical, boundary time constant, or failed held-out prediction."; return report; }
                report.ValidationRmseC = Math.Max(report.ValidationRmseC, channels[channel].Rmse);
                report.ValidationMaxErrorC = Math.Max(report.ValidationMaxErrorC, channels[channel].MaxError);
            }
            double[] domain = { minFan, maxFan, commonLow, commonHigh, commonOtherLow, commonOtherHigh, minAmbient, maxAmbient };
            ThermalModel model = new ThermalModel(key, channels, domain, data[0].HasHotspot, data[0].HasMemory);
            // Reject held-out extrapolation: apparent accuracy outside training coverage does not expand that coverage.
            for (int i = split; i < data.Count; i++)
                if (!model.Supports(data[i].Ambient, data[i].Fan, data[i].Power, data[i].Other))
                { report.Detail = "Held-out data extends outside the common training domain; collect overlapping coverage."; return report; }
            report.Accepted = true; report.Model = model; report.CoreTimeConstantSeconds = channels[0].Tau;
            report.EvidenceScore = Math.Max(0.75, Math.Min(0.95, 0.95 - report.ValidationRmseC / 10));
            report.FanMinimum = minFan; report.FanMaximum = maxFan; report.PowerMinimumW = commonLow; report.PowerMaximumW = commonHigh;
            report.Detail = "Validated on later, unused data. Interpolation only; 120-second free-run errors and steady-state constraints available.";
            return report;
        }

        private static bool Valid(ThermalSample s)
        {
            return PredictiveMath.Finite(s.Time) && PredictiveMath.Finite(s.Ambient) && PredictiveMath.Finite(s.Fan)
                && PredictiveMath.Finite(s.Power) && PredictiveMath.Finite(s.Other) && PredictiveMath.Finite(s.Core)
                && (!s.HasHotspot || PredictiveMath.Finite(s.Hotspot)) && (!s.HasMemory || PredictiveMath.Finite(s.Memory))
                && s.Time >= 0 && s.Ambient >= -10 && s.Ambient <= 60 && s.Fan >= 0 && s.Fan <= 100
                && s.Power >= 30 && s.Power <= 3000 && s.Other >= 0 && s.Other <= 20000;
        }

        private static ThermalChannel FitChannel(List<ThermalSample> data, int split, int channel, double[] knots, bool coupling)
        {
            double bestError = double.PositiveInfinity, bestTau = 0; double[] best = null;
            foreach (double tau in Taus)
            {
                List<double[]> rows = new List<double[]>(); double[] y = new double[split - 1], weights = new double[split - 1];
                double[] originalWeights = new double[split - 1];
                for (int i = 0; i < split - 1; i++)
                {
                    ThermalSample a = data[i], b = data[i + 1]; double alpha = Math.Exp(-(b.Time - a.Time) / tau);
                    double[] basis = PredictiveMath.Basis(a.Fan, knots);
                    double[] row = new double[coupling ? 5 : 4]; row[0] = 1;
                    for (int j = 0; j < 3; j++) row[j + 1] = a.Power * basis[j];
                    if (coupling) row[4] = a.Other;
                    rows.Add(row); y[i] = (b.Temperature(channel) - alpha * a.Temperature(channel)) / (1 - alpha) - a.Ambient;
                    weights[i] = originalWeights[i] = (1 - alpha) * (1 - alpha);
                }
                double[] beta = null;
                // Huber IRLS on one-step residuals. Validation remains untouched and is never downweighted.
                for (int iteration = 0; iteration < 3; iteration++)
                {
                    beta = PredictiveMath.Solve(rows, y, weights); if (beta == null) break;
                    for (int i = 0; i < rows.Count; i++)
                    {
                        double error = Math.Abs(y[i] - PredictiveMath.Dot(rows[i], beta)) * Math.Sqrt(originalWeights[i]);
                        weights[i] = originalWeights[i] * (error <= 1 ? 1 : 1 / error);
                    }
                }
                if (beta == null || beta[0] < -3 || beta[0] > 40 || (coupling && (beta[4] < 0 || beta[4] > 1))) continue;
                bool physical = true;
                for (int j = 1; j <= 3; j++) if (beta[j] <= 0 || beta[j] > 2 || (j > 1 && beta[j] > beta[j - 1] + 1e-5)) physical = false;
                if (!physical) continue; // Do not silently project contradictory observations into a convincing curve.
                double errorSum = 0;
                for (int i = 0; i < rows.Count; i++)
                {
                    double error = y[i] - PredictiveMath.Dot(rows[i], beta); errorSum += originalWeights[i] * error * error;
                }
                if (errorSum < bestError) { bestError = errorSum; best = beta; bestTau = tau; }
            }
            if (best == null || bestTau == Taus[0] || bestTau == Taus[Taus.Length - 1]
                || data[split - 1].Time - data[0].Time < 3 * bestTau
                || data[data.Count - 1].Time - data[split - 1].Time < Math.Max(120, 2 * bestTau)) return null;
            ThermalChannel draft = new ThermalChannel(bestTau, best[0], coupling ? best[4] : 0, knots,
                new[] { best[1], best[2], best[3] }, 0, 0);
            double squared = 0, worst = 0; int count = 0;
            // Non-overlapping 120-second free-run blocks, initialised once from an actual reading.
            int start = split - 1;
            while (start < data.Count - 1)
            {
                double prediction = data[start].Temperature(channel); int end = start + 1;
                for (; end < data.Count && data[end].Time - data[start].Time <= 120; end++)
                {
                    ThermalSample prior = data[end - 1], actual = data[end];
                    if (prior.Fan < knots[0] || prior.Fan > knots[2]) return null;
                    prediction = draft.Advance(prediction, actual.Time - prior.Time, prior.Ambient, prior.Power, prior.Other, prior.Fan);
                    double error = Math.Abs(prediction - actual.Temperature(channel)); squared += error * error; worst = Math.Max(worst, error); count++;
                }
                start = end - 1;
            }
            double rmse = Math.Sqrt(squared / Math.Max(1, count));
            if (count < 60 || rmse > 2 || worst > 4) return null;
            return new ThermalChannel(bestTau, best[0], coupling ? best[4] : 0, knots,
                new[] { best[1], best[2], best[3] }, rmse, worst);
        }
    }

    internal sealed class PredictiveChoice
    {
        internal double Fan, Power, Cost, CoreUpper;
        internal double? HotspotUpper, MemoryUpper;
    }

    internal static class PredictiveOptimization
    {
        internal static PredictiveChoice Choose(ThermalModel model, DeviceProfile profile, ThermalSample now,
            double currentCap, double startFan, double minFan, double maxFan, double[] ceilings)
        {
            if (!model.Supports(now.Ambient, now.Fan, now.Power, now.Other)) return null;
            minFan = Math.Max(minFan, Math.Max(profile.FanMinPercent, model.MinFan));
            maxFan = Math.Min(maxFan, Math.Min(profile.FanMaxPercent, model.MaxFan));
            double lowerPower = Math.Max(profile.PowerMinW, model.MinPower), upperPower = Math.Min(currentCap, Math.Min(profile.PowerMaxW, model.MaxPower));
            if (maxFan < minFan || upperPower < lowerPower) return null;
            PredictiveChoice best = null;
            // Finite, reproducible grid: reachable fan interval, <=0.5-point spacing; 5 W power spacing.
            List<double> fans = new List<double> { minFan, maxFan };
            if (startFan >= minFan && startFan <= maxFan) fans.Add(startFan);
            for (double fan = Math.Ceiling(minFan * 2) / 2; fan <= maxFan; fan += 0.5) fans.Add(fan);
            List<double> powers = new List<double> { lowerPower, upperPower };
            for (double p = Math.Ceiling(lowerPower / 5) * 5; p <= upperPower; p += 5) powers.Add(p);
            foreach (double fan in fans) foreach (double power in powers)
            {
                double[] upper = new double[3]; bool feasible = true; double cycling = 0, temperaturePenalty = 0;
                for (int channel = 0; channel < 3; channel++)
                {
                    ThermalChannel c = model.Channels[channel]; if (c == null) continue;
                    double initial = now.Temperature(channel), predicted = initial;
                    // Include time zero and steady state, so a short horizon cannot hide a later violation.
                    double maxPredicted = initial;
                    for (int step = 1; step <= 12; step++)
                    {
                        predicted = c.Advance(predicted, 10, now.Ambient, power, now.Other, fan);
                        maxPredicted = Math.Max(maxPredicted, predicted);
                        cycling += Math.Pow((predicted - initial) / 10, 2) / 36;
                    }
                    maxPredicted = Math.Max(maxPredicted, c.Equilibrium(now.Ambient, power, now.Other, fan));
                    upper[channel] = maxPredicted + c.Margin;
                    if (upper[channel] > ceilings[channel]) feasible = false;
                    temperaturePenalty += Math.Pow(Math.Max(0, upper[channel] - (ceilings[channel] - 6)) / 6, 2);
                }
                if (!feasible) continue;
                // Noise is a dimensionless proxy, NOT dBA. Power loss is a throughput proxy, NOT a benchmark.
                double noise = Math.Pow(fan / profile.FanMaxPercent, 3);
                double loss = Math.Pow((currentCap - power) / currentCap, 2);
                double movement = Math.Pow((fan - startFan) / 5, 2);
                double preference = Math.Pow(Math.Max(0, fan - profile.AcousticPreferencePercent) / 25, 2);
                double cost = noise + 4 * loss + 0.2 * movement + 0.1 * cycling + 0.25 * temperaturePenalty + preference;
                if (best == null || cost < best.Cost - 1e-10)
                    best = new PredictiveChoice { Fan = fan, Power = power, Cost = cost, CoreUpper = upper[0],
                        HotspotUpper = model.HasHotspot ? (double?)upper[1] : null, MemoryUpper = model.HasMemory ? (double?)upper[2] : null };
            }
            return best;
        }
    }

    internal static class CalibratedFanController
    {
        internal static Recommendation Evaluate(DeviceProfile profile, Snapshot snapshot, Memory previous)
        {
            Recommendation result = AdaptiveFanPolicy.EvaluateGuard(profile, snapshot, previous);
            Memory m = result.Next;
            bool priorCalibrated = previous != null && previous.CalibrationComplete;
            // The internal guard's observation bit is not the public predictive-calibration bit.
            m.CalibrationComplete = false;
            if (result.State == ControlState.Emergency || result.State == ControlState.FanFault || result.State == ControlState.SensorFault || result.State == ControlState.VendorAuto)
            {
                if (!priorCalibrated) result.FanPercent = null;
                result.PowerLimitW = null;
                // Fault recovery always needs fresh identification; only the current emergency may retain maximum-fan advice.
                m.Samples.Clear(); m.ThermalModel = null; m.FitReport = null; m.LastFitTime = double.NegativeInfinity;
                return result;
            }
            result.FanPercent = null; result.PowerLimitW = null; result.ModelConfidence = 0;
            result.TargetInfeasibleAtMinimumPower = false; // A legacy ratio does not establish predictive infeasibility.
            List<string> currentReasons = new List<string>();
            foreach (string reason in result.Reasons)
                if (!reason.StartsWith("Power budget is a conservative") && !reason.StartsWith("Estimated target requires power")) currentReasons.Add(reason);
            result.Reasons = currentReasons.ToArray();
            if (result.Confidence < 0.75 || !result.AmbientC.HasValue)
            { AddReason(result, "Predictive calibration requires uninterrupted high-confidence telemetry."); return result; }
            double fan = snapshot.Fans[0].IntendedPercent.Value;
            foreach (FanReading f in snapshot.Fans)
                if (Math.Abs(f.IntendedPercent.Value - fan) > 3)
                { ClearModel(m); AddReason(result, "Predictive model does not support independently moving fan zones."); m.State = ControlState.Calibrating; return result; }
            ThermalSample current = new ThermalSample { Time = snapshot.NowSeconds, Ambient = result.AmbientC.Value,
                Fan = fan, Power = snapshot.BoardPowerW.Value, Other = snapshot.OtherHeatW.Value, Core = snapshot.CoreC.Value,
                HasHotspot = snapshot.HotspotC != null, Hotspot = snapshot.HotspotC == null ? 0 : snapshot.HotspotC.Value,
                HasMemory = snapshot.MemoryC != null, Memory = snapshot.MemoryC == null ? 0 : snapshot.MemoryC.Value };
            // Idle is useful for health monitoring, but not mixed into a loaded power-response fit.
            if (current.Power < Math.Max(30, profile.PowerMaxW * 0.15))
            { ClearModel(m); m.State = ControlState.Calibrating; AddReason(result, "Loaded model coverage is unavailable at this operating point."); return result; }
            if (m.ThermalModel != null)
            {
                if (!m.ThermalModel.Supports(current.Ambient, current.Fan, current.Power, current.Other)
                    || m.ThermalModel.HasHotspot != current.HasHotspot || m.ThermalModel.HasMemory != current.HasMemory)
                { ClearModel(m); AddReason(result, "Outside calibrated conditions: collect a new model; extrapolation is disabled."); }
                else if (Drifted(m, current))
                { ClearModel(m); m.ObservationComplete = false; m.ObservedSeconds = 0; m.StableSeconds = 0;
                    AddReason(result, "Sustained prediction error: cooling model invalidated; re-observe and inspect airflow/maintenance."); }
            }
            m.Samples.Add(current); if (m.Samples.Count > 3600) m.Samples.RemoveAt(0);
            if (m.ThermalModel == null && current.Time - m.LastFitTime >= 60)
            {
                m.LastFitTime = current.Time; m.FitReport = ThermalIdentification.Fit(profile.EvidenceKey, m.Samples);
                if (m.FitReport.Accepted)
                {
                    m.ThermalModel = m.FitReport.Model; m.DriftPrediction = new[] { current.Core, current.Hotspot, current.Memory };
                    m.DriftAnchorTime = current.Time; m.ModelBadSeconds = 0;
                }
            }
            result.Calibration = m.FitReport;
            if (m.ThermalModel == null || !m.ObservationComplete)
            {
                m.State = m.ObservedSeconds < 60 ? ControlState.Observing : ControlState.Calibrating;
                AddReason(result, m.FitReport == null ? "Collecting thermal response for predictive calibration." : m.FitReport.Detail);
                return result;
            }
            m.CalibrationComplete = true;
            result.ModelConfidence = m.FitReport.EvidenceScore;
            double startFan = priorCalibrated && previous != null && PredictiveMath.Finite(previous.VirtualFan) ? previous.VirtualFan : current.Fan;
            double dt = previous == null ? 0 : Math.Max(0, Math.Min(5, current.Time - previous.LastNow));
            double lastChange = priorCalibrated ? previous.LastFanChange : current.Time;
            double minFan = startFan, maxFan = startFan;
            if (current.Time - lastChange >= 30) maxFan += Math.Min(5, dt * AdaptiveFanPolicy.FanRisePercentPerSecond);
            if (current.Time - lastChange >= 60 && m.CoolSeconds >= 120 && m.StableSeconds >= 120 && result.State != ControlState.Cooldown)
                minFan -= Math.Min(2, dt * AdaptiveFanPolicy.FanFallPercentPerSecond);
            double[] ceilings = { result.CoreEmergencyC - 7, result.HotspotEmergencyC - 7, result.MemoryEmergencyC - 7 };
            PredictiveChoice choice = PredictiveOptimization.Choose(m.ThermalModel, profile, current,
                snapshot.CurrentPowerLimitW.Value, startFan, minFan, maxFan, ceilings);
            if (choice == null)
            {
                m.State = ControlState.HeatLimited; result.ReduceWorkload = true;
                AddReason(result, "No calibrated, reachable fan/power pair satisfies the prediction envelope; reduce work or improve cooling.");
                m.VirtualFan = startFan; m.LastFanChange = lastChange; return result;
            }
            result.FanPercent = choice.Fan;
            if (choice.Power < snapshot.CurrentPowerLimitW.Value - 0.1) result.PowerLimitW = choice.Power;
            result.ForecastCoreUpperC = choice.CoreUpper; result.ForecastHotspotUpperC = choice.HotspotUpper; result.ForecastMemoryUpperC = choice.MemoryUpper;
            result.OptimizationCost = choice.Cost;
            m.VirtualFan = choice.Fan; m.LastFanChange = Math.Abs(choice.Fan - startFan) > 0.001 ? current.Time : lastChange;
            AddReason(result, "Calibrated finite-horizon search: 120 seconds plus steady state, empirical error margins, reachable fan moves, no extrapolation.");
            return result;
        }
        private static void ClearModel(Memory m)
        {
            m.ThermalModel = null; m.FitReport = null; m.Samples.Clear(); m.DriftPrediction = null;
            m.ModelBadSeconds = 0; m.LastFitTime = double.NegativeInfinity; m.CalibrationComplete = false;
        }
        private static bool Drifted(Memory m, ThermalSample current)
        {
            if (m.Samples.Count == 0 || m.DriftPrediction == null) return false;
            ThermalSample prior = m.Samples[m.Samples.Count - 1]; double dt = current.Time - prior.Time; bool bad = false;
            for (int channel = 0; channel < 3; channel++)
            {
                ThermalChannel model = m.ThermalModel.Channels[channel]; if (model == null) continue;
                m.DriftPrediction[channel] = model.Advance(m.DriftPrediction[channel], dt, prior.Ambient, prior.Power, prior.Other, prior.Fan);
                if (Math.Abs(current.Temperature(channel) - m.DriftPrediction[channel]) > model.Margin + 1) bad = true;
            }
            m.ModelBadSeconds = bad ? m.ModelBadSeconds + dt : 0;
            if (m.ModelBadSeconds >= 20) return true;
            if (!bad && current.Time - m.DriftAnchorTime >= 120)
            { m.DriftPrediction = new[] { current.Core, current.Hotspot, current.Memory }; m.DriftAnchorTime = current.Time; }
            return false;
        }
        private static void AddReason(Recommendation r, string reason)
        {
            List<string> reasons = new List<string>(r.Reasons ?? new string[0]); reasons.Add(reason); r.Reasons = reasons.ToArray();
        }
    }
}
