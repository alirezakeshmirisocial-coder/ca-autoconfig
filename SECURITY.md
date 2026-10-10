# Security policy

CA AutoConfig reads system telemetry and can optionally invoke a narrowly scoped elevated helper to apply GPU limits. The face-presence experiment processes biometric material locally. Reports involving privilege boundaries, command execution, scheduled tasks, settings-file tampering, biometric data, or unintended network access are security-sensitive.

## Supported versions

The project is currently a personal alpha. Only the newest commit and newest published release will receive security fixes until the first stable release.

## Reporting a vulnerability

Do not open a public issue containing exploit details, biometric data, tokens, webhook addresses, machine identifiers, or private logs. Use GitHub's private vulnerability-reporting feature once the public repository is available. Until then, contact the maintainer privately and include the affected component, reproduction steps, required privileges, impact, and a minimal proof of concept with personal data removed.

We aim to acknowledge a complete report within three business days. A fix and disclosure timeline depends on severity and whether the issue affects the unprivileged HUD, elevated GPU helper, or optional presence component.

## Safety boundaries

- Monitoring should run without administrator rights.
- Elevation is required only for applying or resetting GPU limits and installing privileged scheduled tasks.
- Power recommendations are read-only candidates until the user explicitly starts a benchmark and confirms an apply operation.
- Recommendations must remain inside vendor-reported limits and must not exceed the vendor default.
- The RGB-camera presence feature is not liveness detection and is not a replacement for Windows Hello, BitLocker, or a strong Windows credential.
