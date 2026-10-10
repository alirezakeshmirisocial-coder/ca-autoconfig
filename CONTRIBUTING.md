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
.\tests\DesktopPackageVerifier.Tests.ps1
.\tests\CleanMachineSandbox.Tests.ps1
.\tests\WindowsGpuCapability.Tests.ps1
.\tests\WindowsGpuChurnHarness.Tests.ps1
.\tests\WindowsGpuLoadedValidation.Tests.ps1
dotnet run --project .\src\CAAutoConfig.Telemetry.Tests\CAAutoConfig.Telemetry.Tests.csproj -c Release
.\tests\GpuLimits.Safety.Tests.ps1
.\tests\GpuLimitPlan.Tests.ps1
.\benchmark\Run-Tests.ps1
.\fan-control\Run-Tests.ps1
```

Pull requests should explain the user problem, safety boundary, test evidence, and any administrator permissions required. Screenshots are expected for HUD or settings changes.

Clean-machine testers should use the [Windows Sandbox protocol](docs/CLEAN_MACHINE_SANDBOX.md) and the dedicated [result form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=clean-machine-result.yml). Keep failed results and inspect the generated JSON before posting.

## Hardware reports

Include GPU model, driver version, Windows version, supported minimum/default/maximum power limits, workload, observed watts, temperature, throughput, and whether the test produced a driver reset or workload error. Remove usernames, machine names, UUIDs, and personal paths before posting. Prefer the versioned, privacy-checked export and protocol in [benchmark/POWER_CURVE_METHOD.md](benchmark/POWER_CURVE_METHOD.md).

Windows WMI/formatted-PDH/raw-PDH provider reports should use the dedicated [Windows GPU telemetry form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=windows-gpu-result.yml). Include the exact provider and display language because performance-counter behavior and localization are part of the compatibility boundary, retain every full/partial/per-field/unavailable/failure count, and never paste raw counter-instance names, LUIDs, PIDs, PNP/PCI identifiers, or UUIDs. `READY_FOR_VALIDATION` and `PARTIAL_READY_FOR_VALIDATION` are research evidence only; neither authorizes HUD integration.

For a loaded local-AI result, collect the raw-PDH report concurrently with a current schema-v3 workload recorder, then use [`New-WindowsGpuLoadedValidationSummary.ps1`](tools/New-WindowsGpuLoadedValidationSummary.ps1). A `READY_FOR_MANUAL_VALUE_COMPARISON` result proves only that the explicit windows overlap, every workload GPU sustained the declared load for the required share of complete utilization samples, and the Windows provider retained complete samples. It does not compare the Windows values with an independent vendor source and cannot authorize HUD integration. Publish both anonymized inputs, the linked summary, declared thresholds, and every retained failure.

Generated Power Curve cards must link the exact raw anonymized JSON and method used to create them. Do not crop or cover the fixture, draft, phase-alignment, repetition, failure, or non-universal-limit labels. Never rename a rate/power index as Joules per token or work unit when the declared windows differ.

Persistent clock-lock candidates also need paired idle evidence from [`Record-IdlePowerRun.ps1`](benchmark/Record-IdlePowerRun.ps1): at least three vendor-auto baseline runs and three candidate runs with the same cards and driver. Retain busy, missing, failed, and incomplete runs. A passing idle report means only that the candidate may proceed to workload, stability, temperature, rollback, and confirmation gates; do not present it as a final recommendation.

Use [`New-WorkloadCandidateReport.ps1`](benchmark/New-WorkloadCandidateReport.ps1) to evaluate one explicitly named candidate against one explicitly named reference. Do not remove a failed/incomplete/reset run, loosen a threshold after seeing the result without disclosing it, or substitute a phase-mismatched rate/power index for energy. Publish the exact anonymized inputs, command thresholds, and rejection reason codes with the report.

Accepted evidence is summarized in the public [hardware matrix](docs/HARDWARE_MATRIX.md). The desktop Settings window can copy a sanitized starting block; inspect it before posting, then add workload method and failures manually. A report must include failures and incomplete runs, not only the best repetition. You never need to star the repository to participate.

## Community conduct

Be direct, patient, and evidence-led. Hardware results vary; disagreement about a benchmark is not a disagreement about the person reporting it. Security concerns should follow [SECURITY.md](SECURITY.md), not public issues.
