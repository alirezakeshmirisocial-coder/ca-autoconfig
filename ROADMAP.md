# CA AutoConfig roadmap

The product direction is a tiny, trustworthy Windows HUD and safe power optimizer for local-AI workstations. The public success target is broad adoption, including a long-term goal of 5,000 genuine GitHub stars; engineering quality, useful benchmarks, installs, contributors, and retained users remain the leading indicators.

## Milestone 1 — Interactive HUD alpha

- [x] Tiny lock/unlock control with click-through outside the control.
- [x] Dragging with persistent per-display position.
- [x] Visual monitor-topology selector.
- [x] User-defined global lock shortcut with conflict detection.
- [x] GPU power draw, cap, vendor range, temperature, clock, load, and VRAM telemetry.
- [x] Conservative read-only starting point that never raises an existing lower cap.
- [x] Read-only pre-UAC install plan with per-board power/clock validation and migration blockers.
- [x] Scheduled-task installation and control-panel entry.
- [x] Compile and policy smoke tests.

## Milestone 2 — Public technical preview

- [x] Move the HUD into a compiled .NET 8 application with a versioned, forward-write-protected settings schema.
- [x] Resolve selected GPU indices once at installation, pin the task/state to NVIDIA UUIDs, and verify live identity with legacy-state fallback.
- [x] Isolate the minimal elevated apply/reset helper behind fixed ACL-protected Task Scheduler commands and a compiled strict-command executable.
- [x] Add a deterministic simulated NVIDIA source and fail-closed tests for missing, timed-out, empty, partial, malformed, and explicit-`N/A` telemetry.
- [x] Build a research-only WDDM path with a capability probe, deterministic LUID mapping, explicit WMI/formatted-PDH/raw-pairing-PDH sources, sanitized reports, bounded polling, and fail-closed status retention; follow the [Windows telemetry provider boundary](docs/research/WINDOWS_GPU_TELEMETRY.md).
- [ ] Promote any WDDM field into the HUD only after a clean sustained run, sleep/reset recovery, and external Windows 10/11 AMD/Intel/NVIDIA evidence satisfy that boundary.
- [x] Package a reproducible self-contained `win-x64` ZIP with a least-privilege installer and checksum.
- [x] Add an offline, no-extraction package verifier for checksum, ZIP-path, size, required-file, and version integrity.
- [x] Prepare an offline Windows Sandbox install/task/uninstall harness with read-only package input and privacy-safe evidence output.
- [ ] Add CI-built artifacts, signing, clean-machine install/uninstall coverage, and an MSIX or equivalent upgrade path.
- [x] Separate the optional camera/presence experiment and GPU mutation from the default HUD installation.
- [x] Add an English screenshot and public privacy statement.
- [x] Add a short privacy-safe, app-window-only demo.
- [x] Add architecture documentation with explicit runtime, privilege, privacy, and failure boundaries.

## Milestone 3 — Workload-aware Power Advisor

- [x] Define an anonymized schema-v1 run export, query-only telemetry recorder, deterministic fixture suite, and human-readable comparison report.
- [ ] Record baseline power, temperature, errors, and throughput for a real workload.
- [x] Add a local-first Ollama adapter that measures the request and NVIDIA telemetry concurrently without storing prompt/response text or changing GPU settings.
- [x] Add a local llama.cpp/`llama-bench` adapter with exact JSON-row validation, concurrent NVIDIA sampling, and path/command omission.
- [x] Add a loopback-first ComfyUI adapter with explicit work units, cache-separated seeds, empty-queue preflight, and workflow/output omission.
- [ ] Offer Balanced, Eco, Quiet, and Default profiles only when evidence is sufficient.
- [x] Add a read-only, paired idle-power regression gate before recommending a persistent graphics-clock lock; fixture evidence can exercise thresholds but can never authorize progression.
- [x] Reject a workload candidate after driver-reset evidence, workload error, incomplete data, unstable loaded clocks, or a clock-ceiling violation.
- [x] Require explicit manual confirmation, administrator-approved installation, and a hardware-isolated, exact-value one-click rollback path.
- [x] Turn the anonymized JSON benchmark into a deterministic, evidence-gated AI Power Curve SVG card.
- [x] Add schema-v3 phase provenance so only same-window throughput and board power can produce per-joule claims.

## Milestone 3.5 — Adaptive cooling, simulation first

- [x] Specify a deterministic ambient-aware fan/power policy with explicit safety precedence.
- [x] Cover 40°C ambient, poor ventilation, multi-GPU heat soak, sensor loss, fan stalls, maintenance drift, hysteresis, dwell, and slew limits with synthetic tests.
- [x] Keep the prototype isolated and advice-only: no device writes, no hidden actuator, and `CanApply` always false.
- [x] Gate predictive simulation behind identifiable input variation, chronological held-out validation, bounded interpolation, and drift invalidation.
- [ ] Add a read-only telemetry adapter with per-reading timestamp, units, provenance, and capability discovery.
- [ ] Build verified per-board profiles keyed by GPU UUID, board/VBIOS/driver, fan topology, and cooling configuration.
- [ ] Validate physical tachometry; intended fan speed alone must never clear a fan-fault latch.
- [ ] Replay long-duration real traces across hot rooms, restricted airflow, dual-GPU loads, and cleaned/degraded baselines.
- [ ] Before any opt-in live mode, implement an independent watchdog and verify vendor-auto restoration after crash, sleep, driver reset, sensor loss, and controller conflict.

## Milestone 4 — Community launch

- [x] Complete repository community-health files, issue forms, Discussions, and a public evidence-tiered hardware matrix.
- [ ] Recruit 20–30 design partners across local-LLM and diffusion workflows.
- [ ] Publish reproducible power-versus-throughput studies rather than promotional claims.
- [ ] Prepare tailored, rules-compliant launches for relevant Reddit communities, Show HN, and local-AI creators.
- [ ] Track releases, installs, benchmark submissions, contributors, response time, and star-source attribution.
- [ ] Do not buy stars, automate endorsements, brigade communities, or hide sponsorships.

## Release gates

A public `v1.0` requires a compiled application, rollback-tested privileged helper, clean-machine installation test, explicit privacy boundary, failure-mode tests, supported-hardware table, checksum-verifiable artifacts, and no unresolved critical security findings.
