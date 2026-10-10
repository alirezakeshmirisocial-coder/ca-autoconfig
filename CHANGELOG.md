# Changelog

This project follows semantic versioning after `v1.0.0`. Pre-1.0 releases may change installation and configuration details while preserving documented safety boundaries.

## Unreleased

- Added a deterministic Windows Sandbox clean-machine harness that verifies a release, maps package inputs read-only, disables network/vGPU/clipboard/device redirection, checks least-privilege Logon/SessionUnlock installation, uninstalls, and emits a privacy-safe result JSON to one narrow writable folder.
- Added five preparation-policy tests in both PowerShell runtimes. A real Sandbox result is still required before claiming clean-machine coverage.
- Added a dedicated clean-machine result issue form that requires exact release/build context, retained failures, the sanitized result JSON, and explicit privacy/evidence-boundary confirmations.
- Defined the Windows/WDDM GPU telemetry provider contract, including per-adapter identity, field-level capability, standard-user failure behavior, known counter-scope limitations, and the evidence required before AMD/Intel telemetry can reach the HUD.
- Added a query-only Windows GPU capability probe with seven deterministic tests. It reports sanitized controller names and counter availability, rejects raw identifiers, and keeps `CanUseInHud=false` until per-adapter mapping is validated.
- Added a pure Windows GPU counter-mapping core with nine hardware-independent cases for same-name adapters, enumeration reorder, incomplete/foreign identities, busiest-engine aggregation, and raw-LUID omission. It remains disconnected from the HUD pending a live DXGI provider and cross-hardware evidence.

## v0.2.6-alpha.3 — Offline package verification

- Added an offline desktop-package verifier that checks the published SHA-256 filename and digest, rejects unsafe or duplicate ZIP paths and oversized expansion, requires the install-critical files, and validates the declared package version without extracting or executing the bundle.
- Added nine deterministic verifier tests and included the verifier in future desktop preview packages.

## v0.2.6-alpha.2 — Read-only preflight plan

- Added a privacy-safe, query-only GPU limit plan that shows selected cards, current/default/vendor power ranges, live/vendor-maximum clocks, a shared no-raise power starting point, and migration readiness before UAC.
- A proposed profile now fails before elevation if it exceeds any selected board's range/default/maximum clock, is incomplete, would silently raise a current cap, or would overwrite an installed/legacy profile without a safe reset.
- Extended the compiled helper's independent preflight to enforce the vendor-reported maximum graphics clock and require a fixed-task `--allow-power-increase` flag before raising any current cap.
- Added seven deterministic planner tests and expanded compiled-helper coverage to ten hardware-isolated cases in PowerShell 7 and Windows PowerShell 5.1.

## v0.2.6-alpha.1 — Transactional compiled GPU helper

- Replaced the PowerShell-based SYSTEM action with a small compiled helper that accepts only strict `apply` or `reset` commands, launches the fixed System32 `nvidia-smi.exe` without a shell, and refuses standard-user direct execution.
- Added a protected, atomic rollback record containing the exact pre-apply power limits. Apply and reset both preflight every UUID-pinned target, verify results, and attempt reverse recovery after partial failure.
- Split privileged mutation into fixed ACL-protected Apply and Reset tasks. The control panel can run those reviewed commands but cannot supply privileged arguments or call `-pl`, `-lgc`, or `-rgc` itself.
- Added explicit confirmation for manual GPU changes, hash pinning across UAC, legacy-migration refusal when original values are unknown, and eight hardware-isolated compiled-helper safety tests.

## v0.2.5-alpha.2 — Fail-closed workload candidates

- Added an explicit-reference workload candidate gate that requires live phase-aligned schema-v3 evidence, repeated complete sampling, lower power, configurable throughput retention and efficiency gain, bounded temperature, and stable loaded clocks below a declared ceiling.
- Failed/incomplete runs now reject the selected candidate; driver/GPU reset, device-loss, and NVIDIA Xid errors receive an explicit rejection reason. Fixture data can exercise thresholds but can never pass.
- Added 14 deterministic workload-advisor tests and a read-only Markdown report; the strongest output is `CanProceedPastWorkloadGate`, never an apply recommendation.

## v0.2.5-alpha.1 — Idle-safe clock candidates

- Added a separate, query-only idle-power recorder, anonymized idle-schema-v1 contract, deterministic paired baseline/candidate fixtures, and a fail-closed regression report for persistent graphics-clock candidates.
- The idle gate requires repeated live evidence, exact hardware/driver consistency, complete low-utilization telemetry, and aggregate plus per-GPU thresholds. Its strongest output is `CanProceedPastIdleGate`; fixture data and a gate pass can never become a final recommendation.
- Expanded shared privacy-field rejection to common camelCase identifier variants such as `machineName`, `computerName`, and `gpuUuid`.

## v0.2.4-alpha.2 — Phase-honest energy evidence

- Added schema-v3 measurement provenance for power, prompt, generation, and work-rate windows; current adapters now emit explicit phase semantics.
- Exact tokens/J or work/J is emitted only for same-window evidence. Ollama and llama.cpp phase rates remain rate/power indices against their request/process power windows, while ComfyUI client-window work/J stays aligned.
- Added deterministic legacy, phase-mismatch, card-label, and adapter-export tests so older or unaligned data cannot gain an energy claim during analysis.
- Added a public research note connecting the boundary to official runtime semantics, current energy-benchmark research, and local-AI community demand signals.

## v0.2.4-alpha.1 — Evidence-gated Power Curve cards

- Added a deterministic Power Curve SVG generator with strict workload/source matching, schema-v1/v2 units, repetition gates, retained failure counts, and permanent fixture/draft evidence labels.
- Added a permanent provenance footer and accessible SVG metadata with run, failure, axis, profile, and evidence-boundary details.
- Added a fixture preview that cannot be mistaken for measured hardware evidence; real cards require exact anonymized raw JSON and the method beside them.
- Fixed packaged installation under Windows PowerShell 5.1 by resolving the bundled executable after script initialization, and preserved/validated the selected display across upgrades.

## v0.2.3-alpha.2 — Privacy-safe diagnostics and test intake

- Added one-click privacy-safe diagnostics in Settings with inline copied feedback, display/DPI topology, profile state, telemetry and advisor values, and defensive UUID/path redaction.
- Added an evidence-tiered public hardware/workflow matrix that distinguishes live maintainer checks, deterministic fixtures, unsupported surfaces, and zero external reproductions.
- Fixed issue-form labels to match repository labels, added privacy-aware contact routing, and required hardware submissions to retain failed/incomplete runs.
- Opened a focused design-partner intake with three bounded test cohorts and no star requirement.
- Regenerated the application-only demo and corrected the maintainer display evidence with DPI-aware values.

## v0.2.3-alpha.1 — ComfyUI image-efficiency adapter

- Added schema-v2 generalized work throughput and unit-aware efficiency reporting, while retaining schema-v1 token-run compatibility.
- Added a loopback-first ComfyUI adapter with empty-queue preflight, cache-separated deterministic seeds, client-window image/work-unit throughput, concurrent NVIDIA sampling, and no output download.
- Added eight deterministic ComfyUI tests covering API-workflow validation, immutable seed injection, queue/history parsing, seed-node cache rejection, remote-endpoint refusal, concurrent telemetry, failed-run preservation, and workflow/output omission in both PowerShell runtimes.
- Fixed Markdown observation sentences so the selected profile and efficiency render as values instead of an escaped PowerShell expression, with direct regression coverage.

## v0.2.2-alpha.2 — Offline llama.cpp power-run adapter

- Added a local, offline llama.cpp adapter that runs an explicit `llama-bench`/GGUF pair, validates exact official JSON `pp` and `tg` evidence, and samples selected NVIDIA GPUs concurrently.
- Added nine deterministic llama-bench tests covering strict parsing, repetition completeness, no-download/no-network/no-mutation boundaries, concurrent process telemetry, private-field omission, and failed-process preservation in both PowerShell runtimes.
- Kept GGUF paths, raw commands, child stdout/stderr, and llama-bench CPU/GPU identity fields out of schema-v1 exports; the measured power interval is explicitly labeled as a process window.
- Added workload `name` to the report comparison key so different prompt, token, batch, context, or adapter protocols cannot be ranked together merely because model/backend labels match.

## v0.2.2-alpha.1 — Local Ollama power-run adapter

- Added a local-first Ollama power-run adapter that samples NVIDIA telemetry during a deterministic generation request and derives uncached prompt/generation throughput from official API counters.
- Kept workload collection read-only: no model pull, GPU mutation, elevation, prompt export, response export, or implicit remote endpoint.
- Added nine deterministic Ollama adapter tests, including remote-endpoint rejection, a concurrent local fixture run, and a failed-request export, in Windows PowerShell and PowerShell 7.

## v0.2.1-alpha.3 — Stable GPU identity and control-path repair

- Resolved user-selected GPU indices to stable NVIDIA UUIDs before elevation and pinned the protected scheduled task to those identities.
- Added UUIDs to applied state and made the HUD verify live cards by UUID, while retaining a tested fallback for state produced by older releases.
- Made Reset read the applied profile, preflight every recorded target, and prefer UUIDs instead of assuming hard-coded GPU indices `0,1`.
- Made control-panel status compare live values with each applied profile instead of a maintainer-specific `280 W` constant.
- Added deterministic index-reordering, wrong-card-at-old-index, legacy-state, malformed-identity, and duplicate-identity cases; the NVIDIA simulation suite now covers 13 cases.
- Fixed the control panel's GPU Apply action to run the already-reviewed protected task and wait for a fresh state result, without rebuilding or omitting privileged-helper arguments.
- Made Start all and auto-start controls tolerate the intentionally absent camera task in the default HUD-only installation.

## v0.2.1-alpha.2 — Telemetry resilience and version metadata

- Added an injectable NVIDIA telemetry boundary and eight deterministic fail-closed cases covering missing, timed-out, failed, empty, partial, malformed, and explicit-`N/A` data.
- Rendered unavailable GPU percentages, watts, and temperature as unknown values instead of plausible zero readings.
- Corrected the compiled executable's product, assembly, and file-version metadata for the `v0.2.1` line.
- Added a zero-baseline growth scorecard that separates product health, design-partner evidence, distribution, and genuine stars without application tracking.

## v0.2.1-alpha.1 — Read-only power-curve lab

- Added a read-only power-curve lab with a versioned anonymized JSON schema, live NVIDIA telemetry recorder, synthetic dry run, deterministic calculations, privacy rejection, and Markdown comparison report.
- Added 14 benchmark tests in Windows PowerShell and PowerShell 7; the fixture suite performs no hardware reads or writes, and the live recorder contains query-only NVIDIA operations.
- Added a privacy-safe animated demo generator that captures only CA AutoConfig windows and restores the live HUD to locked mode.
- Documented the runtime map, privilege split, trust boundaries, failure behavior, and verification surface for the compiled preview.
- Updated the community launch sequence from current Reddit and Hacker News rules: benchmark-first, human-authored posts, participation before promotion, and no vote solicitation or automated submission.
- Expanded the prepared Windows CI example to cover the compiled desktop smoke test and privileged-helper safety boundary.
- Granted only the configured user read/run access to the protected SYSTEM GPU task, so the control panel can inspect and trigger it without permission to rewrite its action.
- Replaced the public observation-only thermal recommendation with a calibration-first predictive simulation that refuses flat/confounded data and out-of-domain extrapolation.
- Added chronological held-out prediction checks, empirical per-junction margins, bounded fan interpolation, finite-grid fan/power optimization, and sustained-drift invalidation.
- Expanded the isolated policy suite from 35 to 52 scenarios across both Windows PowerShell and PowerShell 7; the module still exposes no hardware-write path.

## v0.2.0-alpha.1 — Compiled desktop preview

- Added a self-contained .NET 8 Windows application that reuses the tested WinForms HUD implementation.
- Added schema-v1 settings migration shared by the compiled and PowerShell hosts; newer settings schemas cannot be overwritten.
- Added a least-privilege compiled-app installation path for Logon and SessionUnlock.
- Added reproducible `win-x64` packaging, ZIP checksums, and headless framework-dependent/self-contained smoke tests.
- Replaced the .NET Framework-only JSON dependency while retaining Windows PowerShell compatibility.
- Verified a live compiled-HUD swap and restored/updated the existing scheduled task without touching GPU or camera tasks.

## v0.1.2-alpha — Public installer safety

- Made camera monitoring and GPU mutation opt-in in the combined installer; its default path now installs only the HUD and control shortcut.
- Required explicit GPU targets, clock, power, and hardware-risk acknowledgement; added all-target preflight and best-effort rollback reporting.
- Protected the SYSTEM task source with an administrator-owned ACL and rejected reparse-point install paths.
- Added a no-hardware-write safety smoke test for the privileged GPU install/apply boundary.
- Documented the adaptive cooling architecture, sensor provenance, thermal model, state machine, maintenance baseline, failure responses, and live-mode safety gates.
- Expanded the isolated policy suite to 35 scenarios, including latched zero-RPM fan-fault recovery and the exact recommendation-confidence boundary.
- Kept cooling output simulation-only: the policy performs no device writes and `CanApply` remains `false`.

## v0.1.1-alpha — High-DPI correction

- Switched the HUD UI thread to per-monitor-v2 DPI awareness before WinForms creates windows.
- Corrected clipping on mixed-DPI monitor layouts while preserving the selected monitor and lower-left placement.
- Added a privacy-safe capture of the actual running HUD to the README.

## v0.1.0-alpha — Interactive HUD foundation

- Added a tiny lock/unlock control that leaves the locked HUD click-through.
- Added draggable placement, a visual Windows monitor map, and persisted per-display position.
- Added a configurable global shortcut with conflict detection; the default is `Ctrl+Alt+L`.
- Added tray and control-panel access to HUD settings.
- Added NVIDIA power draw, cap, vendor range, temperature, clock, CUDA/SM load, and VRAM telemetry.
- Replaced hardcoded HUD health assumptions with current-boot profile verification.
- Added a conservative read-only power starting point that never raises an existing lower cap.
- Added an adaptive fan-policy prototype and isolated policy tests.
- Added smoke tests, security and privacy guidance, contribution documentation, issue forms, and an open-source roadmap.

Known limitations:

- The compiled HUD ships as an unsigned self-contained ZIP preview rather than a signed installer; the PowerShell-hosted path remains as a compatibility fallback.
- Windows and NVIDIA are the only supported public-alpha platform and GPU provider.
- Power suggestions are benchmark starting points, not measured workload recommendations.
- The optional camera/presence experiment remains in the same repository and is not installed by the standalone HUD installer.
- GitHub Actions is prepared in `docs/ci.yml.example` but is not active until the maintainer authorizes the GitHub CLI `workflow` scope.
