# Windows GPU telemetry provider boundary

CA AutoConfig needs a standard-user fallback for AMD, Intel, and NVIDIA systems where `nvidia-smi` is absent. The fallback must not turn an ambiguous Windows counter into a confident per-card value.

This note defines what must be proven before a Windows/WDDM provider can enter the HUD. It is an implementation contract, not a claim that the provider already exists.

## Evidence and constraints

Microsoft documents GPU utilization and memory counters in the Windows performance-counter system, and recommends the performance counter consumer APIs for applications. Counter instances are supplied by Windows and drivers and must be enumerated rather than guessed. See [Using Performance Counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/using-performance-counters), [About Performance Counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters), and the GPU counters described in [PIX timing captures](https://learn.microsoft.com/en-us/windows/win32/direct3dtools/pix/articles/timing-captures/pix-timing-captures).

Those APIs do not make every value interchangeable:

- GPU-engine instances can represent different processes, engines, linked adapters, and physical adapter indices. Summing every engine percentage can exceed 100% and can silently mix cards.
- [`IDXGIAdapter3::QueryVideoMemoryInfo`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo) reports a memory budget and current usage visible to an application. It is not sufficient evidence by itself that the value equals Task Manager's whole-adapter dedicated-memory use.
- Microsoft documents incorrect or zero `GPU Process Memory` dedicated-memory values on affected Windows systems and recommends Task Manager Performance, WPR, or WPA for that case. See [GPU Process Memory counters report incorrect values](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/gpu-process-memory-counters-report-wrong-value).
- WDDM 2.x provides the underlying virtual-memory and scheduling model, but a driver-level structure is not automatically a stable application-level contract. See [GPU virtual memory in WDDM 2.0](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-virtual-memory-in-wddm-2-0).

On the maintainer's Windows 10 standard-user session, a 2026-10-10 query for `GPU*` counter sets produced no usable set, and `typeperf -qx GPU` returned the documented Performance Log Users/elevation error. This was a read-only capability check. It means a PDH-only implementation would fail on at least one otherwise supported CA AutoConfig installation unless it preserves an explicit unavailable state.

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

1. **Capability probe:** enumerate available counter sets and adapter identities as a normal user. Return only capability/status metadata and sanitized adapter names.
2. **Recorded provider:** define deterministic multi-adapter fixtures for enumeration reorder, duplicate engine names, inaccessible counters, missing memory, integrated plus discrete graphics, and driver reset.
3. **Read-only live provider:** sample without shell commands, network access, elevation, persistence, or hardware writes. Keep the existing two-second collector overlap guard.
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
