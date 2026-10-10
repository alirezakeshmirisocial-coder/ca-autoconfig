# Community post drafts

These are evidence checklists and starting points. Re-check community rules and replace bracketed evidence immediately before posting. Do not publish the same copy to multiple communities.

`r/LocalLLaMA` and Hacker News both reject low-effort generated prose. The maintainer must rewrite Reddit material in their own voice and disclose meaningful AI assistance; Hacker News text and replies must be written by the maintainer without AI generation or editing.

## r/LocalLLaMA — benchmark-first

Do not copy/paste this draft. Post only after meaningful participation in other people's discussions keeps self-promotion below the current 10% limit.

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

## r/StableDiffusion — only after ComfyUI evidence

Use the community's one-per-tool/guide/update allowance only when a real diffusion benchmark exists. Lead with workflow, image dimensions, sampler/steps, batch size, repeated-run variance, images/second, watt-hours/image, thermals, and the raw export. The HUD belongs in the final paragraph as the reproducibility tool, not in the title.

## Show HN — owner-written fact sheet

Do not turn this section into a draft. Hacker News prohibits generated and AI-edited post text and replies. The maintainer should independently write a short launch explanation from these verified facts:

- Public repository and self-contained `win-x64` download; no signup.
- Tiny click-through WinForms HUD with an explicit lock/edit state.
- Per-monitor placement, custom global hotkey, CPU/RAM/storage, and per-GPU CUDA/SM, VRAM, watts, cap, temperature, and clock.
- Read-only advisor in the standard-user process; explicit UAC and a separate protected task for opt-in hardware changes.
- No application network client or product telemetry.
- Windows/NVIDIA-only alpha; unsigned ZIP; current limitations linked up front.
- Demo, architecture document, benchmark method, and raw power curve available before submission.
- The maintainer will be present to answer questions and will not ask anyone to vote or comment.

## Creator outreach

**Subject:** Reproducible `[GPU]` local-AI power curve—would you challenge the method?

Hi `[name]`,

Your `[specific video/post]` was useful when I was validating `[specific issue]`. I am building CA AutoConfig, an open-source Windows HUD and measured power advisor for local-AI GPUs.

I have a reproducible `[workload]` test that compares `[limits]` and exports watts, temperature, throughput, and errors. Would you be willing to challenge the methodology or run the same test on `[their relevant GPU]`? This is not sponsored and there is no request for a positive mention.

Method: `[link]`
Repository: `[link]`

If it is not relevant to your current work, no response is needed.
