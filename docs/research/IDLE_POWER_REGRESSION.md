# Why persistent clock locks need an idle-power gate

A graphics-clock limit can improve throughput per watt under one AI workload and still be a poor always-on workstation setting. CA AutoConfig therefore treats workload efficiency and idle behavior as different evidence domains. Neither can stand in for the other.

## Evidence behind the boundary

NVIDIA documents `nvidia-smi --lock-gpu-clocks` as an explicit device command and `--reset-gpu-clocks` as the corresponding return to default behavior. NVIDIA's TensorRT measurement guidance recommends recording clocks, power, temperature, and utilization during performance work, and explicitly says there is no single definite clock-lock recommendation for every workload:

- [NVIDIA System Management Interface documentation](https://docs.nvidia.com/deploy/nvidia-smi/index.html)
- [NVIDIA TensorRT performance measurement environment](https://docs.nvidia.com/deeplearning/tensorrt/10.x.x/performance/hw-sw-environment.html)

Local-AI users have also reported hardware- and driver-specific idle regressions after persistent clock or persistence-mode changes. These reports are anecdotes, not universal measurements, but they are a strong reason to measure rather than assume:

- [RTX 3090 llama.cpp power-limit and clock-limit experiment](https://www.reddit.com/r/LocalLLaMA/comments/1hg6qrd/relative_performance_in_llamacpp_when_adjusting/)
- [Further RTX 3090 idle-power exploration](https://www.reddit.com/r/LocalLLaMA/comments/1k7m902/further_explorations_of_3090_idle_power/)
- [Community report on clock limits and RTX 3090 idle draw](https://www.reddit.com/r/LocalLLaMA/comments/1k2fb67/save_13w_of_idle_power_on_your_3090/)

The inference is deliberately narrow: because the direction and size of idle effects vary by card, driver, display state, operating system, and clock mechanism, an advisor must require paired local evidence before advancing a persistent clock-lock candidate.

## Gate contract

The current gate uses [`idle-schema-v1.json`](../../benchmark/idle-schema-v1.json) and keeps idle evidence separate from workload schema-v3.

- Baseline runs must declare `vendor-auto` and no graphics-clock maximum.
- Candidate runs must declare `persistent-graphics-lock` and the tested maximum clock.
- Baseline and candidate must use the same GPU indices, models, and driver.
- Every condition needs at least three unique repetitions; the live recorder defaults to 60 seconds after a 30-second settling window.
- Missing power or utilization, a short sample set, failed/incomplete runs, mixed profiles, or a non-idle desktop fail closed.
- Default idle acceptance is mean utilization at most 5% and p95 utilization at most 15%.
- Combined board-power increase must stay within 5 W and 10%; every GPU must also stay within 3 W and 15%. Exceeding either the watt or percentage limit blocks progression.
- Fixture evidence can test every branch but always returns `FIXTURE`, never `PASS`.

These are transparent project defaults, not physical constants. A report records the exact thresholds used so reviewers can reproduce or dispute the decision.

## What a pass means

A live pass means only `CanProceedPastIdleGate = true`. It does not mean the profile is safe, stable, optimal, or ready to apply. A final advisor still needs all of the following:

1. phase-aligned repeated workload evidence;
2. no workload, driver-reset, or incomplete run;
3. stable clocks and acceptable temperature;
4. a minimal authenticated privileged apply/reset boundary;
5. explicit administrator confirmation and a verified one-click rollback.

The recorder never calls `-lgc`, `-rgc`, `-pl`, or any other mutation command. Profile changes remain separate, visible user actions. Board telemetry also does not replace a wall meter when making whole-system energy or electricity-cost claims.
