# Read-only AI power-curve lab

This lab records NVIDIA board telemetry beside throughput that you measured from a real AI workload. It does not set a power limit, clock, voltage, or fan value. Every exported run omits GPU UUIDs, machine/user names, file paths, and raw commands.

The included fixtures are synthetic test data. They demonstrate the pipeline and must never be presented as hardware results.

## Why the protocol is strict

A single “tokens per second at 280 W” number is not portable. Prompt processing and token generation stress different parts of a GPU; board/VBIOS limits differ; a hot second run is not comparable to a cold first run; partial CPU offload changes both throughput and whole-system energy.

For a publishable curve:

1. Freeze the model, quantization, context, batch size, GPU split, backend build/commit, driver, and workload input.
2. Record prompt-processing and generation throughput separately whenever the backend exposes both.
3. Declare the board-power window and each throughput-rate window. For the generic steady-state recorder, warm up for at least 30 seconds and sample for at least 60 seconds.
4. Run at least three repetitions per profile. Interleave or randomize profile order and allow temperatures to return near the same baseline.
5. Record every failed, incomplete, throttled, or reset run. Do not discard it because it weakens the curve.
6. Use generation tokens/Joule (`tokens/s ÷ mean board watts`) only when schema-v3 declares the rate and board power over the same window. A phase rate divided by request/process-window watts is only a rate/power index, not Joules per token. Add wall-meter watt-hours when making electricity-cost claims.
7. Publish the raw anonymized JSON beside the summary and describe anything the schema does not capture.

## Dry run

The dry run analyzes two synthetic dual-3090 fixtures and writes a Markdown report:

```powershell
.\benchmark\New-PowerCurveReport.ps1 -DryRun -OutputPath .\artifacts\fixture-power-curve.md
.\benchmark\New-PowerCurveCard.ps1 -DryRun -OutputPath .\artifacts\fixture-power-curve.svg
```

The SVG card is generated deterministically from the same validated rows. It labels fixture data as **NOT HARDWARE EVIDENCE**, labels live curves with fewer than three runs per profile as **DRAFT / INSUFFICIENT REPETITIONS**, and counts failed or incomplete runs instead of silently dropping them.

## Phase alignment and energy claims

Schema-v3 records `powerWindow`, `promptRateWindow`, `generationRateWindow`, and `workRateWindow`. Exact `/J` output is allowed only when the relevant rate window equals the power window:

- The generic recorder declares `steady-state` for the user-supplied rate and sampled power. The user is responsible for measuring that rate over the same steady interval.
- Ollama power samples span the `end-to-end-request`, while its official prompt and generation rates describe `prompt-phase` and `generation-phase`. The report therefore emits a within-protocol rate/power index, never prompt or generation tokens/J.
- llama.cpp power samples span the measured `process-window`, including load and shutdown, while official `pp` and `tg` rates describe their benchmark phases. These are also index-only until power is sampled per phase.
- ComfyUI's declared work rate and board power both span the same `client-window`, so work/J is energy-aligned for that scoped client-observed run.

Schema-v1/v2 remain readable but have no phase provenance. They retain rate and board-power values while exact per-joule fields stay `N/A`. This prevents a legacy export from acquiring a stronger energy claim during re-analysis.

Run the deterministic privacy and calculation tests in either supported PowerShell runtime:

```powershell
.\benchmark\Run-Tests.ps1
powershell.exe -NoProfile -File .\benchmark\Run-Tests.ps1
```

## Record one real run

### Ollama: measure workload and GPUs together

Install the model yourself, keep Ollama running locally, and use a fixed public benchmark prompt. The adapter calls the local `/api/generate` endpoint with `stream=false`, temperature `0`, seed `42`, and explicit context/output sizes while it samples NVIDIA telemetry:

```powershell
.\benchmark\Invoke-OllamaPowerRun.ps1 `
  -Model 'qwen2.5-coder:14b' `
  -BenchmarkId 'public-code-prompt-v1' `
  -Prompt 'Write a deterministic 512-token explanation of matrix multiplication.' `
  -GpuIndexList '0,1' `
  -NumCtx 4096 `
  -NumPredict 512 `
  -Repetition 1 `
  -OutputPath .\artifacts\runs\ollama-profile-a-r1.json
```

`BenchmarkId` is a non-sensitive identifier for the exact prompt/protocol. Keep it unchanged only when the prompt and workload are unchanged. The raw prompt and generated response are used in memory but are never written to the schema-v3 export. Model quantization comes from `/api/show`; prompt and generation rates come from Ollama's `prompt_eval_*` and `eval_*` counters. Cached prompt tokens are excluded from prompt throughput. See the official [generate-response fields](https://docs.ollama.com/api/generate) and [model-details endpoint](https://docs.ollama.com/api-reference/show-model-details).

The adapter does not pull models or change GPU settings. It records a run as `incomplete` when generation ends before the default ten-second measurement window, and as `failed` when the measured request or its metrics fail. Local loopback is the default; a non-loopback endpoint requires `-AllowRemoteEndpoint` because it sends the supplied prompt to that server. Apply each candidate power profile through the separate reviewed workflow, then record at least three interleaved repetitions per profile.

### llama.cpp: drive `llama-bench` and sample GPUs together

Download/build llama.cpp and obtain the GGUF model yourself. The adapter never downloads either one. Give it non-sensitive labels rather than relying on a potentially private filename:

```powershell
.\benchmark\Invoke-LlamaBenchPowerRun.ps1 `
  -LlamaBenchPath 'C:\tools\llama.cpp\llama-bench.exe' `
  -ModelPath 'D:\models\qwen2.5-coder-14b-q4_k_m.gguf' `
  -ModelLabel 'Qwen2.5 Coder 14B' `
  -Quantization 'Q4_K_M' `
  -BenchmarkId 'qwen25-coder-14b-v1' `
  -GpuIndexList '0,1' `
  -PromptTokens 512 `
  -GenerationTokens 128 `
  -BenchRepetitions 5 `
  -Repetition 1 `
  -OutputPath .\artifacts\runs\llamacpp-profile-a-r1.json
```

The adapter first runs one same-shape warm-up repetition. It then starts a second process with `--no-warmup`, requests JSON output, and samples the selected GPUs until that process exits. The exporter requires exactly one `pp` row and one `tg` row matching the requested token counts, a complete `samples_ts` set, positive finite rates, and one consistent build/backend identity. Ambiguous or malformed output fails closed.

The power window is deliberately labeled `process-window`: it includes measured-process model load and shutdown, while llama-bench's official `avg_ts` values describe the `prompt-phase` and `generation-phase` benchmark operations and exclude tokenization and sampling. The report will not relabel this phase mismatch as tokens/J. That distinction must remain in published methodology. The schema export omits `model_filename`, `cpu_info`, `gpu_info`, the GGUF path, child stdout/stderr, and the raw command. See the official [`llama-bench` syntax and JSON fields](https://github.com/ggml-org/llama.cpp/blob/master/tools/llama-bench/README.md).

Use the same safe labels and all numeric options for every point in a curve. Apply each candidate power profile through the separate reviewed workflow, record at least three interleaved outer `-Repetition` runs, and keep failed/incomplete JSON files.

### ComfyUI: fixed workflow with explicit image throughput

In ComfyUI, export a working graph in API format (`File` → `Export (API)`). Choose one integer seed input that invalidates the sampler path on every run, and state the exact number of comparable work units produced by one workflow:

```powershell
.\benchmark\Invoke-ComfyUIPowerRun.ps1 `
  -WorkflowPath 'D:\benchmarks\sdxl-fixed-api.json' `
  -WorkflowId 'sdxl-1024-euler-30-v1' `
  -ModelLabel 'SDXL example' `
  -Quantization 'FP16' `
  -BackendLabel 'ComfyUI local API' `
  -SeedNodeId '3' `
  -SeedInputName 'seed' `
  -BaseSeed 1000 `
  -WorkUnits 1 `
  -WorkUnit 'image' `
  -GpuIndexList '0,1' `
  -Repetition 1 `
  -OutputPath .\artifacts\runs\comfy-profile-a-r1.json
```

The adapter requires an empty `/queue`, submits one warm-up at `BaseSeed`, verifies completion and the declared image count through `/history/{prompt_id}`, checks the queue again, then measures the same workflow at `BaseSeed + 1`. If the nominated seed node appears in ComfyUI's `execution_cached` event, or the terminal history does not contain exactly `WorkUnits` images, the run fails rather than reporting cached or missing output as performance. The reported rate is `WorkUnits ÷ client-observed submission-to-terminal seconds`; power samples cover that same client window. This is not an internal node-timing claim.

Schema-v3 retains `workUnitsPerSecond` and `workUnit` and declares both the ComfyUI rate and power as `client-window`, so image workloads can be reported as aligned `image/s` and `image/J` instead of being mislabeled as token throughput. Keep `WorkflowId`, work units, graph, model, sampler, scheduler, steps, dimensions, batch, extensions, and output behavior identical within a curve. See ComfyUI's official [basic API example](https://github.com/Comfy-Org/ComfyUI/blob/master/script_examples/basic_api_example.py) and [WebSocket/history example](https://github.com/Comfy-Org/ComfyUI/blob/master/script_examples/websockets_api_example.py).

The workflow must expose its images in terminal history and decides where they are saved. CA AutoConfig neither fetches nor deletes them, and it never writes the workflow, prompt text, history payload, output metadata, prompt ID, endpoint, or seed values into the run export. Loopback is the default; redirects are disabled, and `-AllowRemoteEndpoint` is required for a non-loopback server because the full workflow may contain prompts, filenames, and custom-node settings. On timeout the adapter deliberately does not call ComfyUI's global interrupt route, which could stop unrelated work.

### Manual or other workloads

Start the workload yourself and wait until it is ready to benchmark. Obtain prompt/generation throughput from the workload's own benchmark output, then keep the same workload running while the recorder observes the selected GPUs:

```powershell
.\benchmark\Record-WorkloadRun.ps1 `
  -WorkloadClass llama.cpp `
  -WorkloadName 'llama-bench tg128' `
  -Model 'Qwen example' `
  -Quantization 'Q4_K_M' `
  -Backend 'llama.cpp CUDA build <commit>' `
  -GpuIndexList '0,1' `
  -GenerationTokensPerSecond 21.2 `
  -WarmupSeconds 30 `
  -SampleSeconds 60 `
  -IntervalMilliseconds 1000 `
  -Repetition 1 `
  -OutputPath .\artifacts\runs\profile-a-r1.json
```

The generic recorder queries `nvidia-smi`; it does not launch the workload and cannot change the active profile. Profile selection remains an explicit, separate action. This separation keeps benchmark collection usable without administrator rights and prevents an analysis script from becoming a hardware actuator.

Use an `incomplete` or `failed` result instead of inventing throughput when the workload resets or does not finish:

```powershell
.\benchmark\Record-WorkloadRun.ps1 `
  -WorkloadClass llama.cpp `
  -WorkloadName 'llama-bench tg128' `
  -Model 'Qwen example' `
  -Quantization 'Q4_K_M' `
  -Backend 'llama.cpp CUDA build <commit>' `
  -GpuIndexList '0,1' `
  -ResultStatus failed `
  -ErrorMessage 'driver reset during repetition 2' `
  -WarmupSeconds 0 `
  -SampleSeconds 10 `
  -Repetition 2 `
  -OutputPath .\artifacts\runs\profile-a-r2-failed.json
```

## Gate persistent clock locks against idle power

A workload-efficient clock lock can still be a poor always-on setting if it prevents the board from returning to its normal idle state. Record at least three quiet, paired runs for the same cards and driver. Apply or reset the profile through a separately reviewed workflow; the recorder below is query-only and never changes the active profile.

First collect a vendor-auto baseline after the clocks have been reset and the desktop has settled:

```powershell
.\benchmark\Record-IdlePowerRun.ps1 `
  -Condition baseline `
  -ProfileLabel 'Vendor auto 350 W' `
  -ClockPolicy vendor-auto `
  -GpuIndexList '0,1' `
  -SettleSeconds 30 `
  -SampleSeconds 60 `
  -Repetition 1 `
  -OutputPath .\artifacts\idle\baseline-r1.json
```

Then, only after the user has explicitly applied the candidate elsewhere, record the persistent-lock condition:

```powershell
.\benchmark\Record-IdlePowerRun.ps1 `
  -Condition candidate `
  -ProfileLabel 'Locked 1700 MHz 280 W' `
  -ClockPolicy persistent-graphics-lock `
  -GraphicsClockMaximumMHz 1700 `
  -GpuIndexList '0,1' `
  -SettleSeconds 30 `
  -SampleSeconds 60 `
  -Repetition 1 `
  -OutputPath .\artifacts\idle\candidate-r1.json
```

Interleave the conditions where practical, increment `-Repetition`, and close GPU workloads during every sample window. Generate the gate report from all paired exports:

```powershell
$idleRuns = Get-ChildItem .\artifacts\idle\*.json | ForEach-Object FullName
.\benchmark\New-IdlePowerGateReport.ps1 `
  -InputPath $idleRuns `
  -OutputPath .\artifacts\idle-power-gate.md
```

The default gate requires three unique repetitions per condition, at least 30 seconds per run, complete board-power/utilization telemetry, mean utilization no higher than 5%, and p95 utilization no higher than 15%. Combined idle power must stay within both declared bounds (5 W and 10%), and every card must stay within both of its bounds (3 W and 15%); exceeding any one watt or percentage bound is enough to fail. Thresholds and per-GPU deltas are printed in the report.

Fixture data returns `FIXTURE`, never `PASS`. A live `PASS` exposes only `CanProceedPastIdleGate`; it is not a hardware-limit recommendation. Workload failures, clock stability, temperature, rollback, administrator elevation, and explicit confirmation remain separate gates. See [the rationale and threat model](../docs/research/IDLE_POWER_REGRESSION.md).

## Compare runs

```powershell
$runs = Get-ChildItem .\artifacts\runs\*.json | ForEach-Object FullName
.\benchmark\New-PowerCurveReport.ps1 -InputPath $runs -OutputPath .\artifacts\power-curve.md
```

The report compares only identical workload fingerprints (`class`, `name`, `model`, `quantization`, and `backend`). The adapters put their performance-affecting protocol settings in `name`, so unlike token counts, batches, or prompts are not ranked together. It identifies an efficiency leader only when power and rate windows align; otherwise it reports a rate/power index with the two windows visible. Every leader remains a candidate for repetition—not a universal best limit.

## Gate one workload candidate

The comparison report ranks evidence but does not authorize a profile. To evaluate one explicitly named candidate against one explicitly named reference, run:

```powershell
.\benchmark\New-WorkloadCandidateReport.ps1 `
  -InputPath $runs `
  -ReferenceProfile 'GPU0 350 W + GPU1 350 W' `
  -CandidateProfile 'GPU0 280 W + GPU1 280 W' `
  -ExpectedGraphicsClockMaximumMHz 1700 `
  -OutputPath .\artifacts\workload-candidate-gate.md
```

The default workload gate requires live schema-v3 evidence with aligned rate/power windows, one exact workload and hardware/driver identity, three unique repetitions per profile, and at least 30 seconds of complete power and temperature telemetry per run. The candidate must:

- retain at least 90% of reference throughput;
- improve the same-window efficiency metric by at least 5%;
- use less mean board power than the reference;
- stay at or below 85°C peak;
- provide at least three graphics-clock samples per GPU/run while utilization is at least 50%;
- keep the p05-to-p95 loaded-clock spread within 5%; and
- never exceed the declared graphics-clock ceiling by more than 30 MHz.

Any failed or incomplete selected run rejects the candidate. Errors mentioning a driver/GPU reset, device loss, or NVIDIA Xid also receive a dedicated `driver-reset-evidence` reason. Missing/short/mixed evidence fails as `INSUFFICIENT`; measured threshold or failure violations return `REJECTED`; synthetic data always returns `FIXTURE`. A live pass exposes only `CanProceedPastWorkloadGate` and still needs the idle-power, privilege, confirmation, and rollback gates.

Create a share card only from the exact run set used for the report:

```powershell
.\benchmark\New-PowerCurveCard.ps1 `
  -InputPath $runs `
  -OutputPath .\artifacts\power-curve.svg
```

Publish the card only beside the raw anonymized JSON and method. The card refuses mixed workload fingerprints, mixed live/fixture sources, mixed token/work-unit rates, mixed power/rate-window provenance, and datasets with fewer than two comparable power profiles. A repeated but phase-mismatched live curve is labeled **MEASURED / RATE-POWER INDEX**, never `/J`.

## Export schema and privacy

[`schema-v1.json`](schema-v1.json) remains supported for token workloads. [`schema-v2.json`](schema-v2.json) adds an explicit rate/unit pair for image and other non-token workloads. [`schema-v3.json`](schema-v3.json) is the current workload writer format and adds mandatory power/rate-window provenance. [`idle-schema-v1.json`](idle-schema-v1.json) is a separate paired-idle evidence contract; it cannot be passed off as workload evidence. All versions require explicit `null` values for missing throughput or telemetry; missing evidence never becomes zero. Before any report is produced, the modules reject fields named like UUID, hostname, user, path, command line, serial, or PCI bus ID—including common camelCase variants—and scan strings for common home/profile paths.

Review exports before posting. A model name or workload label that you type can still contain information you did not intend to share.
