# Maintainer evidence

This directory contains small, privacy-reviewed outputs from explicit maintainer runs. Evidence is committed only when the exact collection command is read-only, the report carries its own safety flags, failures are retained, and the file contains no raw adapter identifier, process identifier, username, machine name, personal path, prompt, workflow, model path, token, or generated content.

Each file proves only the fields and environment stated in its companion research note or hardware-matrix row. It does not prove cross-hardware compatibility, safe GPU settings, workload efficiency, clean-machine installation, or authorization to enable an experimental provider in the HUD.

## Current files

| File | Scope | SHA-256 |
| --- | --- | --- |
| [`windows-gpu-pdh-fields-600s-2026-10-10.json`](windows-gpu-pdh-fields-600s-2026-10-10.json) | Dual RTX 3090, Windows 10, standard-user native-PDH field-isolation run; 300/300 memory-valid and 285/300 engine-valid collections | `aed1d30d006b349e7c0ce2c614b6f24b7e5df349cf846b34e99a6cc93619aa27` |
| [`windows-gpu-pdh-persistent-600s-2026-10-10.json`](windows-gpu-pdh-persistent-600s-2026-10-10.json) | Same host and cadence with one baseline-once persistent PDH query; 300/300 memory-valid and 292/300 engine-valid collections | `bbf6f38e9c3764bec6822a59747698901b09f3d504965380fc3f34fba2705b35` |
| [`windows-gpu-pdh-adapter-recovery-600s-2026-10-10.json`](windows-gpu-pdh-adapter-recovery-600s-2026-10-10.json) | Same host/cadence with adapter-scoped failure retention and fresh-baseline recovery after an invalid formatted item; 300/300 memory-valid and 294/300 engine-valid collections | `87810c22c94ddeab2a15d6ed9ec750b8c0032b549f02d919f114ee36a246fbb9` |
| [`windows-gpu-pdh-raw-600s-2026-10-10.json`](windows-gpu-pdh-raw-600s-2026-10-10.json) | Same host/cadence with explicit adjacent raw pairing, guarded duplicate aggregation, and proven zero baselines; 300/300 memory-valid and 300/300 engine-valid collections | `96d9f1df738ba9d1af0822f808a346912eb43b0ae24a5628c4e9eaf9df7195f4` |
| [`windows-gpu-pdh-raw-churn-60s-2026-10-10.json`](windows-gpu-pdh-raw-churn-60s-2026-10-10.json) | Same host with a local WebGL GPU process starting and stopping during the run; 29/30 engine-valid, 30/30 memory-valid, one retained baseline-missing partial, zero unavailable/overlap collections | `db9a4c0e6aeb0030987a8738c97105e48d7e0c2bba04afc629b030b5bff0b1cb` |
| [`windows-gpu-pdh-raw-churn-summary-60s-2026-10-10.json`](windows-gpu-pdh-raw-churn-summary-60s-2026-10-10.json) | Sanitized harness proof linking the exact polling report hash to the token-scoped local browser process and positive process-specific GPU counters | `9622af28be08055a1328e88876fcd0e10ffc1dcb311842a3db5513046d73c413` |

The committed JSON retains its final newline, so its repository-file digest intentionally differs from any otherwise identical no-final-newline scratch artifact.

External results belong in the [Windows GPU telemetry form](https://github.com/alirezakeshmirisocial-coder/ca-autoconfig/issues/new?template=windows-gpu-result.yml) first. They are reviewed for provenance, completeness, failure retention, and privacy before a repository evidence row is added. A star is never requested or required.
