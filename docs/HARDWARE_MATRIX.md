# Hardware and workflow evidence matrix

This matrix separates live maintainer checks, deterministic fixtures, and external reproductions. A green row means only the listed behavior was observed under the listed conditions; it is not a universal compatibility or power-limit claim.

## Evidence levels

| Level | Meaning |
| --- | --- |
| Maintainer live | Observed on the maintainer workstation with the public code path and noted release. |
| Deterministic fixture | Parser, privacy, calculation, or failure behavior exercised without claiming real hardware performance. |
| External reproduced | A sanitized report from another person links the release, hardware, protocol, and retained failures. |

## Maintainer workstation

Last live read-only hardware check: 2026-10-10 with the `v0.2.6-alpha.4` candidate. The compiled-helper mutation path remains deterministic-fixture evidence only until an explicitly approved migration test is recorded.

| Surface | Environment | Evidence | Result and boundary |
| --- | --- | --- | --- |
| Compiled HUD | Windows 10 Pro for Workstations 22H2, build 19045, x64 | Maintainer live | Self-contained app starts from Logon/SessionUnlock as a normal user; one process observed. |
| Display placement | Three displays: 3840×2160 at 200%, 1920×1080 at 100%, 1920×1080 at 125% | Maintainer live | The 125% display physically below the second is selected at lower-left. A packaged PowerShell 5.1 reinstall preserved its attached `DISPLAY7` target despite enumeration-order changes. Coverage remains limited to this topology. |
| NVIDIA telemetry | 2× GeForce RTX 3090 24 GiB, driver 581.57 | Maintainer live | Both rows report load, VRAM, watts/cap, temperature, and graphics clock; missing/malformed sources are fixture-tested to remain unknown/red. |
| Windows GPU capability probe | 2× GeForce RTX 3090, Windows 10 build 19045 | Maintainer live, query only (unreleased) + deterministic fixture | Five `GPU*` counter sets, engine and memory counter families, and two sanitized controller rows were observed. The probe reports `CanProceedToMappingValidation=true` but deliberately keeps `CanUseInHud=false`; no per-adapter mapping or AMD/Intel support is claimed. Seven fixture cases pass in both PowerShell runtimes. |
| Windows GPU counter mapping | Same dual RTX 3090 system + synthetic same-name inventory | Maintainer live, query only (`v0.2.6-alpha.4` + unreleased PDH source) + deterministic compiled fixture | The one-shot probe joined both DXGI hardware adapters and excluded the software adapter. Thirty-eight compiled mapping/provider/report/polling cases pass without hardware access. The formatted-WMI 600-second run used 0.264% normalized process CPU but had 283/299 successful mappings, 16 unavailable samples, 2 overlaps, and 3210 ms maximum latency; schema v2 isolated `engine-counter-out-of-range`. The first native-PDH run had 259/300 full mappings and 41 invalid-engine failures. The [field-isolated schema-v3 run](evidence/windows-gpu-pdh-fields-600s-2026-10-10.json) separated 285 full and 15 partial mappings. The subsequent [persistent-query run](evidence/windows-gpu-pdh-persistent-600s-2026-10-10.json) reached 292 full and 8 partial mappings, 0 fully unavailable and 0 overlaps; VRAM passed 300/300, engine load failed at 292/300, final latency was 10 ms, maximum including first warm-up was 1588 ms, and normalized CPU was 0.023%. Final zero load and sorted VRAM values matched `nvidia-smi` after accounting for DXGI/NVML order. `CanUseInHud=false`; no AMD/Intel or external validation is claimed. |
| GPU profile identity | Same dual RTX 3090 system | Maintainer live + deterministic fixture | Apply/reset was exercised live; installed 280 W / 1700 MHz ceiling settles at 1695 MHz. Stable UUID targeting is used internally, but UUIDs are never published. Index reorder/replacement cases are deterministic fixtures. |
| Read-only GPU limit plan | Same dual RTX 3090 system | Maintainer live, query only (`v0.2.6-alpha.2` candidate) | 280 W / 1700 MHz passes the independent profile checks, while the installed legacy applied state correctly returns `legacy-reset-required` and blocks installation. The result contains no UUID and reports `HardwareWrites=false`; no reset, migration, or mutation was performed. |
| GPU plan policy | Synthetic mixed-board inventory | Deterministic fixture (`v0.2.6-alpha.2`) | Seven cases cover inventory-only output, a shared no-raise power starting point, range/max-clock rejection, explicit acknowledgement before raising a current cap, complete-profile enforcement, and absence of mutation/elevation. Fixture output cannot authorize installation. |
| Transactional compiled helper | Fake NVIDIA command runner, protected temporary state | Deterministic fixture (`v0.2.6-alpha.2`) | Ten cases cover strict command parsing, all-target preflight, vendor max-clock/current-cap enforcement, exact pre-apply backup, Apply rollback, Reset, failed-Reset recovery, corrupt-record rejection, and profile-mismatch refusal. No live migration or GPU mutation claimed. |
| Offline release verifier | Synthetic ZIP fixtures plus the `v0.2.6-alpha.4` candidate | Deterministic fixture + candidate-asset read | Nine failure/success cases pass in both PowerShell runtimes. The 47-file candidate verifies at SHA-256 `0a71a120…b32f3b6d` without extraction, execution, network access, or hardware writes. |
| Clean-machine harness | Synthetic package plus generated `v0.2.6-alpha.4` `.wsb` policy | Deterministic fixture + candidate preparation | Five preparation cases pass in both PowerShell runtimes. The candidate config was prepared with network, vGPU, clipboard and device redirection disabled; input is read-only and only the evidence directory is writable. It was not launched because Windows Sandbox is unavailable on the maintainer host. |
| Board power ranges | Card 0: 100/420/500 W min/default/max; card 1: 100/370/380 W | Maintainer live | These values demonstrate why limits cannot be universal. `280 W` is only this workstation's approved test profile. |
| Ollama adapter | Ollama 0.32.5, no installed model | Live boundary + deterministic fixture | Loopback/version and missing-model behavior verified; request/telemetry orchestration is fixture-tested. No throughput or efficiency result claimed. |
| llama.cpp adapter | No `llama-bench` on PATH and no user-approved GGUF input | Deterministic fixture | Exact official JSON pp/tg parsing, process telemetry, failure retention, and path omission pass. No hardware result claimed. |
| ComfyUI adapter | No listener on ports 8188/8189 and no supplied API workflow | Deterministic loopback fixture | Queue/history, seed-cache rejection, exact image count, schema-v3 aligned client-window image/J, failures, and redaction pass. No diffusion result claimed. |
| Idle-power regression gate | Synthetic paired dual-3090 baseline/candidate evidence | Deterministic fixture | Three repetitions per condition, aggregate/per-GPU deltas, busy/missing/failed/mixed evidence rejection, and permanent fixture non-authorization pass. No live idle result or clock recommendation claimed. |
| Workload candidate gate | Synthetic repeated dual-3090 reference/candidate evidence | Deterministic fixture | Phase alignment, throughput retention, efficiency gain, temperature, loaded-clock stability/ceiling, driver-reset/failure/incomplete/missing/mixed rejection, and permanent fixture non-authorization pass. No real workload result or profile recommendation claimed. |
| Presence experiment | Microsoft LifeCam Studio RGB webcam | Maintainer experiment only | Local RGB face matching is optional, spoofable, and separate from the default HUD. The device is not available as Windows Hello Face hardware. |

## External coverage

No external hardware reproduction has been accepted yet. That zero is intentional and remains visible until a report meets the evidence and privacy checklist.

| GPU family | Windows | Displays | HUD/telemetry | Workload curve | Reports |
| --- | --- | --- | --- | --- | ---: |
| NVIDIA RTX 20/40/50 series | Unverified | Unverified | Unverified | Unverified | 0 |
| NVIDIA workstation/datacenter | Unverified | Unverified | Unverified | Unverified | 0 |
| AMD | Unsupported in current alpha | — | [WDDM/provider contract](research/WINDOWS_GPU_TELEMETRY.md) open | — | 0 |
| Intel | Unsupported in current alpha | — | [WDDM/provider contract](research/WINDOWS_GPU_TELEMETRY.md) open | — | 0 |
| Windows 11 | Unverified externally | Unverified | Unverified | Unverified | 0 |

## Add a reproducible row

Choose one test in the [design-partner intake](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/discussions/9), use the [workload hardware form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=hardware-result.yml), submit a [Windows GPU telemetry result](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=windows-gpu-result.yml), submit a disposable install through the [clean-machine form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=clean-machine-result.yml), or join [Discussions](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/discussions). Include the release, Windows build and display language, GPU board/model and driver, display layout, exact public workload protocol, warm-up and repetition count, and every failure or reset. Attach schema-v1/v2/v3 workload exports and idle-schema-v1 paired exports when relevant; only schema-v3 can prove workload phase alignment, and only live paired idle evidence can pass the idle gate.

Remove usernames, machine names, GPU UUIDs, serials, personal paths, private prompts/workflows, tokens, and image content. Do not share a raw command if it contains private paths. Reports are reviewed before this table changes; stars are never a condition for inclusion.
