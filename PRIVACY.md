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

The HUD and GPU helper make no network requests. The Ollama benchmark adapter calls `http://127.0.0.1:11434` by default and refuses a non-loopback endpoint unless the user passes `-AllowRemoteEndpoint`; that explicit override sends the supplied prompt to the chosen server. The adapter never writes prompt text or generated text into its benchmark export and does not upload the export. The llama.cpp adapter has no network client or download path: it launches only the explicit local `llama-bench` and GGUF inputs. Its export omits the model path, raw command, child stdout/stderr, and llama-bench CPU/GPU identity fields. The ComfyUI adapter likewise defaults to loopback and requires explicit remote opt-in because it sends the complete API workflow; its export omits that workflow, prompt text, server history, generated-output metadata, endpoint, prompt ID, paths, and seed values. It never fetches generated files. The guard has an optional user-supplied failure webhook; it is disabled unless the user configures a URL. Future update checks, benchmark sharing, or community leaderboards must be opt-in and documented before release.

## Public reports

Before sharing a log, screenshot, or benchmark, remove usernames, computer names, GPU UUIDs, monitor contents, personal paths, webhook addresses, tokens, and biometric material. Hardware models, driver versions, supported power ranges, anonymized temperatures, watts, and workload throughput are generally useful without those identifiers.
