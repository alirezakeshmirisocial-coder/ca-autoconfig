# Security policy

CA AutoConfig reads system telemetry and can optionally invoke a narrowly scoped elevated helper to apply GPU limits. The face-presence experiment processes biometric material locally. Reports involving privilege boundaries, command execution, scheduled tasks, settings-file tampering, biometric data, or unintended network access are security-sensitive.

## Supported versions

The project is currently a personal alpha. Only the newest commit and newest published release will receive security fixes until the first stable release.

## Reporting a vulnerability

Do not open a public issue containing exploit details, biometric data, tokens, webhook addresses, machine identifiers, or private logs. Use the repository's [private vulnerability-reporting form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/security/advisories/new) and include the affected component, reproduction steps, required privileges, impact, and a minimal proof of concept with personal data removed.

We aim to acknowledge a complete report within three business days. A fix and disclosure timeline depends on severity and whether the issue affects the unprivileged HUD, elevated GPU helper, or optional presence component.

## Safety boundaries

- Monitoring should run without administrator rights.
- Elevation is required only for applying or resetting GPU limits and installing privileged scheduled tasks.
- The two SYSTEM tasks execute only an administrator-owned, hash-pinned compiled helper from a non-reparse-point directory. Normal users can read and run the fixed Apply/Reset tasks but cannot modify their commands.
- The helper accepts only strict `apply` or `reset` grammars, invokes the fixed System32 `nvidia-smi.exe` without a shell, preflights every UUID-pinned target, and refuses standard-user direct execution.
- Before UAC, the read-only planner queries selected cards and rejects values outside any vendor range/default/maximum clock. Raising a current cap needs a separate acknowledgement that is preserved as a fixed helper argument and independently enforced inside the helper.
- Apply writes an atomic protected record of exact pre-change values before mutation. Reset consumes that record; it never guesses targets or rollback power limits.
- Power recommendations are read-only candidates until the user explicitly starts a benchmark and confirms an apply operation.
- Recommendations must remain inside vendor-reported limits and must not exceed the vendor default.
- Release consumers can run `Verify-DesktopPackage.ps1` before extraction; it validates the separately published SHA-256, rejects unsafe/duplicate archive paths and oversized expansion, and checks the declared version and required install files without executing package content.
- The Ollama adapter is loopback-only by default, never pulls a model, and has no GPU-write or elevation path; remote prompt transmission requires an explicit flag.
- The llama.cpp adapter accepts only explicit local executable/model paths, has no network/download/elevation path, uses query-only NVIDIA telemetry, and never exports the child command, model path, stdout, or stderr.
- The ComfyUI adapter is loopback-only by default with redirects disabled, requires an empty queue and exact terminal image count, never calls global interrupt/free/history-delete routes, and exports neither the submitted workflow nor server history/output metadata; remote workflow transmission requires an explicit flag.
- The RGB-camera presence feature is not liveness detection and is not a replacement for Windows Hello, BitLocker, or a strong Windows credential.
