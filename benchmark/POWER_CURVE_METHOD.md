# Read-only AI power-curve lab

This lab records NVIDIA board telemetry beside throughput that you measured from a real AI workload. It does not set a power limit, clock, voltage, or fan value. Every exported run omits GPU UUIDs, machine/user names, file paths, and raw commands.

The included fixtures are synthetic test data. They demonstrate the pipeline and must never be presented as hardware results.

## Why the protocol is strict

A single “tokens per second at 280 W” number is not portable. Prompt processing and token generation stress different parts of a GPU; board/VBIOS limits differ; a hot second run is not comparable to a cold first run; partial CPU offload changes both throughput and whole-system energy.

For a publishable curve:

1. Freeze the model, quantization, context, batch size, GPU split, backend build/commit, driver, and workload input.
2. Record prompt-processing and generation throughput separately whenever the backend exposes both.
3. Warm up for at least 30 seconds, then sample a steady window for at least 60 seconds.
4. Run at least three repetitions per profile. Interleave or randomize profile order and allow temperatures to return near the same baseline.
5. Record every failed, incomplete, throttled, or reset run. Do not discard it because it weakens the curve.
6. Use generation tokens/Joule (`tokens/s ÷ mean board watts`) only for like-for-like runs. Add wall-meter watt-hours when making electricity-cost claims.
7. Publish the raw anonymized JSON beside the summary and describe anything the schema does not capture.

## Dry run

The dry run analyzes two synthetic dual-3090 fixtures and writes a Markdown report:

```powershell
.\benchmark\New-PowerCurveReport.ps1 -DryRun -OutputPath .\artifacts\fixture-power-curve.md
```

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

`BenchmarkId` is a non-sensitive identifier for the exact prompt/protocol. Keep it unchanged only when the prompt and workload are unchanged. The raw prompt and generated response are used in memory but are never written to the schema-v1 export. Model quantization comes from `/api/show`; prompt and generation rates come from Ollama's `prompt_eval_*` and `eval_*` counters. Cached prompt tokens are excluded from prompt throughput. See the official [generate-response fields](https://docs.ollama.com/api/generate) and [model-details endpoint](https://docs.ollama.com/api-reference/show-model-details).

The adapter does not pull models or change GPU settings. It records a run as `incomplete` when generation ends before the default ten-second measurement window, and as `failed` when the measured request or its metrics fail. Local loopback is the default; a non-loopback endpoint requires `-AllowRemoteEndpoint` because it sends the supplied prompt to that server. Apply each candidate power profile through the separate reviewed workflow, then record at least three interleaved repetitions per profile.

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

## Compare runs

```powershell
$runs = Get-ChildItem .\artifacts\runs\*.json | ForEach-Object FullName
.\benchmark\New-PowerCurveReport.ps1 -InputPath $runs -OutputPath .\artifacts\power-curve.md
```

The report compares only identical workload fingerprints (`class`, `model`, `quantization`, and `backend`). It may identify the most efficient measured profile inside that group, but it always labels the result as a candidate for repetition—not a universal best limit.

## Export schema and privacy

[`schema-v1.json`](schema-v1.json) requires explicit `null` values for missing throughput or telemetry. Missing evidence never becomes zero. Before any report is produced, the module rejects fields named like UUID, hostname, user, path, command line, serial, or PCI bus ID and scans strings for common home/profile paths.

Review exports before posting. A model name or workload label that you type can still contain information you did not intend to share.
