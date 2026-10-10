# Changelog

This project follows semantic versioning after `v1.0.0`. Pre-1.0 releases may change installation and configuration details while preserving documented safety boundaries.

## Unreleased

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
