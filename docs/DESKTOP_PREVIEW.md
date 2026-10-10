# Compiled desktop preview

The compiled preview packages the tested HUD as a self-contained .NET 8 Windows application. It does not require PowerShell source compilation or a separately installed .NET runtime on the target machine.

## Install

1. Download the `win-x64` preview ZIP and its `.sha256` file from Releases.
2. Verify the checksum, extract the ZIP, and run:

```powershell
.\Install-DesktopApp.ps1
```

The installer copies `CAAutoConfig.exe` and the control panel to `%LOCALAPPDATA%\CASystemOverlay`, creates a desktop shortcut, and creates the least-privilege `CA System Overlay` task. It starts at Logon and SessionUnlock. The default install does not install camera monitoring, request administrator rights, or apply GPU settings.

The tray icon, tiny lock pill, monitor map, custom shortcut, opacity, and saved position behave the same as the PowerShell-hosted alpha. Both hosts share schema-versioned settings at `%LOCALAPPDATA%\CAAutoConfig\settings.json`. A host that encounters a newer settings schema falls back safely and refuses to overwrite that file.

Settings also has **Copy diagnostics** for low-friction hardware reports. The copied text includes the app/Windows version, architecture, shortcut, selected display, display topology and DPI scale, profile state, and current NVIDIA telemetry/advisor values. It deliberately excludes usernames, machine names, GPU UUIDs, local paths, prompts, outputs, workflows, and image content; inspect the text before posting it publicly.

The release ZIP also includes the optional [`benchmark`](../benchmark/POWER_CURVE_METHOD.md) lab. It records query-only NVIDIA telemetry beside throughput you measured from a workload, rejects common machine identifiers, and produces a scoped Markdown comparison plus a deterministic, evidence-gated SVG share card. Schema-v3 records the power and throughput windows so only aligned evidence becomes `/J`; Ollama/llama.cpp phase rates remain clearly labeled indices, while ComfyUI's same client window can produce aligned `image/J`. A workload gate rejects failed, reset, incomplete, unstable-clock, over-temperature, weak-efficiency, or excessive-throughput-loss candidates. A separate paired idle gate prevents fixture, busy, mixed-driver, or idle-regressing clock-lock evidence from advancing. The adapters omit prompts, responses, local model paths, raw commands, workflows, and output metadata. The lab is not part of the startup task and cannot change a GPU profile.

The ZIP contains a separate optional `CAGpuHelper.exe`. It is not installed by `Install-DesktopApp.ps1`. To opt in, review your board limits and run `Install-GpuLimits.ps1` with explicit GPU indices, MHz, watts, and `-AcceptHardwareRisk`. The installer hash-pins the helper across UAC and registers fixed Apply and Reset SYSTEM tasks. Manual changes require confirmation in the control panel; the protected reset record restores the exact pre-apply power values rather than guessing a universal default.

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
.\tests\GpuLimits.Safety.Tests.ps1
```

The smoke mode tests application startup and settings persistence without opening the HUD, changing GPU settings, or writing outside its temporary result directory.
