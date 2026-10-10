# Contributing to CA AutoConfig

CA AutoConfig is being built for people running local LLMs, diffusion models, and other sustained GPU workloads on Windows. Useful contributions are reproducible, hardware-aware, and conservative about changing system state.

## Before opening a pull request

1. Open an issue or Discussion for behavior changes, new hardware providers, or changes that require elevation.
2. Keep read-only telemetry separate from privileged actions.
3. Never silently raise a vendor default, change voltage, or apply a suggested limit without explicit user confirmation.
4. Do not add telemetry, cloud calls, camera capture, or update checks without an opt-in design and privacy review.
5. Test on simulated data when possible and identify the real hardware used for hardware validation.

## Local checks

```powershell
.\tests\SystemOverlay.Smoke.Tests.ps1
.\tests\Guard.Smoke.Tests.ps1
.\tests\DesktopApp.Smoke.Tests.ps1
.\tests\GpuLimits.Safety.Tests.ps1
.\benchmark\Run-Tests.ps1
.\fan-control\Run-Tests.ps1
```

Pull requests should explain the user problem, safety boundary, test evidence, and any administrator permissions required. Screenshots are expected for HUD or settings changes.

## Hardware reports

Include GPU model, driver version, Windows version, supported minimum/default/maximum power limits, workload, observed watts, temperature, throughput, and whether the test produced a driver reset or workload error. Remove usernames, machine names, UUIDs, and personal paths before posting. Prefer the versioned, privacy-checked export and protocol in [benchmark/POWER_CURVE_METHOD.md](benchmark/POWER_CURVE_METHOD.md).

Generated Power Curve cards must link the exact raw anonymized JSON and method used to create them. Do not crop or cover the fixture, draft, repetition, failure, or non-universal-limit labels.

Accepted evidence is summarized in the public [hardware matrix](docs/HARDWARE_MATRIX.md). The desktop Settings window can copy a sanitized starting block; inspect it before posting, then add workload method and failures manually. A report must include failures and incomplete runs, not only the best repetition. You never need to star the repository to participate.

## Community conduct

Be direct, patient, and evidence-led. Hardware results vary; disagreement about a benchmark is not a disagreement about the person reporting it. Security concerns should follow [SECURITY.md](SECURITY.md), not public issues.
