# Phase-aligned energy evidence

Research check: 2026-10-10.

CA AutoConfig's benchmark path must distinguish a throughput rate divided by some observed wattage from actual work per Joule. The units become physically meaningful only when the numerator and denominator describe the same time window.

## Evidence that shaped the design

- The official [Ollama generate response](https://docs.ollama.com/api/generate) exposes separate prompt-evaluation and generation counters after an end-to-end request. Sampling board power for the whole request does not isolate either phase.
- The official [`llama-bench` documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/llama-bench/README.md) reports prompt-processing and token-generation operations separately. CA AutoConfig currently samples the surrounding child-process lifetime, including work outside those operation windows.
- [TokenPowerBench](https://arxiv.org/abs/2512.03024) treats phase alignment as a first-class measurement problem rather than combining unrelated rate and power intervals.
- A 2026 consumer-GPU study measured mean/peak power, Joules per prompt, Joules per output token, and throughput separately across fixed prompts, reinforcing the need to preserve the measurement scope: [Energy Efficiency of Locally Deployed LLMs](https://arxiv.org/abs/2608.00008).
- Recent LocalLLaMA results show why a single “best wattage” is unsafe: a four-RTX-3090 report found decode largely flat while prompt processing degraded at lower power, and another current thread asked for an optimal 3090 limit after a deliberately informal test. These are useful demand signals, not universal hardware evidence: [four-card curve](https://www.reddit.com/r/LocalLLaMA/comments/1te9o18/finding_the_4x_3090_sweet_spot/), [single-card question](https://www.reddit.com/r/LocalLLaMA/comments/1w1x24p/rtx_3090_inference_optimal_power/).
- Community testing has also reported that persistent graphics-clock locks can increase idle draw on some NVIDIA setups until reset. CA AutoConfig treats this as an unverified cross-hardware risk that needs an idle-baseline gate, not as a fact to generalize from one report: [llama.cpp clock-limit discussion](https://www.reddit.com/r/LocalLLaMA/comments/1hg6qrd/relative_performance_in_llamacpp_when_adjusting/).

## Product decision

Schema-v3 requires four provenance fields:

| Field | Meaning |
| --- | --- |
| `powerWindow` | Interval covered by GPU board-power samples. |
| `promptRateWindow` | Interval represented by prompt throughput, or `null`. |
| `generationRateWindow` | Interval represented by generation throughput, or `null`. |
| `workRateWindow` | Interval represented by generalized work throughput, or `null`. |

The analyzer emits an exact `/J` value only when the relevant rate window equals `powerWindow`. Otherwise it emits a visibly named rate/power index and preserves both windows in Markdown, SVG text, and accessible SVG metadata. Schema-v1/v2 remain readable but cannot acquire an exact energy claim because they lack phase provenance.

Current adapter semantics:

| Adapter | Power window | Rate window | Allowed claim |
| --- | --- | --- | --- |
| Generic recorder | `steady-state` | `steady-state` | Aligned token/J when the user followed the same-window protocol. |
| Ollama | `end-to-end-request` | `prompt-phase` / `generation-phase` | Rate/power index only. |
| llama.cpp | `process-window` | `prompt-phase` / `generation-phase` | Rate/power index only. |
| ComfyUI | `client-window` | `client-window` | Aligned work/J for the scoped client-observed workflow. |

## Next evidence gates

1. Add phase-specific power sampling before promoting Ollama or llama.cpp indices to token-energy metrics.
2. Capture a pre-profile and post-profile idle baseline before recommending a persistent clock lock.
3. Require throughput retention, temperature, errors, and repeated interleaved runs before naming Balanced, Eco, or Quiet profiles.
4. Use a wall meter for whole-system cost claims; board telemetry alone is not household energy use.

No item in this research note authorizes a GPU write or establishes a universal wattage.
