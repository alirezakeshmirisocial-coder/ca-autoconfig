# Privacy

CA AutoConfig is designed to work locally. The hardware HUD reads Windows and NVIDIA telemetry and does not transmit it. There is no analytics SDK, account requirement, advertising identifier, or automatic benchmark upload in the current alpha.

## Local data

- HUD preferences: `%LOCALAPPDATA%\CAAutoConfig\settings.json`
- HUD diagnostic errors: `%LOCALAPPDATA%\CASystemOverlay\overlay-errors.log`
- GPU-limit state and logs: `C:\ProgramData\CAGpuLimits`
- Presence-lab embeddings and event logs: `%LOCALAPPDATA%\CAUnlockGuardLab`
- Installed guard data: `%LOCALAPPDATA%\CAUnlockGuard`

The face components store local model data or embeddings. They do not need to save raw video, but biometric templates are still sensitive local data and should not be committed, uploaded, or attached to issues.

## Network behavior

The HUD and GPU helper make no network requests. The guard has an optional user-supplied failure webhook; it is disabled unless the user configures a URL. Future update checks, benchmark sharing, or community leaderboards must be opt-in and documented before release.

## Public reports

Before sharing a log, screenshot, or benchmark, remove usernames, computer names, GPU UUIDs, monitor contents, personal paths, webhook addresses, tokens, and biometric material. Hardware models, driver versions, supported power ranges, anonymized temperatures, watts, and workload throughput are generally useful without those identifiers.
