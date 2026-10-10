# Calibration first, then predictive optimization

This is the current public policy, implemented in `PredictiveThermalModel.cs` and called by `AdaptiveFanPolicy.Evaluate`. The earlier five-minute gate is now **observation readiness**, not sufficient calibration. The implementation is still a simulation: no fan/power writes, stress tests, or live hardware calibration have been performed.

## What must be measured first

The system needs enough independent variation to distinguish fan response, board-power heating, shared chassis heat and thermal inertia. A long flat recording cannot do that. A fan that always increases in lockstep with power can also leave effects confounded. The public policy withholds numeric fan/power advice until both the observation gate and identification gate pass.

| Gate | Current requirement |
|---|---|
| Valid observations | Existing physical-tach, sensor confidence, freshness, per-junction and vendor-limit guards |
| Basic readiness | Five minutes, 30 fresh samples, and a two-minute stable loaded interval |
| Identification history | At least ten minutes and 300 samples; minimum time alone never passes |
| Fan coverage | Three regions spanning at least 20 percentage points |
| Power coverage | At least 60 W variation in every fan region and a common overlapping power range |
| Region support | Each fan region has at least 30 training samples and ten later validation samples within five percentage points of its knot |
| Neighbor heat | Fit coupling only if other heat varies by at least 30 W and the regression is identifiable; otherwise permit only the observed fixed other-heat range |
| Numeric conditioning | Column-scaled QR; reject a normalized residual column norm below 0.001 |
| Physical coefficients | Positive resistance decreasing with fan; nonnegative neighbor coupling; bounded offset and coefficients |
| Time response coverage | Training spans at least three fitted time constants; validation spans at least two and no less than 120 seconds |
| Held-out prediction | Each available junction: free-run RMSE ≤2°C and maximum absolute error ≤4°C |
| Current operating point | Inside the trained fan, overlapping power/neighbor-heat, ambient and sensor-coverage domain |

The first 70% of accepted samples selects coefficients and time constants. The last 30% is later validation data. That split is chronological, never a random shuffle of neighboring thermal samples. The held-out data does not choose fan knots, coefficient values, or time constant. It can reject a model, and it cannot expand its training domain. Using distinct estimation and validation data follows standard [system-identification guidance](https://www.mathworks.com/help/ident/ug/specifying-estimation-and-validation-data.html).

The model is refitted at most once a minute while uncalibrated. History is bounded to 3,600 samples. In production, identification belongs on a worker so it cannot delay sensor polling or raw safety checks. Future data can become part of a later rolling training window; these are engineering validation errors, not a formal statistical coverage guarantee.

## Thermal equations

For each available sensor `j` (core, hotspot, VRAM), fit a separate local first-order response:

```text
T∞,j = Ta + bj + Rj(u) P + Kj Po
Tj,k+1 = aj,k Tj,k + (1 − aj,k) T∞,j,k
aj,k = exp(−Δtk / τj)
```

`Ta` is room temperature, `P` board watts, `Po` other chassis watts, `u` observed fan percent, `bj` an offset in °C, `Rj` an effective resistance in °C/W, `Kj` a coupling coefficient in °C/W, and `τj` the thermal time constant in seconds. This is a calibrated local model, not a package thermal specification. When neighbor heat is constant, its effect is absorbed into the offset and the model refuses a new neighbor-heat condition.

Unlike the separate inlet-based case-resistance diagnostic, `Rj` includes the effective board/cooler/chassis response. `Kj` uses aggregate other heat; it does not identify which neighboring GPU heats which zone. Case-temperature diagnostics remain useful for maintenance, but are not silently substituted for this fitted dynamic model.

The coefficient fit assumes inputs are approximately held over each acquisition interval. Keep synchronized original timestamps and compatible power averaging windows. A readout of average board power and a temperature from a different time can otherwise create a misleading time constant. The model assumes one coordinated fan zone and does not support different fans moving independently.

### Bounded interpolation

Use three measured fan knots `u0 < u1 < u2`. In the bracketing interval:

```text
λ = (u − ui) / (ui+1 − ui)
Rj(u) = (1 − λ) Rj,i + λ Rj,i+1
```

The fit accepts only `Rj,0 ≥ Rj,1 ≥ Rj,2 > 0`. Linear interpolation is therefore positive, monotone and bounded by adjacent measured coefficients. Values outside `[u0,u2]` are rejected. A physically contradictory curve causes failed calibration; it is not smoothed into a falsely convincing cooling curve.

The choice of linear interpolation is deliberate: with only three independently supported regions, it exposes the evidence and avoids overshoot. With denser verified data, shape-preserving PCHIP is a reasonable later option. [SciPy documents PCHIP's monotonicity and no-overshoot behavior](https://docs.scipy.org/doc/scipy/reference/generated/scipy.interpolate.PchipInterpolator.html). A generic high-degree polynomial or unconstrained cubic is not justified here.

### Fit coefficients and time constants

For a candidate `τ`, define three linear fan basis weights `Bi(u)` and rearrange the response:

```text
yk = (Tj,k+1 − ak Tj,k) / (1 − ak) − Ta,k
xk = [1, Pk B0(uk), Pk B1(uk), Pk B2(uk), Po,k]
βj = [bj, Rj,0, Rj,1, Rj,2, Kj]
βj ≈ argmin Σk wk (yk − xk βj)²
wk starts at (1 − ak)²
```

The `Po` column is omitted when not excited. Weighting by `(1−a)²` compares one-step temperature error consistently across candidate time constants. The implementation uses **column-scaled Householder QR**, not inversion of `XᵀX`, and three Huber reweighting iterations with a 1°C one-step residual threshold. This limits the influence of isolated training spikes. Validation errors are never downweighted or discarded.

Search time constants `{5, 8, 12, 18, 27, 40, 60, 90, 135, 200, 300, 450, 600}` seconds using training error only. Reject optima at the grid endpoints because the selected time scale may lie outside the model's search range. Reject under-excited, nonphysical and numerically weak fits. The QR screen is a conservative rank/conditioning check, not a reported SVD condition number.

A more complex model is not automatically better. First-order responses can fail for liquid loops, delayed multi-stage chassis soak, changing thermal contact, memory-heavy workloads with different heat distribution, or fan-actuator delay. Those systems should fail validation or be treated as unsupported; adding more fitted parameters without additional independent measurements would make identifiability worse.

### Validation must predict without peeking

Initialize each validation block from one measured temperature. Then recursively predict up to 120 seconds using the recorded inputs, without resetting to the measured temperature each sample. A one-step predictor can look accurate while its multi-step forecast drifts; this free-run check tests the behavior used by the optimizer.

For every supported junction, report:

```text
RMSE = sqrt(mean((Tpred − Tmeasured)²))
Emax = max(abs(Tpred − Tmeasured))
margin = max(2°C, Emax + 1°C)
```

Reject if any junction fails its validation gate. The margin is an empirical error allowance, **not** a 95% confidence interval or a guarantee against future error. The displayed model evidence score is capped at 0.95 and based on worst-junction validation RMSE. Sensor evidence remains a separate score.

## The predictive decision

The optimizer enumerates a deterministic grid of **currently reachable** fan values (≤0.5-point grid spacing) and power limits (5 W grid spacing, including endpoints). It evaluates each candidate over twelve ten-second steps and its eventual steady state. It repeats this search when new telemetry arrives.

This is a single-move, hold-constant predictive search with hard constraints. It does not optimize an arbitrary sequence of future fan/power actions and does not claim a proof of closed-loop stability. Predicting ahead and enforcing constraints follows the general [model predictive control approach](https://www.mathworks.com/help/mpc/gs/what-is-mpc.html); the implementation is purposefully smaller than a general MPC solver.

Hard constraints always take precedence:

- Fan/power values remain within vendor bounds and the calibrated domain; power never exceeds the current enforced cap.
- Fan moves obey existing dwell, slew and cooldown limits. The search cannot assume an instant jump to maximum fan.
- Predicted temperature **plus the junction's own margin** must stay below that junction's emergency ceiling minus 7°C.
- Include time zero and eventual steady state. A short horizon cannot hide an overheating equilibrium.
- If no feasible candidate exists, output no numeric solution; request less work or better cooling. Do not relax the temperature constraint until a number appears.

Predictions are conditional on the hypothetical candidate being realized, room temperature and other-GPU heat staying within the stated scenario, and the identified response remaining valid. Physical actuator lag, power-cap transient overshoot, unobserved VRAM sensors and future workload changes are not guaranteed by this model. The delivered code has no actuator.

Among feasible candidates, minimize this explicit dimensionless objective:

```text
J = noiseProxy + 4 powerLossProxy + 0.2 fanMovement
    + 0.1 thermalMovement + 0.25 temperaturePressure + acousticPreferencePenalty

noiseProxy = (u / uvendor,max)³
powerLossProxy = ((PcurrentCap − Pcandidate) / PcurrentCap)²
fanMovement = ((u − upreviousSuggestion) / 5)²
thermalMovement = mean over junctions/time of ((Tpred − Tnow) / 10)²
temperaturePressure = Σj (max(0, Tupper,j − (ceilingj − 6)) / 6)²
acousticPreferencePenalty = (max(0, u − preferredFanPercent) / 25)²
```

The acoustic term is a proxy, not dBA, and the power term is a preference proxy, not measured tokens/second or FPS. The weights are explicit engineering defaults, not learned preferences. To claim hardware-specific efficiency optimization, the next measurement layer must supply a measured acoustic cost curve and a workload performance-versus-power curve. Until then, the claim is: **lowest declared objective among the enumerated feasible candidates**, not globally best performance/noise.

The three goals interact visibly. At 40°C, smaller thermal headroom can eliminate high-power candidates even when fan speed is high. With a flat calibrated fan-benefit curve, more fan noise cannot win merely by chasing an unreachable temperature. Penalizing movement and retaining hysteresis/dwell discourages fan hunting and large temperature cycles.

## Invalidate models when evidence changes

A 25°C calibration is not reused at 40°C. Current room temperature may differ by at most 1°C from the observed training envelope; larger changes restart identification. Fan and power stay strictly inside measured bounds; neighbor heat gets a 1 W numerical tolerance only. Change the profile evidence key for hardware, driver, topology or policy changes.

While calibrated, maintain a free-running thermal prediction using observed inputs. Re-anchor every 120 seconds only while residuals are healthy. If any junction differs by more than its margin plus 1°C continuously for 20 seconds, invalidate the model, revoke numeric advice and restart observation. Do not silently adapt away dust or cooler-contact degradation. Raw emergency and sensor/fan fault handling always runs before model fitting or optimization.

## Calibration workflow and UX

1. Inventory and validate sensors/limits; stay in vendor auto.
2. Observe normal representative loads. Show `ObservationComplete` independently from `CalibrationComplete`.
3. Show the missing evidence: fan span, power span per fan region, independent neighbor variation, stable interval, or held-out accuracy. Do not show a guaranteed “ready in five minutes.”
4. If passive vendor-auto data remains correlated, say **“Current readings cannot separate fan cooling from workload heat. Predictive control remains unavailable.”** A separately reviewed, bounded calibration experiment may be needed; this code never starts one or changes settings to obtain data.
5. Once accepted, show the measured domain, time constants, worst-junction validation errors, predictions with empirical margins, and the proposed fan/power pair. Continue marking it **Simulation**.

Suggested status text:

> Observation complete. Predictive calibration needs more variation: three fan regions, with different power levels in each.

> Model validated: predicts the later recording within the displayed error bounds. Optimization is limited to the measured conditions.

> Cooling response changed. Predictions no longer match readings; numeric advice is paused while calibration restarts.

## Validation of this implementation

Verified on 10 October 2026: **52/52 tests passed in Windows PowerShell 5.1 and 52/52 in PowerShell 7.6.6** (35 safety/reference cases and 17 predictive/public-API cases). Both production sources compile without external numerical dependencies. The exact synthetic plant's 40/60/90-second time constants were recovered, with worst-junction held-out RMSE and maximum error each below 0.001°C; the separate integer-quantized telemetry case also passed the 2°C/4°C validation gates. These are synthetic test results, not physical GPU measurements.

`PredictiveThermalModel.Tests.cs` uses an independently generated synthetic thermal plant with known 40/60/90-second core/hotspot/memory constants, two-segment fan resistance, independently changing power and neighbor heat. It checks coefficient recovery, bounded interpolation, held-out predictions, integer temperature quantization, training spikes, confounded inputs, failed validation, fixed neighbor heat, hot-room power choices, infeasibility, model drift, public calibration gating, immediate emergencies, and deterministic replay without mutating state.

The existing 35 regression cases now call the internal guard/reference branch, preserving coverage of hardware safety behavior. The public API always calls the predictive gate; it has no public switch to use the legacy observation-only recommendation path. Test output distinguishes these suites.

Synthetic recovery demonstrates the mathematics on a known model. It does not establish real-device calibration, noise benefit, throughput gain, lifespan improvement, or support for every cooling architecture. All files remain isolated under `fan-control`.
