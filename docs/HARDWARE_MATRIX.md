# Hardware and workflow evidence matrix

This matrix separates live maintainer checks, deterministic fixtures, and external reproductions. A green row means only the listed behavior was observed under the listed conditions; it is not a universal compatibility or power-limit claim.

## Evidence levels

| Level | Meaning |
| --- | --- |
| Maintainer live | Observed on the maintainer workstation with the public code path and noted release. |
| Deterministic fixture | Parser, privacy, calculation, or failure behavior exercised without claiming real hardware performance. |
| External reproduced | A sanitized report from another person links the release, hardware, protocol, and retained failures. |

## Maintainer workstation

Last checked: 2026-10-10 with `v0.2.3-alpha.2`.

| Surface | Environment | Evidence | Result and boundary |
| --- | --- | --- | --- |
| Compiled HUD | Windows 10 Pro for Workstations 22H2, build 19045, x64 | Maintainer live | Self-contained app starts from Logon/SessionUnlock as a normal user; one process observed. |
| Display placement | Three displays: 3840×2160 at 200% primary, 1920×1080 at 100%, 1920×1080 at 125% | Maintainer live | Third enumerated display selected below the second at lower-left. Mixed resolution, mixed DPI, selection, startup, and session-unlock placement are covered on this topology only. |
| NVIDIA telemetry | 2× GeForce RTX 3090 24 GiB, driver 581.57 | Maintainer live | Both rows report load, VRAM, watts/cap, temperature, and graphics clock; missing/malformed sources are fixture-tested to remain unknown/red. |
| GPU profile identity | Same dual RTX 3090 system | Maintainer live + deterministic fixture | Apply/reset was exercised live; installed 280 W / 1700 MHz ceiling settles at 1695 MHz. Stable UUID targeting is used internally, but UUIDs are never published. Index reorder/replacement cases are deterministic fixtures. |
| Board power ranges | Card 0: 100/420/500 W min/default/max; card 1: 100/370/380 W | Maintainer live | These values demonstrate why limits cannot be universal. `280 W` is only this workstation's approved test profile. |
| Ollama adapter | Ollama 0.32.5, no installed model | Live boundary + deterministic fixture | Loopback/version and missing-model behavior verified; request/telemetry orchestration is fixture-tested. No throughput or efficiency result claimed. |
| llama.cpp adapter | No `llama-bench` on PATH and no user-approved GGUF input | Deterministic fixture | Exact official JSON pp/tg parsing, process telemetry, failure retention, and path omission pass. No hardware result claimed. |
| ComfyUI adapter | No listener on ports 8188/8189 and no supplied API workflow | Deterministic loopback fixture | Queue/history, seed-cache rejection, exact image count, schema-v2 image/J, failures, and redaction pass. No diffusion result claimed. |
| Presence experiment | Microsoft LifeCam Studio RGB webcam | Maintainer experiment only | Local RGB face matching is optional, spoofable, and separate from the default HUD. The device is not available as Windows Hello Face hardware. |

## External coverage

No external hardware reproduction has been accepted yet. That zero is intentional and remains visible until a report meets the evidence and privacy checklist.

| GPU family | Windows | Displays | HUD/telemetry | Workload curve | Reports |
| --- | --- | --- | --- | --- | ---: |
| NVIDIA RTX 20/40/50 series | Unverified | Unverified | Unverified | Unverified | 0 |
| NVIDIA workstation/datacenter | Unverified | Unverified | Unverified | Unverified | 0 |
| AMD | Unsupported in current alpha | — | WDDM/provider work open | — | 0 |
| Intel | Unsupported in current alpha | — | WDDM/provider work open | — | 0 |
| Windows 11 | Unverified externally | Unverified | Unverified | Unverified | 0 |

## Add a reproducible row

Choose one test in the [design-partner intake](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/discussions/9), use the [hardware-result form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=hardware-result.yml), or join [Discussions](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/discussions). Include the release, Windows build, GPU board/model and driver, display layout, exact public workload protocol, warm-up and repetition count, and every failure or reset. Attach schema-v1/v2 exports when relevant.

Remove usernames, machine names, GPU UUIDs, serials, personal paths, private prompts/workflows, tokens, and image content. Do not share a raw command if it contains private paths. Reports are reviewed before this table changes; stars are never a condition for inclusion.
