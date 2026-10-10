# Evidence gates for a safe GPU candidate

CA AutoConfig does not turn the most efficient point in a chart directly into a setting. A chart is exploratory evidence. A candidate becomes eligible for later user confirmation only after independent gates answer different questions.

## Why the gates are separate

NVIDIA's TensorRT measurement guidance recommends collecting clocks, power, temperature, and utilization alongside the workload, and explicitly does not prescribe one universal clock frequency. Local-AI community measurements also show that a power/clock sweet spot depends on the card, workload phase, model, driver, and cooling:

- [NVIDIA TensorRT performance measurement environment](https://docs.nvidia.com/deeplearning/tensorrt/10.x.x/performance/hw-sw-environment.html)
- [RTX 3090 llama.cpp power-limit experiment with raw methodology](https://www.reddit.com/r/LocalLLaMA/comments/1hg6qrd/relative_performance_in_llamacpp_when_adjusting/)
- [Community multi-GPU clock-versus-throughput experiment](https://www.reddit.com/r/LocalLLaMA/comments/1ggjngw/gpu_speed_vs_tokens_per_second_power_draw_test/)

These sources motivate local measurement; they do not prove CA AutoConfig's defaults or any universal limit.

## Current progression

```text
Power Curve evidence
        |
        v
Workload candidate gate
  - exact reference + candidate
  - phase-aligned repeated rates and power
  - no failure, incomplete run, or driver reset
  - throughput, efficiency, temperature, clock stability
        |
        v
Idle-power gate
  - paired vendor-auto + persistent-lock idle runs
  - complete genuinely idle telemetry
  - aggregate + per-GPU regression thresholds
        |
        v
Future privileged boundary
  - authenticated minimal apply/reset helper
  - explicit administrator confirmation
  - verified one-click rollback
```

No current function skips directly to the last step.

## Workload gate defaults

[`PowerAdvisor.psm1`](../../benchmark/PowerAdvisor.psm1) compares one user-named candidate with one user-named reference. It never searches for a winner and therefore cannot hide the selection decision.

- At least three unique repetitions per profile.
- At least 30 seconds and the declared interval's full sample count per run.
- Live schema-v3 data with one workload, one hardware/driver identity, and aligned throughput/power windows.
- At least 90% of reference throughput retained.
- At least 5% same-window efficiency improvement.
- Candidate mean board power lower than reference.
- Candidate peak temperature at most 85°C.
- At least three clock samples per GPU/run while utilization is at least 50%.
- Loaded p05-to-p95 clock spread at most 5%.
- No loaded clock more than 30 MHz above the declared ceiling.

Any failed or incomplete selected run is a rejection, not a sample to discard. Driver/GPU reset, device-loss, and Xid text is surfaced as `driver-reset-evidence`. Structural or missing evidence returns `INSUFFICIENT`; a measured failure or threshold violation returns `REJECTED`; fixtures always return `FIXTURE`.

## What remains before apply

`CanProceedPastWorkloadGate` and `CanProceedPastIdleGate` are deliberately separate. Even if both are true, CA AutoConfig still lacks the minimal authenticated privileged boundary and end-to-end rollback proof required for an apply recommendation. Quiet profiles also need acoustic/fan evidence that the current workload schema does not collect.

Thresholds are policy defaults rather than physical constants. Every generated report prints the thresholds used. If a contributor changes them, the exact command and rationale must accompany the raw anonymized exports.
