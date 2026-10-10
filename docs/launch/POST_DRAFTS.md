# Community post drafts

These are starting points. Re-check community rules and replace bracketed evidence immediately before posting. Do not publish the same copy to multiple communities.

## r/LocalLLaMA — benchmark-first

**Title:** I measured what a lower RTX 3090 power cap actually costs in local-LLM throughput

I run a two-GPU Windows workstation and wanted a better answer than “280 W feels fine.” I tested `[model and quantization]` through `[Ollama/llama.cpp command]` at `[tested limits]`, with `[number]` repeated runs per point.

The useful result: `[one-sentence finding with throughput, watts, and temperature]`.

Method and sanitized raw results: `[benchmark link]`

I also released the small HUD I used to verify that the current-boot cap was really active and to keep power/temperature visible without stealing clicks: `[repository link]`. The advisor is deliberately read-only; it calls values “starting points” until a real workload has been measured.

I would especially value corrections to the benchmark method and results from different 3090 board limits. Please remove GPU UUIDs and machine identifiers from reports.

## r/nvidia — utility-first

**Title:** A click-through Windows HUD that turns red when an NVIDIA power profile did not apply

I built a small open-source HUD for a dual-GPU local-AI workstation. It checks the limit state from the current boot against live power and clock data, then stays click-through over the selected monitor.

The tiny lock control or a configurable shortcut enables dragging and monitor selection. It now shows current/cap watts, temperature, CUDA/SM load, VRAM, CPU, RAM, and storage.

Screenshot and source: `[repository link]`

This is a Windows/NVIDIA alpha. It does not change voltage, never raises an existing lower cap, and does not automatically apply its read-only starting point. I am looking for reports from cards whose `nvidia-smi` power fields behave differently.

## Show HN — compiled technical preview

**Title:** Show HN: CA AutoConfig – a tiny power HUD for local-AI workstations

CA AutoConfig is an open-source Windows HUD for people running local LLMs and diffusion workloads on NVIDIA GPUs.

It verifies that a configured power/clock profile applied after the current boot, shows per-GPU power/load/VRAM/temperature, and lets the user place a click-through overlay on any monitor. The Power Advisor measures real workload throughput before calling a limit “Balanced” or “Eco.”

Repository: `[repository link]`
Demo: `[demo link]`
Benchmark methodology: `[method link]`

The current preview is Windows/NVIDIA only. Monitoring is unprivileged; applying a profile uses a separate minimal elevated helper with explicit confirmation and rollback. There is no application telemetry or account.

I would value feedback on the privilege boundary, workload adapters, and how to make cross-hardware power curves comparable.

## Creator outreach

**Subject:** Reproducible `[GPU]` local-AI power curve—would you challenge the method?

Hi `[name]`,

Your `[specific video/post]` was useful when I was validating `[specific issue]`. I am building CA AutoConfig, an open-source Windows HUD and measured power advisor for local-AI GPUs.

I have a reproducible `[workload]` test that compares `[limits]` and exports watts, temperature, throughput, and errors. Would you be willing to challenge the methodology or run the same test on `[their relevant GPU]`? This is not sponsored and there is no request for a positive mention.

Method: `[link]`
Repository: `[link]`

If it is not relevant to your current work, no response is needed.
