# CA AutoConfig roadmap

The product direction is a tiny, trustworthy Windows HUD and safe power optimizer for local-AI workstations. The public success target is broad adoption, including a long-term goal of 5,000 genuine GitHub stars; engineering quality, useful benchmarks, installs, contributors, and retained users remain the leading indicators.

## Milestone 1 — Interactive HUD alpha

- [x] Tiny lock/unlock control with click-through outside the control.
- [x] Dragging with persistent per-display position.
- [x] Visual monitor-topology selector.
- [x] User-defined global lock shortcut with conflict detection.
- [x] GPU power draw, cap, vendor range, temperature, clock, load, and VRAM telemetry.
- [x] Conservative read-only starting point that never raises an existing lower cap.
- [x] Scheduled-task installation and control-panel entry.
- [x] Compile and policy smoke tests.

## Milestone 2 — Public technical preview

- [x] Move the HUD into a compiled .NET 8 application with a versioned, forward-write-protected settings schema.
- [ ] Address GPUs by UUID rather than mutable numeric index.
- [ ] Isolate the minimal elevated apply/reset helper behind an authenticated local boundary.
- [ ] Add simulated NVIDIA/WDDM providers and unit tests for missing or malformed telemetry.
- [x] Package a reproducible self-contained `win-x64` ZIP with a least-privilege installer and checksum.
- [ ] Add CI-built artifacts, signing, clean-machine install/uninstall coverage, and an MSIX or equivalent upgrade path.
- [x] Separate the optional camera/presence experiment and GPU mutation from the default HUD installation.
- [x] Add an English screenshot and public privacy statement.
- [x] Add a short privacy-safe, app-window-only demo.
- [ ] Add architecture documentation.

## Milestone 3 — Workload-aware Power Advisor

- [ ] Record baseline power, temperature, errors, and throughput for a real workload.
- [ ] Add adapters for Ollama/llama.cpp and ComfyUI before attempting generic detection.
- [ ] Offer Balanced, Eco, Quiet, and Default profiles only when evidence is sufficient.
- [ ] Reject a candidate after driver reset, workload error, unstable clock behavior, or incomplete data.
- [ ] Require explicit confirmation, administrator elevation, and a tested one-click rollback.
- [ ] Export an anonymized JSON benchmark and shareable AI Power Curve card.

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

- [ ] Complete repository community-health files, issue forms, Discussions, and a public hardware matrix.
- [ ] Recruit 20–30 design partners across local-LLM and diffusion workflows.
- [ ] Publish reproducible power-versus-throughput studies rather than promotional claims.
- [ ] Prepare tailored, rules-compliant launches for relevant Reddit communities, Show HN, and local-AI creators.
- [ ] Track releases, installs, benchmark submissions, contributors, response time, and star-source attribution.
- [ ] Do not buy stars, automate endorsements, brigade communities, or hide sponsorships.

## Release gates

A public `v1.0` requires a compiled application, rollback-tested privileged helper, clean-machine installation test, explicit privacy boundary, failure-mode tests, supported-hardware table, checksum-verifiable artifacts, and no unresolved critical security findings.
