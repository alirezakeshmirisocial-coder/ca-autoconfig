# Compiled desktop preview

The compiled preview packages the tested HUD as a self-contained .NET 8 Windows application. It does not require PowerShell source compilation or a separately installed .NET runtime on the target machine.

## Install

1. Download the `win-x64` preview ZIP, its `.sha256` file, and the standalone `Verify-DesktopPackage.ps1` from Releases.
2. Before extraction, run the offline verifier from the same directory:

```powershell
.\Verify-DesktopPackage.ps1 -PackagePath .\CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip -ExpectedVersion 0.2.6-alpha.4
```

It checks the checksum filename and digest, archive paths, case-insensitive duplicates, expansion size, required install files, and the declared version without extracting or executing package content.

3. Extract the ZIP and run:

```powershell
.\Install-DesktopApp.ps1
```

The installer copies `CAAutoConfig.exe` and the control panel to `%LOCALAPPDATA%\CASystemOverlay`, creates a desktop shortcut, and creates the least-privilege `CA System Overlay` task. It starts at Logon and SessionUnlock. The default install does not install camera monitoring, request administrator rights, or apply GPU settings.

The tray icon, tiny lock pill, monitor map, custom shortcut, opacity, and saved position behave the same as the PowerShell-hosted alpha. Both hosts share schema-versioned settings at `%LOCALAPPDATA%\CAAutoConfig\settings.json`. A host that encounters a newer settings schema falls back safely and refuses to overwrite that file.

Settings also has **Copy diagnostics** for low-friction hardware reports. The copied text includes the app/Windows version, architecture, shortcut, selected display, display topology and DPI scale, profile state, and current NVIDIA telemetry/advisor values. It deliberately excludes usernames, machine names, GPU UUIDs, local paths, prompts, outputs, workflows, and image content; inspect the text before posting it publicly.

The release ZIP also includes the optional [`benchmark`](../benchmark/POWER_CURVE_METHOD.md) lab. It records query-only NVIDIA telemetry beside throughput you measured from a workload, rejects common machine identifiers, and produces a scoped Markdown comparison plus a deterministic, evidence-gated SVG share card. Schema-v3 records the power and throughput windows so only aligned evidence becomes `/J`; Ollama/llama.cpp phase rates remain clearly labeled indices, while ComfyUI's same client window can produce aligned `image/J`. A workload gate rejects failed, reset, incomplete, unstable-clock, over-temperature, weak-efficiency, or excessive-throughput-loss candidates. A separate paired idle gate prevents fixture, busy, mixed-driver, or idle-regressing clock-lock evidence from advancing. The adapters omit prompts, responses, local model paths, raw commands, workflows, and output metadata. The lab is not part of the startup task and cannot change a GPU profile.

The ZIP contains a separate optional `CAGpuHelper.exe`. It is not installed by `Install-DesktopApp.ps1`. Before opting in, inspect a proposed profile without elevation or hardware writes:

```powershell
.\Get-GpuLimitPlan.ps1 -GpuIndexList '0,1' -PowerLimitWatts 280 -MaxGraphicsClockMHz 1700
```

The plan shows the selected cards, current/default/supported power limits, current/vendor-maximum graphics clocks, and migration readiness without emitting GPU UUIDs. It can calculate a shared no-raise power starting point, but deliberately leaves the clock suggestion empty because a safe ceiling needs workload evidence. Fixture plans and blocked migrations can never authorize installation.

For Windows GPU research beyond the current NVIDIA provider, the ZIP also includes a query-only capability probe:

```powershell
.\Get-WindowsGpuCapability.ps1 | Format-List
```

It reports sanitized video-controller names and whether Windows exposes GPU engine and memory counter families. It performs no hardware write, never emits raw adapter identifiers, and always keeps `CanUseInHud=false` until per-adapter mapping and cross-hardware validation are complete.

Current source builds also expose the next research stage through the compiled executable:

```powershell
.\CAAutoConfig.exe --windows-gpu-probe-result .\windows-gpu-probe.json --windows-gpu-provider pdh
```

This explicit one-shot probe joins DXGI adapters to Windows engine and dedicated-memory counters, filters only adapters carrying the official DXGI software flag, and writes a sanitized local schema-v3 JSON report. Select `pdh` for the native Performance Data Helper experiment or `wmi` for the original formatted-WMI experiment; reports name the chosen provider and never fall back between them. Load and dedicated-memory capability are reported independently, so an invalid engine sample cannot masquerade as a valid zero or erase healthy VRAM evidence. It does not alter the running HUD, poll in the background, request elevation, access the network, change hardware, or emit raw LUID/PID values. `canUseInHud` remains `false` even when mapping succeeds.

Unreleased source builds also provide an explicit bounded polling benchmark for measuring collection latency and normalized process CPU before any HUD integration:

```powershell
.\CAAutoConfig.exe --windows-gpu-poll-result .\windows-gpu-poll.json --windows-gpu-poll-seconds 600 --windows-gpu-poll-ms 2000 --windows-gpu-provider pdh
```

The benchmark report is local and sanitized. It counts full, partial, engine-valid, memory-valid, and unavailable collections independently; per-field readiness requires every completed collection plus a fresh/stable final state and zero suppressed overlaps, rather than trusting only the final sample. `canUseInHud` remains `false`. It is research evidence, not a background service or supported AMD/Intel HUD claim.

To opt in, review your exact board limits and run `Install-GpuLimits.ps1` with explicit GPU indices, MHz, watts, and `-AcceptHardwareRisk`. The installer reruns the plan before UAC, hash-pins the helper across elevation, and registers fixed Apply and Reset SYSTEM tasks. Raising an existing current power cap additionally requires `-AcknowledgePowerIncrease`, which is retained in the reviewed fixed task and independently enforced by the helper. Manual changes require confirmation in the control panel; the protected reset record restores the exact pre-apply power values rather than guessing a universal default.

## Remove

```powershell
.\Uninstall-SystemOverlay.ps1
```

This removes the scheduled task. Local preferences remain so an upgrade can preserve the selected display, position, opacity, and shortcut.

## Build and verify

From a source checkout, use the .NET 8 SDK:

```powershell
.\Build-DesktopApp.ps1 -SelfContained
.\Build-GpuHelper.ps1 -SelfContained
.\tests\DesktopApp.Smoke.Tests.ps1 -SelfContained
.\tests\DesktopPackageVerifier.Tests.ps1
.\tests\WindowsGpuCapability.Tests.ps1
.\tests\GpuLimits.Safety.Tests.ps1
.\tests\GpuLimitPlan.Tests.ps1
```

The smoke mode tests application startup and settings persistence without opening the HUD, changing GPU settings, or writing outside its temporary result directory.
