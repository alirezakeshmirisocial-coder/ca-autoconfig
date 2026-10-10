# Raw PDH GPU Engine experiment

This note describes a read-only experiment, not a production telemetry claim. CA AutoConfig's formatted native-PDH path still retained six invalid/out-of-range engine collections in a 300-collection run, even though dedicated memory passed 300/300. The raw experiment asks a narrower question: can explicitly matching adjacent raw wildcard samples avoid PDH's implicit instance matching failures without inventing a plausible zero?

## Why raw samples may help

Microsoft documents that PDH normally manages instance matching and formatted-value calculation, that rate counters need two samples, and that consumers may instead retain [`PDH_RAW_COUNTER`](https://learn.microsoft.com/en-us/windows/win32/api/pdh/ns-pdh-pdh_raw_counter) values and call [`PdhCalculateCounterFromRawValue`](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhcalculatecounterfromrawvalue). It also warns that instance names are not always unique and their occurrence indexes can move between samples. See [About performance counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters) and [Handling duplicate instance names](https://learn.microsoft.com/en-us/windows/win32/perfctrs/handling-duplicate-instance-names).

The `GPU Engine` instance names observed here contain process, adapter, physical-adapter, and engine identity. Those strings are useful for an in-memory join but are privacy-sensitive and never enter a public report.

## Fail-closed algorithm

The explicit `pdh-raw` provider:

1. Opens one native PDH query and verifies that `GPU Engine\Utilization Percentage` is exactly the `Timer100Ns` counter type (`0x20510500`). Any other type is unsupported rather than guessed.
2. Collects one baseline raw wildcard array, waits one second, then collects the current array. Bounded polling retains each current raw set as the next baseline.
3. Groups duplicate full instance identities only when their timestamp, denominator, and `MultiCount` metadata are identical. It sums only their active-time numerator, making the operation independent of duplicate ordering. Any metadata disagreement fails that identity.
4. Matches the same full identity across adjacent samples and asks PDH to calculate the uncapped display value from the current and older raw structures.
5. Treats a new nonzero instance, invalid raw/formatted status, failed native calculation, negative/out-of-range result, or incompatible duplicate as an adapter-scoped failure.
6. Treats a new zero-numerator instance as zero only when the prior collection has one common timebase. With a zero active-time delta, the native `Timer100Ns` result is provably zero; this shortcut is disabled for every other counter type or ambiguous timebase.
7. Aggregates process contexts for the same physical engine, then reports the busiest engine for the adapter. It does not sum independent 3D/copy/video/compute engines.

The public schema-v3 report contains only adapter index/name, supported field values, sanitized reason codes, cadence/timing/CPU counts, and explicit safety flags. It does not contain raw instance names, LUIDs, PIDs, PNP identifiers, user or machine names, paths, commands, prompts, or content.

## What failed before the guarded aggregation

The first raw implementation required every raw array item name to be unique. A live one-shot and 60-second run showed duplicate full identities on both RTX 3090 adapters. The sustained run therefore produced 0/30 engine-valid collections and 30/30 memory-valid collections. Guessing an occurrence index was rejected because Microsoft documents that duplicate ordering can change.

After grouping only duplicates with identical timing metadata and proving the zero-new-instance case, a one-shot mapped both adapters and a 60-second run completed 30/30 full mappings with zero partial, unavailable, or overlapping collections. Normalized process CPU was 0.063%; the first warm-up dominated the 1637 ms maximum latency, while the final collection took 9 ms.

The required [600-second sanitized run](../evidence/windows-gpu-pdh-raw-600s-2026-10-10.json) then completed 300/300 full mappings, with 300/300 engine-valid and memory-valid collections, zero partial/unavailable/overlap collections, 7 ms final latency, 1587 ms maximum including warm-up, and 0.021% normalized CPU. Its repository SHA-256 is `96d9f1df738ba9d1af0822f808a346912eb43b0ae24a5628c4e9eaf9df7195f4`. Final zero load and sorted dedicated-memory values agreed with a contemporaneous read-only `nvidia-smi` query within sampling delay. This is still idle single-host evidence, not a production claim.

## Live process-churn result

The bounded [`Invoke-WindowsGpuChurnValidation.ps1`](../../tools/Invoke-WindowsGpuChurnValidation.ps1) harness starts the explicit raw provider, waits for its baseline, then opens only the repository's local WebGL fixture in a fresh headless Edge/Chrome profile. It discovers and later stops only processes whose executable and unique temporary-profile token both match. Process-scoped Windows counters are used only to prove the fixture rendered on a GPU; PID-bearing instance names never enter either output. The browser profile is removed only after its resolved path is rechecked under the system temporary directory with the dedicated `ca-gpu-churn-*` prefix.

The [60-second schema-v3 polling report](../evidence/windows-gpu-pdh-raw-churn-60s-2026-10-10.json) and [linked sanitized churn summary](../evidence/windows-gpu-pdh-raw-churn-summary-60s-2026-10-10.json) observed the browser process plus two positive process-specific GPU-counter samples, with a 1.452% maximum. The separately sampled whole-card `nvidia-smi` integer percentage remained 0; it is optional corroboration, not the proof of browser activity. The provider completed 29/30 full mappings, retained exactly one `pdh-engine-baseline-missing` partial for adapter 0 when the process appeared, kept dedicated memory valid 30/30, and recorded zero unavailable collections or overlaps. The next interval recovered and the stopped process left no stale row. Because the run retained one engine failure, `engineLoadReadyForValidation` and overall readiness stayed false even though the final state was healthy. This is the intended fail-closed boundary.

## Link a loaded inference window

[`New-WindowsGpuLoadedValidationSummary.ps1`](../../tools/New-WindowsGpuLoadedValidationSummary.ps1) is an offline gate for two already-created evidence files. It does not launch a model or collect telemetry. Run a schema-v3 workload adapter and the explicit raw-PDH polling command concurrently, then link the two files:

```powershell
.\tools\New-WindowsGpuLoadedValidationSummary.ps1 `
  -WindowsReportPath .\windows-gpu-pdh-raw-loaded.json `
  -WorkloadRunPath .\ollama-run.json `
  -OutputPath .\windows-gpu-loaded-link.json `
  -MinimumLoadedUtilizationPercent 50 `
  -MinimumLoadedSamplePercent 50 `
  -MinimumOverlapSeconds 10
```

The gate requires a `live` passed workload run with explicit `measurement.startedUtc`/`endedUtc`, at least 95% workload-window coverage, the declared minimum overlap, valid utilization in every sample, threshold load in at least the declared share of samples on every workload GPU, internally consistent Windows counts, zero unavailable or overlapping collections, and complete engine/memory evidence. A lone utilization spike therefore cannot qualify as loaded inference. It rejects private schema flags, a duration that disagrees with `protocol.sampleSeconds`, and input/output collisions. The summary contains hashes and aggregate windows/load only—not input filenames, workload identity, model/run ID, prompts, paths, commands, raw adapter identities, or process IDs.

`READY_FOR_MANUAL_VALUE_COMPARISON` is intentionally not a validation claim. A reviewer must still compare the time-aligned Windows values with an independent vendor source using a declared tolerance, retain every discrepancy, and reproduce across hardware/lifecycle cases. The summary always emits `valuesCompared=false`, `promotionAuthorized=false`, and `canUseInHud=false`.

The maintainer host had Ollama available but no installed models, and no identified local llama.cpp or ComfyUI model input. No model was downloaded to manufacture a result. Therefore this repository currently includes deterministic fixture validation of the linker, not loaded-inference evidence.

## Manual sleep/resume lane

After a current self-contained source build, start the bounded lifecycle harness as a standard user:

```powershell
.\tools\Invoke-WindowsGpuSleepResumeValidation.ps1 `
  -DurationSeconds 300 `
  -PollMilliseconds 2000 `
  -MinimumPreSleepSeconds 10 `
  -MinimumPostWakeSeconds 10 `
  -ResultPath .\windows-gpu-pdh-raw-sleep-resume.json
```

The harness starts only the explicit `pdh-raw` collector in a hidden child process. It tells the tester when to put Windows to sleep manually, waits for the bounded collector, then reads new `Microsoft-Windows-Power-Troubleshooter` event ID 1 records. It never calls a suspend API or utility, changes a power plan, touches GPU controls, requests elevation, or uses the network.

The separate `.sleep-resume-summary.json` hashes the untouched polling report and keeps only sanitized sleep/wake timestamps plus aggregate collection counts. Computer/user identity, event record ID, wake source, raw event XML, file paths, and raw adapter identifiers are omitted. Exactly one event must fall inside the observed wall-clock collection window with the requested awake margin on both sides. Missing/multiple/out-of-window events and every partial, unavailable, or overlapped provider collection remain explicit failures.

Even `READY_FOR_MANUAL_SLEEP_RESUME_REVIEW` sets `promotionAuthorized=false` and `canUseInHud=false`. The [120-second no-sleep control report](../evidence/windows-gpu-pdh-raw-no-resume-control-120s-2026-10-10.json) and [linked summary](../evidence/windows-gpu-pdh-raw-no-resume-control-summary-120s-2026-10-10.json) verified the negative path: the event log was readable, zero new resume events produced `NO_RESUME_OBSERVED`, and the provider still completed 61/61 full engine/memory collections with no partial, unavailable, or overlapping collection. The repository report SHA-256 is `1d4a227d9de9b37e7abbd0372d15d7296e1628779199acf8759b1ce3ee20f963`; the linked summary SHA-256 is `c971476afcbcb240098a7d3e823f2cedc4c28b7f56d16a564b4fe3378f6e9a69`. No live sleep was initiated, so actual lifecycle compatibility is still unproven.

## Reproduce without enabling the HUD

From a current source build:

```powershell
.\CAAutoConfig.exe `
  --windows-gpu-poll-result .\windows-gpu-pdh-raw.json `
  --windows-gpu-poll-seconds 600 `
  --windows-gpu-poll-ms 2000 `
  --windows-gpu-provider pdh-raw
```

The command performs no hardware write, elevation, network access, provider fallback, background installation, or HUD integration. Review the JSON before sharing it. Submit complete sanitized results through the [Windows GPU result form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=windows-gpu-result.yml); failures are useful evidence and a star is neither required nor requested.

To reproduce the low-load lifecycle test with a locally installed Edge or Chrome and the self-contained source build:

```powershell
.\tools\Invoke-WindowsGpuChurnValidation.ps1 `
  -DurationSeconds 60 `
  -PollMilliseconds 2000 `
  -ChurnStartSeconds 10 `
  -ChurnSeconds 20 `
  -ResultPath .\windows-gpu-pdh-raw-churn.json
```

The harness writes the untouched polling report plus a separate `.churn-summary.json` that contains only the browser product/version, sanitized aggregate proof, report hash, and safety flags. It deliberately omits even the user-selected report filename. Inspect both before sharing. A `CHURN_NOT_PROVEN` result is valid negative evidence; do not retry with elevation or weaken browser isolation.

## Remaining proof

- Deterministic coverage and one low-load live browser run now prove the intended process lifecycle: a new nonzero engine fails only its first interval, recovers once an adjacent baseline exists, and disappears without leaving a stale row. The offline linker is ready, but loaded inference/process churn still needs a real local model input and independent evidence.
- Run the prepared manual sleep/resume lane and the loaded local-AI workflow on real hardware; retain every intermediate failure.
- Loaded inference and image-generation runs must agree with an independent vendor source within a declared sampling tolerance.
- Sleep/resume, loaded process churn, driver reset, adapter reorder, and stale-data behavior need explicit system tests.
- External Windows 10/11 results must cover NVIDIA, AMD, Intel, integrated/discrete, a non-English display language, and an inaccessible-counter environment.
- Even a perfect single-host run keeps `CanUseInHud=false`; production promotion requires the broader contract above.
