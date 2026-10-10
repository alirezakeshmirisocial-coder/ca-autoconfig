# Compiled desktop preview

The compiled preview packages the tested HUD as a self-contained .NET 8 Windows application. It does not require PowerShell source compilation or a separately installed .NET runtime on the target machine.

## Install

1. Download the `win-x64` preview ZIP and its `.sha256` file from Releases.
2. Verify the checksum, extract the ZIP, and run:

```powershell
.\Install-DesktopApp.ps1
```

The installer copies `CAAutoConfig.exe` to `%LOCALAPPDATA%\CASystemOverlay` and creates the existing least-privilege `CA System Overlay` task. It starts at Logon and SessionUnlock. It does not install camera monitoring, request administrator rights, or apply GPU settings.

The tray icon, tiny lock pill, monitor map, custom shortcut, opacity, and saved position behave the same as the PowerShell-hosted alpha. Both hosts share schema-versioned settings at `%LOCALAPPDATA%\CAAutoConfig\settings.json`. A host that encounters a newer settings schema falls back safely and refuses to overwrite that file.

Settings also has **Copy diagnostics** for low-friction hardware reports. The copied text includes the app/Windows version, architecture, shortcut, selected display, display topology and DPI scale, profile state, and current NVIDIA telemetry/advisor values. It deliberately excludes usernames, machine names, GPU UUIDs, local paths, prompts, outputs, workflows, and image content; inspect the text before posting it publicly.

The release ZIP also includes the optional [`benchmark`](../benchmark/POWER_CURVE_METHOD.md) lab. It records query-only NVIDIA telemetry beside throughput you measured from a workload, rejects common machine identifiers, and produces a scoped Markdown comparison plus a deterministic, evidence-gated SVG share card. Schema-v3 records the power and throughput windows so only aligned evidence becomes `/J`; Ollama/llama.cpp phase rates remain clearly labeled indices, while ComfyUI's same client window can produce aligned `image/J`. A separate paired idle recorder and regression gate prevent fixture, busy, incomplete, mixed-driver, or idle-regressing clock-lock evidence from advancing toward a recommendation. The adapters omit prompts, responses, local model paths, raw commands, workflows, and output metadata. The lab is not part of the startup task and cannot change a GPU profile.

## Remove

```powershell
.\Uninstall-SystemOverlay.ps1
```

This removes the scheduled task. Local preferences remain so an upgrade can preserve the selected display, position, opacity, and shortcut.

## Build and verify

Use the .NET 8 SDK:

```powershell
.\Build-DesktopApp.ps1 -SelfContained
.\tests\DesktopApp.Smoke.Tests.ps1 -SelfContained
```

The smoke mode tests application startup and settings persistence without opening the HUD, changing GPU settings, or writing outside its temporary result directory.
