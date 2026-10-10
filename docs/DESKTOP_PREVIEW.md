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
