# Clean-machine Windows Sandbox check

This harness prepares a disposable, offline Windows Sandbox test for the desktop ZIP. It is designed to produce install/uninstall evidence without changing the host's scheduled tasks, application files, GPU profile, or network state.

Windows Sandbox must already be enabled by the operator. The generator does not enable Windows features or request elevation.

## Prepare

From a source checkout, point the generator at the downloaded ZIP and checksum:

```powershell
.\tools\New-CleanMachineSandbox.ps1 `
  -PackagePath .\dist\CA-AutoConfig-Desktop-v0.2.6-alpha.3-win-x64.zip `
  -ExpectedVersion 0.2.6-alpha.3
```

The command first runs the offline package verifier, then creates a unique directory under `artifacts`. Its `.wsb` configuration maps package inputs read-only, maps only a dedicated result directory as writable, and disables networking, vGPU, audio/video input, printers, and clipboard sharing.

Open the returned `.wsb` file manually, or pass `-Launch` when Windows Sandbox is already installed. No automatic installation or feature enablement occurs.

## What the sandbox checks

Inside the disposable Windows instance, the fixed runner:

1. verifies the checksum, archive paths, required files, expansion bound, and declared version;
2. extracts only inside the sandbox and runs the desktop no-hardware-write smoke mode;
3. installs the HUD, checks its least-privilege scheduled task, Logon and SessionUnlock triggers, executable, control panel, and desktop shortcut;
4. uninstalls with `-RemoveFiles` and confirms that the task, install directory, and shortcut are gone;
5. writes only `clean-machine-result.json` to the mapped host result directory.

The evidence file omits user and machine names, paths, GPU identifiers, and application content. A passing result is clean-machine evidence for that exact release and Windows build; it does not validate NVIDIA telemetry, GPU mutation, sleep/resume, driver reset, or code signing.

Submit a reviewed result through the [clean-machine result form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=clean-machine-result.yml). Keep failures and inspect the JSON before posting.

## Current evidence boundary

The harness is deterministically tested, but the maintainer host used to prepare it does not currently expose `WindowsSandbox.exe`. Until a real result JSON is reviewed, the public clean-machine release gate remains open.
