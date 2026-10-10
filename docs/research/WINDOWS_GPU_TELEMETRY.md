# Windows GPU telemetry provider boundary

CA AutoConfig needs a standard-user fallback for AMD, Intel, and NVIDIA systems where `nvidia-smi` is absent. The fallback must not turn an ambiguous Windows counter into a confident per-card value.

This note defines what must be proven before a Windows/WDDM provider can enter the HUD. It is an implementation contract, not a claim that the provider already exists.

## Evidence and constraints

Microsoft documents GPU utilization and memory counters in the Windows performance-counter system, and recommends the performance counter consumer APIs for applications. Counter instances are supplied by Windows and drivers and must be enumerated rather than guessed. See [Using Performance Counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/using-performance-counters), [About Performance Counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters), and the GPU counters described in [PIX timing captures](https://learn.microsoft.com/en-us/windows/win32/direct3dtools/pix/articles/timing-captures/pix-timing-captures).

Those APIs do not make every value interchangeable:

- [`IDXGIFactory1::EnumAdapters1`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgifactory1-enumadapters1) enumerates adapters, while [`IDXGIAdapter1::GetDesc1`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiadapter1-getdesc1) returns the matching description, memory capacities, adapter LUID, and flags. The provider uses that LUID only as an in-memory join key and uses the documented software flag rather than guessing from a zero-valued counter.
- GPU-engine instances can represent different processes, engines, linked adapters, and physical adapter indices. Summing every engine percentage can exceed 100% and can silently mix cards.
- [`IDXGIAdapter3::QueryVideoMemoryInfo`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo) reports a memory budget and current usage visible to an application. It is not sufficient evidence by itself that the value equals Task Manager's whole-adapter dedicated-memory use.
- Microsoft documents incorrect or zero `GPU Process Memory` dedicated-memory values on affected Windows systems and recommends Task Manager Performance, WPR, or WPA for that case. See [GPU Process Memory counters report incorrect values](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/gpu-process-memory-counters-report-wrong-value).
- WDDM 2.x provides the underlying virtual-memory and scheduling model, but a driver-level structure is not automatically a stable application-level contract. See [GPU virtual memory in WDDM 2.0](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-virtual-memory-in-wddm-2-0).

On the maintainer's Windows 10 standard-user session, an initial 2026-10-10 shell inspection produced no usable set and `typeperf -qx GPU` returned a Performance Log Users/elevation error. A later run through the implemented capability and WMI paths exposed five `GPU*` sets and usable formatted classes without elevation. The differing results are retained because availability can vary by API, session, and counter state; every collection must preserve an explicit unavailable state rather than assume prior success.

## Provider contract

A Windows provider may enter production only when it can return these concepts without borrowing identity or values from another adapter:

| Field | Requirement |
| --- | --- |
| Provider | Explicit label such as `NVIDIA SMI` or `Windows WDDM`; never hidden |
| Adapter identity | Stable for one collection session and mapped to exactly one displayed adapter; raw LUID/PNP identifiers stay out of diagnostics |
| Name | Human-readable adapter name from the same mapped adapter |
| Load | Defined aggregation rule, bounded 0–100%, with the sampled engine set retained in tests |
| Dedicated memory | Used and capacity values from one documented source and scope; otherwise unknown |
| Power, temperature, clock | Unknown unless a read-only source proves the field for that exact adapter |
| Capability | Per-field supported/unsupported/error state, not zero-filled success |
| Freshness | Capture time and stale/error state for every snapshot |

The HUD must continue showing unknown/red when the provider cannot meet the contract. It must not:

- merge a WMI adapter name with counters whose LUID was not matched;
- label process memory as whole-card VRAM;
- sum unrelated engines or adapters into one percentage;
- infer CUDA support from an adapter name;
- request elevation, add the user to a local group, change performance-counter ACLs, or write a GPU setting;
- fall back from a failed full-fidelity NVIDIA sample to partial Windows data while still claiming the configured NVIDIA profile is verified.

## Implementation sequence

1. **Capability probe — implemented:** `Get-WindowsGpuCapability.ps1` enumerates available counter sets and video-controller names as a normal user. It returns only capability/status metadata and sanitized names, rejects raw identifier fields from fixtures, and can never authorize HUD use.
2. **Recorded mapping core — implemented:** the pure `WindowsGpuCounterMapper` joins DXGI inventory and counter rows by an internal normalized LUID/physical-adapter key. Fourteen deterministic cases cover duplicate model names, counter and adapter enumeration reorder, unknown/malformed identities, missing memory, duplicate identities, DXGI-flagged software adapters, provider failures, privacy-safe reporting, and process-aware busiest-engine aggregation. Fixture tests perform no hardware access and always keep `CanUseInHud=false`.
3. **Read-only live research provider and polling core — implemented, not connected to the HUD:** DXGI supplies the adapter description, LUID, software flag, and dedicated-memory capacity; Windows formatted GPU classes supply per-process engine samples and whole-adapter dedicated usage. The join key remains internal. The one-shot provider uses no shell command, network access, elevation, or hardware write and emits a sanitized schema-v1 JSON report. The coordinator requires two matching topology samples, tolerates row reorder, clears output after a mapping failure or stale deadline, requires revalidation after a topology/reset fingerprint change, and suppresses overlapping collections. Sustained live cadence/CPU evidence remains open.
4. **Cross-hardware validation:** require Windows 10 and 11 results covering AMD, Intel, NVIDIA, integrated/discrete, and at least one inaccessible-counter environment.
5. **HUD integration:** display the provider label and only supported fields. NVIDIA profile health remains an NVIDIA-specific state until equivalent identity and limit evidence exists.

## Minimum acceptance evidence

- deterministic tests prove that adapter reorder or a missing mapping cannot attach load/memory to the wrong card;
- unavailable, access-denied, stale, malformed, duplicate, and partial evidence fail closed;
- a standard-user live capture identifies the provider and field capabilities without exposing raw identifiers;
- CPU use and collection latency are measured over at least ten minutes with the normal two-second cadence;
- external reports cover at least three GPU families and retain failures;
- architecture, privacy, diagnostics, and hardware-matrix documents state the observed field scope.

Until those items exist, CA AutoConfig remains honest by reporting NVIDIA telemetry where supported and `unknown` elsewhere.

Run the first-stage probe without changing the HUD or hardware:

```powershell
.\Get-WindowsGpuCapability.ps1 | Format-List
```

`CanProceedToMappingValidation` means only that the machine exposes the inputs needed for the next research stage. `CanUseInHud` remains `false` until the mapping and cross-hardware evidence above exists.

From a current self-contained source build, write one sanitized live research report with:

```powershell
.\dist\desktop-win-x64-self-contained\CAAutoConfig.exe --windows-gpu-probe-result .\windows-gpu-probe.json
```

On the maintainer's dual-RTX-3090 system this returned two distinct hardware rows, matched engine and dedicated-memory counters, and excluded the DXGI-flagged software adapter. The report declared `MAPPING_AVAILABLE`, `CanUseInHud=false`, no raw adapter identifiers, and no hardware/network/elevation action. Ten additional hardware-independent polling/report cases cover stable-pair warm-up, reorder, topology change, failure, staleness, overlap, measurement counts, and output privacy. This is still one-machine evidence, not AMD/Intel or cross-Windows validation.

Current source builds can run a bounded cadence benchmark without touching the HUD:

```powershell
.\CAAutoConfig.exe `
  --windows-gpu-poll-result .\windows-gpu-poll.json `
  --windows-gpu-poll-seconds 600 `
  --windows-gpu-poll-ms 2000
```

The schema-v1 report contains normalized process CPU, elapsed time, completed/successful/unavailable collection counts, suppressed overlaps, last/maximum collection latency, final freshness/topology state, and the same sanitized adapter fields. Duration is constrained to 10–3600 seconds and cadence to 1000–60000 milliseconds. The command never adds the provider to the HUD and always writes `canUseInHud=false`.

The mapping core first sums process-scoped samples for the same physical engine, then uses the busiest engine percentage for the adapter. It does not sum 3D, copy, video, and compute engines together because parallel or shared-core engines can exceed 100% and misrepresent utilization. This follows the aggregation rationale documented by Microsoft's [DirectX team](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/). The live provider must prove that the same normalized key is obtained from DXGI and Windows performance counters within one sample before this result can enter the HUD.
