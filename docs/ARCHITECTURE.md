# CA AutoConfig architecture

CA AutoConfig separates an always-on, standard-user HUD from the one optional operation that needs administrator rights: applying explicit NVIDIA limits. Camera experiments and the unlock guard are separate opt-in tools; neither is installed by the desktop-preview installer.

This document describes the current `v0.2` architecture and the safety boundaries contributors must preserve.

## Runtime map

```mermaid
flowchart LR
    subgraph session[Standard user session]
        app[CAAutoConfig.exe<br/>WinForms HUD, tray, settings]
        config[settings.json<br/>display, position, opacity, hotkey]
        ipc[Named event<br/>open settings]
        app <--> config
        ipc --> app
    end

    displays[Windows display topology] -->|read| app
    smi[nvidia-smi] -->|read-only query every 2 s| app
    state[gpu-limits-state.json] -->|read and verify| app
    scheduler[Task Scheduler<br/>Logon + SessionUnlock] -->|launch, Limited| app
```

The desktop process is single-instance per user session through the `Local\CA-SystemOverlay` mutex. A second invocation with `--open-settings` signals `Local\CA-SystemOverlay-OpenSettings` and exits instead of creating another HUD.

The metrics collector runs off the UI thread and suppresses overlapping collections. Its normal interval is two seconds. NVIDIA access is behind an internal telemetry-source boundary: production uses a process-backed `nvidia-smi` source, while tests inject a deterministic recorded source with no process or hardware access. Missing, timed-out, failed, empty, partial, malformed, and explicit-`N/A` responses have separate fail-closed outcomes. The app reads Windows CPU, memory, disk, and monitor data plus NVIDIA telemetry; it contains no network client and does not write GPU settings. An explicit **Copy diagnostics** click assembles a sanitized report and writes it only to the local clipboard.

## HUD interaction model

The overlay starts locked. In that state only the small lock rectangle accepts pointer input; the rest of the window returns click-through hit-test results. Unlocking enables drag and right-click settings. The configured global shortcut performs the same state change.

Monitor selection stores the Windows display device name and a per-display position. If that display disappears, the HUD does not silently jump to another monitor. Per-monitor-v2 DPI awareness is enabled before WinForms creates a window, so the same logical layout is scaled by the target display rather than by the primary monitor.

Settings live at:

```text
%LOCALAPPDATA%\CAAutoConfig\settings.json
```

The file has a schema version. Older unversioned settings migrate forward; if the app finds a newer schema, it uses safe defaults for the session and refuses to overwrite the file.

## Read-only power advisor

The HUD asks `nvidia-smi` for each card's current draw, active cap, default cap, supported minimum/maximum, temperature, graphics clock, CUDA/SM load, and VRAM use. The advisor may display a conservative benchmark starting point, but it cannot apply it.

Current invariants:

- A suggested power cap stays inside the range reported by the driver.
- It never raises an already lower active cap.
- It is labeled as a starting point, not a board-independent recommendation.
- Applying a cap remains a separate, explicit, elevated workflow.

Workload-aware recommendations require measured throughput and stability evidence and remain roadmap work.

## Optional privileged GPU path

```mermaid
sequenceDiagram
    actor User
    participant Plan as Get-GpuLimitPlan.ps1
    participant Installer as Install-GpuLimits.ps1
    participant UAC as Windows UAC
    participant Tasks as Fixed Apply/Reset tasks (SYSTEM)
    participant Helper as Compiled strict-command helper
    participant Driver as nvidia-smi / NVIDIA driver
    participant State as State + log files
    participant HUD as Standard-user HUD

    User->>Plan: Explicit GPU indices and proposed MHz/watts
    Plan->>Driver: Query ranges, defaults, current caps, and max clocks
    Plan-->>User: Privacy-safe plan and migration gate (no writes, no UUIDs)
    User->>Installer: Accepted plan and hardware-risk acknowledgement
    Installer->>Plan: Re-run the same read-only checks before UAC
    Installer->>Driver: Resolve selected indices to stable UUIDs (read only)
    Installer->>UAC: Request elevation
    UAC-->>Installer: Administrator-approved process
    Installer->>Installer: Pin helper SHA-256 across UAC
    Installer->>Tasks: Install reviewed fixed commands and ACLs
    Tasks->>Helper: Run apply after logon or reset on demand
    Helper->>Driver: Preflight every UUID-pinned target
    Helper->>State: Atomically save exact pre-apply values
    Helper->>Driver: Apply power cap, then clock ceiling
    Helper->>Driver: Read back live values
    Helper->>State: Write applied/failed result and rollback report
    HUD->>State: Read expected profile
    HUD->>Driver: Compare with live values
```

Installation requires all of these inputs: GPU indices, maximum graphics clock, power limit, and `-AcceptHardwareRisk`. Before UAC, `Get-GpuLimitPlan.ps1` checks every selected board's current/default/minimum/maximum power limits, vendor maximum graphics clock, and installed-profile migration state. It emits no UUIDs and contains no mutation or elevation path. A shared power value may be shown only as a conservative no-raise benchmark starting point; the clock suggestion is deliberately blank until workload evidence exists. Any proposed increase over a current power cap also requires `-AcknowledgePowerIncrease`.

Numeric indices select the cards once; after the plan passes, the installer resolves them through another read-only NVIDIA query and carries their validated UUIDs into the protected task. The compiled helper hash is pinned before elevation and checked again before and after staging. Its command parser accepts only one exact Apply grammar or the argument-free Reset command, and process arguments go directly to the fixed System32 `nvidia-smi.exe` without a shell.

Every UUID-pinned target is preflighted again inside the privileged helper before any card is changed. That independent boundary enforces the vendor power range/default, vendor-reported maximum graphics clock, and the explicit `--allow-power-increase` flag embedded in the reviewed fixed task when a current cap would rise. Before mutation, Apply atomically records the exact prior power cap for every target in the protected directory. If a later operation fails, it makes a reverse-order rollback against the same UUIDs. The separate fixed Reset task reads only that protected record, restores exact prior power caps and vendor-managed graphics clocks, and verifies the result. If reset fails partway, it attempts to restore the previously applied profile so cards do not silently remain in a mixed state.

The installed source and state are under:

```text
%ProgramData%\CAGpuLimits\
```

That directory is administrator-owned and rejects reparse-point installation. SYSTEM and Administrators receive full control; standard Users receive read and execute access. Both tasks run as SYSTEM, but their descriptors grant only the configured user read/run access, not permission to rewrite either action. The control panel starts those exact reviewed tasks and waits for fresh state; it has no direct `-pl`, `-lgc`, or `-rgc` path. Manual Apply and Reset require explicit confirmation. This lets the configured user inspect, stop, start, and roll back the approved profile without turning the UI into a general elevation path.

The HUD's green GPU indicator is not based on the state file alone. It requires a successful state from the current boot, the same configured profile across the expected UUIDs, matching live power caps, and graphics clocks that do not exceed the ceiling beyond a small telemetry tolerance. A driver/reboot index reorder is accepted only when UUID identity still matches; a different card at an old index stays red. Missing, stale, failed, or mismatched evidence also stays red. Index-only state from older releases remains readable so upgrades fail safely without an unnecessary outage.

## Optional experiments stay outside the default install

```mermaid
flowchart TB
    default[Desktop preview installer] --> hud[HUD only]
    combined[Combined installer with explicit flags] --> hud
    combined -->|InstallGpuLimits| gpu[Privileged GPU helper]
    combined -->|InstallPresenceMonitor| presence[Camera presence monitor]
    manual[Separate guard installer] --> guard[Unlock guard]

    ollama[Local Ollama adapter] --> curve[Anonymized power-curve run]
    llamabench[Local llama-bench process] --> curve
    comfy[Local ComfyUI API workflow] --> curve
    smi2[nvidia-smi query only] --> curve
    lab[Adaptive cooling lab] --> advice[Deterministic advice only<br/>CanApply = false]
    advice -. no actuator .-> gpu
```

- The presence lab performs local enrollment and inference. Its SFace path stores embeddings, not raw camera frames, and its test mode never locks Windows.
- The unlock guard can relock Windows after a failed challenge, but it is a separate installation and is not a replacement for Windows Hello, BitLocker, or operating-system access control.
- The Ollama adapter sends a user-supplied prompt to loopback by default, samples NVIDIA telemetry during that request, and exports neither prompt nor generated text. Schema-v3 distinguishes request-window power from prompt/generation phase rates, so the result cannot be mislabeled tokens/J. Remote endpoints require an explicit flag. It cannot pull models, elevate, or change a GPU profile.
- The llama.cpp adapter launches only explicit local inputs, validates the exact official JSON `pp`/`tg` result shape, and samples telemetry during the measured process. Schema-v3 distinguishes process-window power from benchmark phase rates. It has no network/download/elevation path and exports neither local paths, raw commands, child streams, nor llama-bench machine fields.
- The ComfyUI adapter sends an explicit API-format workflow to loopback by default, requires an empty queue, changes only the nominated seed between warm-up and measurement, and reports schema-v3 work units with rate and power bound to the same client window. It never fetches outputs or exports workflow/history content; a remote endpoint requires explicit opt-in.
- The idle-power recorder is a separate query-only path. It captures explicit vendor-auto baseline or persistent-lock candidate conditions, and the pure gate requires paired repetitions, exact hardware/driver consistency, complete board-power/utilization evidence, a genuinely idle window, and both aggregate and per-GPU thresholds. Its strongest output is `CanProceedPastIdleGate`; it cannot authorize a final recommendation or apply a setting.
- The workload candidate gate accepts only an explicitly named reference/candidate pair. It requires live schema-v3 phase alignment, repeated complete samples, exact hardware/driver identity, performance retention, measurable efficiency gain, bounded temperature, and stable loaded clocks below the declared ceiling. Failed, incomplete, reset, mixed, missing, or under-sampled evidence fails closed. Its strongest output is `CanProceedPastWorkloadGate`.
- The adaptive cooling assembly is deterministic and hardware-independent. It has no hardware adapter, process launch, persistence, network access, or write path; `CanApply` is always `false`.

See [PRIVACY.md](../PRIVACY.md), [SECURITY.md](../SECURITY.md), and the [adaptive cooling design](../fan-control/ADAPTIVE_FAN_SYSTEM.md) for the detailed policies.

## Trust boundaries

| Boundary | Allowed today | Deliberately excluded |
| --- | --- | --- |
| HUD process | Read telemetry; draw UI; save user settings; register a hotkey; copy an explicitly requested sanitized diagnostic to the local clipboard | Administrator elevation; GPU writes; camera access; network telemetry; automatic report upload |
| Windows GPU research probe | On one explicit CLI invocation, read DXGI/WMI adapter and counter data and write sanitized JSON to the supplied local path | HUD integration; background polling; raw LUID/PID/PNP output; network; elevation; hardware writes |
| Settings event | Ask the existing user-session process to open its settings window | Arbitrary commands or payloads |
| GPU plan | Query explicitly selected cards; show current/default/range/max-clock evidence; inspect migration state; return a privacy-safe decision | Elevation; GPU writes; UUID output; inferred targets; workload-independent clock suggestions |
| GPU installer | Validate explicit values; pin the helper hash across UAC; install fixed Apply/Reset task actions | Silent elevation; inferred GPU targets; universal power presets |
| GPU tasks/helper | Independently enforce board limits, max clock, and explicit power-increase acknowledgement; run strict compiled Apply/Reset commands as SYSTEM; keep atomic state/rollback records | User-controlled privileged arguments; shell execution; guessed reset targets; hidden profile changes |
| Ollama benchmark | Call a local model; read official timing counters; query NVIDIA telemetry; write an anonymized run | Model pulls; implicit remote prompts; GPU writes; prompt/response export |
| llama.cpp benchmark | Launch explicit local `llama-bench`/GGUF inputs; validate official JSON; query NVIDIA telemetry; write an anonymized run | Downloads; network clients; elevation; GPU writes; path/command/console export |
| ComfyUI benchmark | Submit an explicit workflow to an empty opted-in endpoint; query completion and NVIDIA telemetry; write generalized anonymized throughput | Implicit remote workflows; output downloads; global interrupt/free/history mutation; GPU writes; workflow/history export |
| Idle-power gate | Query NVIDIA board power, utilization, temperature, and current graphics clock; write anonymized paired evidence; evaluate declared thresholds | Profile apply/reset; elevation; final recommendation; UUID/path/command export |
| Workload candidate gate | Read anonymized schema-v3 exports; compare one explicit reference/candidate pair; reject failures and threshold violations | Hardware reads/writes; implicit profile selection; elevation; final recommendation |
| Presence experiment | Local camera inference after opt-in | Default installation; cloud face processing; raw-frame retention in SFace mode |
| Cooling simulation | Return bounded advice and emergency status | Device writes or authorization to apply advice |

## Failure behavior

- No selected monitor: keep the tray process alive and do not move the HUD elsewhere.
- Shortcut collision: keep the previous setting and show a recoverable conflict message.
- Missing or malformed NVIDIA telemetry: render unknown/red rather than claim success.
- Newer settings schema: fall back in memory and block writes.
- GPU preflight failure: change no card.
- Partial GPU apply failure: attempt rollback, record every result, and leave the HUD red.
- Missing camera or uncertain face evidence: report uncertainty/error; do not treat it as owner verification.
- Missing cooling evidence or out-of-domain conditions: suppress numeric advice; emergencies still surface immediately.

## Build and verification map

| Surface | Verification |
| --- | --- |
| Unlock guard | `tests/Guard.Smoke.Tests.ps1` exercises success, timeout-with-lock-suppressed, and fail-open collision behavior. |
| HUD core | `tests/SystemOverlay.Smoke.Tests.ps1` compiles the shared source, round-trips settings, verifies diagnostic UUID/path redaction, validates live multi-GPU telemetry, and exercises 13 deterministic NVIDIA identity/state/success/failure cases. |
| Compiled app | `tests/DesktopApp.Smoke.Tests.ps1` builds and launches the .NET entry point in a no-hardware-write smoke mode. |
| Release package | `tests/DesktopPackageVerifier.Tests.ps1` runs nine deterministic cases for digest/filename/record matching, traversal and duplicate rejection, required files, declared version, and bounded expansion without extraction or execution. |
| Clean-machine harness | `tests/CleanMachineSandbox.Tests.ps1` validates the offline `.wsb` policy, read-only input/narrow result mappings, fixed runner, and explicit-only launch behavior. A real Sandbox result remains a separate release gate. |
| Windows GPU research | `tests/WindowsGpuCapability.Tests.ps1` runs seven query-boundary fixtures in both PowerShell runtimes. `CAAutoConfig.Telemetry.Tests` runs fourteen compiled same-name/reorder/incomplete-identity/provider/reporting cases without hardware access. A separate explicit CLI probes DXGI plus formatted WDDM classes; neither path can enable HUD data. |
| GPU plan | `tests/GpuLimitPlan.Tests.ps1` runs seven deterministic fixture cases for inventory-only behavior, a shared no-raise power starting point, board range and clock ceilings, explicit power-increase acknowledgement, complete profiles, and absence of mutation/elevation. |
| Privileged helper | `tests/GpuLimits.Safety.Tests.ps1` runs ten compiled fake-runner cases plus policy checks for strict commands, preflight-before-write, vendor max-clock enforcement, explicit power-increase acknowledgement, exact rollback, recovery, corrupt-record rejection, hash-pinned elevation, fixed tasks, confirmation, ACL intent, and safe defaults without changing hardware. |
| Power-curve lab | `benchmark/Run-Tests.ps1` runs 28 schema/report/card tests, 12 idle-gate tests, 14 workload-advisor tests, nine Ollama tests, nine llama-bench tests, and eight ComfyUI tests in both PowerShell runtimes, including phase-aware energy labeling, paired idle regression, workload failure/reset/clock rejection, legacy downgrade safety, workload isolation, evidence-gated SVG output, cache rejection, remote-endpoint rejection, concurrent fixture telemetry, and privacy omission. |
| Cooling model | `fan-control/Run-Tests.ps1` runs the isolated safety, calibration, prediction, drift, and emergency scenarios. |
| Demo | `tools/Capture-HudDemo.ps1` uses `PrintWindow` on CA AutoConfig windows only, verifies state transitions, and restores the HUD to locked mode. |

The prepared Windows workflow is in [`docs/ci.yml.example`](ci.yml.example). It cannot become an active `.github/workflows` file until the maintainer's GitHub token is authorized for workflow changes.

The research basis and current phase-alignment boundary are recorded in [`research/PHASE_ALIGNED_ENERGY.md`](research/PHASE_ALIGNED_ENERGY.md).

## Near-term hardening

The current public preview intentionally exposes the remaining work:

1. Add bounded asynchronous polling, freshness, overlap suppression, driver-reset recovery, and cross-hardware validation to the research-only WDDM provider before enabling any of its fields in the HUD.
2. Sign binaries and exercise install, upgrade, uninstall, sleep, driver-reset, and clean-machine recovery in CI.
3. Keep measured workload benchmarks separate from generic or vendor-independent claims.

Changes that weaken the privilege split, make GPU writes implicit, convert unknown evidence into success, or connect cooling advice directly to an actuator are architecture changes and require a security-focused review.
