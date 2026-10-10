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

- Deterministic coverage and one low-load live browser run now prove the intended process lifecycle: a new nonzero engine fails only its first interval, recovers once an adjacent baseline exists, and disappears without leaving a stale row. Loaded inference/process churn still needs independent evidence.
- Repeat the 600-second result after sleep/resume and during a loaded local-AI workload; retain every intermediate failure.
- Loaded inference and image-generation runs must agree with an independent vendor source within a declared sampling tolerance.
- Sleep/resume, loaded process churn, driver reset, adapter reorder, and stale-data behavior need explicit system tests.
- External Windows 10/11 results must cover NVIDIA, AMD, Intel, integrated/discrete, a non-English display language, and an inaccessible-counter environment.
- Even a perfect single-host run keeps `CanUseInHud=false`; production promotion requires the broader contract above.
