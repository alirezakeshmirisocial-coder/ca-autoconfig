# Changelog

This project follows semantic versioning after `v1.0.0`. Pre-1.0 releases may change installation and configuration details while preserving documented safety boundaries.

## Unreleased

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

- The HUD remains a PowerShell-hosted WinForms alpha rather than a packaged .NET application.
- Windows and NVIDIA are the only supported public-alpha platform and GPU provider.
- Power suggestions are benchmark starting points, not measured workload recommendations.
- The optional camera/presence experiment remains in the same repository and is not installed by the standalone HUD installer.
- GitHub Actions is prepared in `docs/ci.yml.example` but is not active until the maintainer authorizes the GitHub CLI `workflow` scope.
