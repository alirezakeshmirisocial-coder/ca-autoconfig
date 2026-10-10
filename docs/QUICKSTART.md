# CA AutoConfig quick start

This is the shortest supported path from the published alpha to the default HUD. It is for **Windows 10/11 x64 with an NVIDIA GPU**. The package is self-contained, so the target machine does not need the .NET SDK or runtime.

> The current alpha is unsigned. Verify the exact archive before extracting it, and stop if any check fails. The default HUD install does not request administrator rights, install the camera experiment, or change GPU power, clocks, voltage, or fans.

## 1. Download the three release assets

Save all three files in the same directory:

- [CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/releases/download/v0.2.6-alpha.4/CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip)
- [CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.sha256](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/releases/download/v0.2.6-alpha.4/CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.sha256)
- [Verify-DesktopPackage.ps1](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/releases/download/v0.2.6-alpha.4/Verify-DesktopPackage.ps1)

Published ZIP SHA-256:

```text
0a71a120139bf10e36bdad1c816cbd07b9fbcac9651ef498ba214862b32f3b6d
```

## 2. Verify before extraction

Open PowerShell in the download directory. First compare Windows' own digest with the published value:

```powershell
(Get-FileHash -LiteralPath .\CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip -Algorithm SHA256).Hash.ToLowerInvariant()
```

Only after that value matches exactly, allow the small verifier script to run and perform the complete offline archive check:

```powershell
Unblock-File -LiteralPath .\Verify-DesktopPackage.ps1
.\Verify-DesktopPackage.ps1 `
  -PackagePath .\CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip `
  -ExpectedVersion 0.2.6-alpha.4
```

The verifier checks the companion digest, traversal and absolute paths, case-insensitive duplicate entries, expansion size, required files, and declared version without extracting or executing the archive.

## 3. Extract and install the default HUD

After the verifier reports success:

```powershell
Unblock-File -LiteralPath .\CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip
Expand-Archive `
  -LiteralPath .\CA-AutoConfig-Desktop-v0.2.6-alpha.4-win-x64.zip `
  -DestinationPath .\CA-AutoConfig-v0.2.6-alpha.4
Set-Location .\CA-AutoConfig-v0.2.6-alpha.4
.\Install-DesktopApp.ps1
```

The installer copies the HUD to `%LOCALAPPDATA%\CASystemOverlay`, creates the `CA System Overlay` least-privilege task for Logon and SessionUnlock, starts it, and adds a `CA AutoConfig` desktop shortcut. It installs only the HUD.

## 4. First minute

1. The HUD starts locked and click-through. Only the small lock control remains clickable.
2. Click the lock or press `Ctrl+Alt+L` to enter edit mode.
3. Right-click the unlocked HUD, double-click its tray icon, or open **HUD settings** from the desktop shortcut.
4. Pick a monitor from the visual display map, drag the HUD, choose a shortcut and opacity, then lock it again.
5. Confirm that each NVIDIA card shows live watts, cap, temperature, clock, CUDA/SM load, and VRAM. A red profile indicator means the configured current-boot limit was not verified; it does not apply a change.

Settings are local at `%LOCALAPPDATA%\CAAutoConfig\settings.json`. **Copy diagnostics** creates an inspectable report that omits usernames, machine names, GPU UUIDs, local paths, prompts, and outputs.

## Remove the HUD

From the extracted release directory:

```powershell
.\Uninstall-SystemOverlay.ps1 -RemoveFiles
```

This removes the task, installed HUD files, and desktop shortcut. Local preferences remain for a future reinstall.

## Optional components are separate

The camera/presence experiment, benchmark lab, and privileged GPU helper are not part of this quick start. The read-only advisor may show a conservative **benchmark starting point**, but it never applies one. Any GPU-setting installation requires a separate plan, explicit values for the exact boards, UAC, and hardware-risk acknowledgement. `280 W / 1700 MHz` is maintainer configuration—not a universal recommendation.

If something fails, keep the failure and use the [bug form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=bug.yml). For monitor placement, shortcut, click-through, or mixed-DPI behavior, use the focused [display/HUD report](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=display-result.yml). No star is required.
