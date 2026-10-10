# CA AutoConfig launch playbook

## Positioning

**CA AutoConfig is a tiny Windows HUD that verifies NVIDIA power caps and helps local-AI users find efficient limits with evidence.**

The wedge is not generic monitoring. The product connects four questions that are normally split across tools and shell commands:

1. Did the configured power and clock profile apply after this boot?
2. What are both cards drawing right now?
3. Which display and position keep the data useful but out of the way?
4. How much real AI throughput is lost when power is reduced?

Camera presence is an optional experiment, not part of the public product promise. Workload-aware recommendations must be earned through measured adapters; a static percentage is only a benchmark starting point.

## Launch gates

The repository can remain public while these gates control broader promotion:

- **Alpha gate — complete:** tagged source and self-contained releases, checksum, clean secret scan, license, privacy/security documents, Discussions, architecture map, and repeatable tests.
- **Design-partner gate — open:** at least 10 external Windows/NVIDIA users, three distinct GPU families, five sanitized hardware reports, and no unresolved destructive or privilege-boundary bug.
- **Technical-preview gate — partial:** compiled .NET application, versioned settings migration, privacy-safe demo, deterministic telemetry failures, the transactional compiled Apply/Reset helper, and an offline Windows Sandbox test harness are complete. A real clean-machine result, upgrade testing, sleep/driver-reset recovery, active CI, and signing remain open.
- **Launch gate — blocked on evidence:** the deterministic share-card generator is ready, but launch still requires a measured Ollama/llama.cpp or ComfyUI power curve, public methodology and raw results, active CI, tagged signed binaries, and issue-response coverage for launch week.

## What current communities reward

The October 2026 check changes the launch strategy:

- `r/LocalLLaMA` now enforces a self-promotion ceiling around 10% of account activity and expects meaningful participation in other people's threads first. Its moderators also reject undisclosed copy-pasted LLM prose. A benchmark post must be written and discussed by the maintainer, not automatically posted. See the [rule update](https://www.reddit.com/r/LocalLLaMA/comments/1su3ao4/rlocalllama_rule_updates/) and a [recent enforcement example](https://www.reddit.com/r/LocalLLaMA/comments/1wyf12e/removed/).
- The topic itself has strong demand: a recent power-limit experiment drew hundreds of votes, while earlier RTX 3090 studies drew detailed method criticism. The recurring requests are token/Joule, exact board/model/quant, full commands, repeated runs, wall-power context, separate prompt-processing from token-generation, and power-cap versus clock-cap comparisons. Persistent clock locks also have a documented idle-power penalty on some systems. See [Stop wasting electricity](https://www.reddit.com/r/LocalLLaMA/comments/1tayu5t/stop_wasting_electricity/), [relative performance at different limits](https://www.reddit.com/r/LocalLLaMA/comments/1hg6qrd/relative_performance_in_llamacpp_when_adjusting/), [power limit versus clock limit](https://www.reddit.com/r/LocalLLaMA/comments/1ghtl58/final_test_power_limit_vs_core_clock_limit/), and [tokens per watt-hour discussion](https://www.reddit.com/r/LocalLLaMA/comments/1jc1nw1/actual_electricity_consumption_and_cost_to_run/).
- `r/StableDiffusion` permits open-source, free, or local tools once per tool/guide/update, but it is only a fit after a real ComfyUI or diffusion power curve exists. Re-check the [current rules](https://www.reddit.com/r/StableDiffusion/comments/1f4zznt/updated_rules_for_this_subreddit/) immediately before posting.
- Show HN requires something people can run without a signup, discourages asking anyone to vote, and explicitly bans generated or AI-edited submission text and comments. CA AutoConfig can supply a fact sheet, but the maintainer must write the HN title, launch text, and replies personally. See the official [Show HN](https://news.ycombinator.com/showhn.html) and [HN](https://news.ycombinator.com/newsguidelines.html) guidelines.

The practical conclusion is simple: the first growth asset is a reproducible Windows RTX 3090 power curve, not another promotional screenshot.

## Product signals to convert into evidence

The October 2026 refresh reinforces the existing wedge rather than suggesting a generic dashboard:

- Multi-GPU Windows builders are actively comparing two-card versus three-card scaling, PCIe lane width, split modes, and per-card power caps. The useful addition is a privacy-safe topology/per-card imbalance report tied to a real workload—not another aggregate utilization number. See a recent [three-RTX-3090 Windows investigation](https://www.reddit.com/r/LocalLLM/comments/1wg9cio/optimal_llamacpp_setup_for_3_rtx_3090_on_windows/).
- Power, heat, and noise are recurring operator problems. A highly visible community experiment reports large power reductions with little throughput loss, while replies explicitly discuss quiet 3090 operation. CA AutoConfig should answer this with repeatable curves, board-specific limits, thermals, and retained failures; it must not turn one user's watts into a universal preset. See [Stop wasting electricity](https://www.reddit.com/r/LocalLLaMA/comments/1tayu5t/stop_wasting_electricity/) and a recent [quiet 24/7 workstation write-up](https://openclawdc.com/blog/quiet-cooling-local-ai-workstation/).
- VRAM remains the purchase and workload-placement constraint most users recognize. The HUD should keep per-card capacity/pressure legible, and future workload reports should explain imbalance and out-of-memory risk without collecting model names or paths. See the current [VRAM-first local-AI guidance](https://www.windowscentral.com/artificial-intelligence/when-it-comes-to-running-ollama-on-your-pc-for-local-ai-one-thing-matters-more-than-most-heres-why).
- Persistent clock locks can improve loaded efficiency yet increase idle draw. The existing paired idle regression gate therefore stays mandatory before any Quiet/Eco profile can graduate from an experiment.
- Community reports warn that standard GPU temperature can miss memory-junction or board-hotspot problems. Until a documented read-only sensor is available for the exact board, the product should say `unknown` instead of inferring safety from core temperature alone.

These signals translate into four immediate proof assets: one real repeated LLM curve, one real repeated ComfyUI curve, an external mixed-board/mixed-DPI matrix, and a clean-machine signed installer. Each asset should be independently useful even if the reader never installs the HUD.

## Execution cadence toward 5,000 genuine stars

The target is managed as a sequence of evidence and distribution gates, not as a guaranteed date:

1. **0 → 50:** resolve the failed ten-minute Windows engine-counter gate, activate Windows CI, obtain one clean-machine result, and help 10 design partners complete one narrowly defined test. Publish corrections and failures; ask for reports, not stars.
2. **50 → 250:** ship one real interleaved RTX 3090 LLM curve plus raw sanitized data, accept at least 25 hardware reports, and turn the recurring installation/telemetry failures into a compatibility table and two small releases.
3. **250 → 1,000:** sign the installer, publish a real ComfyUI curve, add creator reproduction kits, and earn coverage through results that creators can rerun. The maintainer personally participates in Reddit discussions before any project post.
4. **1,000 → 2,500:** publish an anonymized multi-board dataset, contributor-owned adapters, and a stable upgrade path. Measure accepted reproductions and retained users alongside stars.
5. **2,500 → 5,000:** launch the proven cross-hardware technical preview through distinct community-specific stories, owner-written Show HN text, creator follow-ups, and rapid public issue response. No automated submissions, vote requests, or paid/inauthentic stars.

At every stage, a stalled conversion triggers a product/evidence review—download-to-install, install-to-report, or report-to-contribution—rather than more frequent promotion.

## Distribution sequence

1. Recruit design partners through GitHub Discussions and direct, individual outreach. Do not ask for stars; ask for one defined install or hardware-report test.
2. Participate usefully in existing `r/LocalLLaMA` power and multi-GPU discussions until the maintainer's own-project activity is safely below the community's self-promotion limit.
3. Build the benchmark runner, then publish the first reproducible RTX 3090 power/throughput study. Include raw sanitized data, exact commands, warmup/repetition policy, prompt-processing and generation separately, token/Joule, and uncertainty.
4. Have the maintainer write a result-first `r/LocalLLaMA` post in their own voice; answer every technical question and document corrections in the repository.
5. Run and publish a real repeated ComfyUI diffusion curve before using the one-per-update open-source allowance in `r/StableDiffusion`; the adapter alone is not evidence.
6. Post the overlay and supported-limit safety story to `r/nvidia` only after subreddit rules and promotion frequency have been checked that day.
7. After clean-machine verification, active CI, and at least five external reports, have the maintainer write and submit Show HN personally. Do not automate the submission or replies and do not ask anyone to vote.
8. Give local-AI creators a personalized reproduction package: one workload, one expected chart, exact commands, and a clear disclosure that there is no sponsorship unless that changes.
9. Turn repeated questions into documentation and ship small releases during the first week.

The Rybbit team reports that a clear pain point plus coordinated, community-specific posts helped it reach 5,000 stars quickly; this is useful launch evidence, not a repeatable guarantee: <https://rybbit.com/blog/5k-stars>. Research on GitHub stars also treats stars as attention/interest signals rather than proof of software quality: <https://arxiv.org/abs/1811.07643>.

## Growth milestones

- **50 stars / 10 testers:** validate installation, monitor selection, and telemetry fields.
- **250 stars / 25 hardware reports:** publish a compatibility matrix and first external benchmark summary.
- **1,000 stars / 10 contributors:** ship the compiled technical preview and first workload adapter.
- **2,500 stars / 100 benchmark submissions:** publish the anonymized power-curve dataset and shareable result card.
- **5,000 stars:** requires a useful cross-hardware dataset, reliable installer, multiple workload adapters, creator coverage, and sustained community response—not a one-day voting campaign.

## Metrics

Record weekly:

- unique release downloads and checksum downloads;
- stars and forks by day;
- design partners who completed installation;
- hardware reports accepted/rejected and why;
- benchmark submissions by GPU/workload;
- contributors and merged pull requests;
- median first response and time-to-fix;
- referral source for documentation and release pages, without adding application telemetry.

Keep a source label on every legitimate launch link (`github`, `discussion`, `reddit-localllama`, `reddit-stablediffusion`, `hn`, `creator`) and record daily deltas for seven days. Do not use tracking inside the desktop application.

Use stars as a distribution metric. Use successful installs, retained users, reproducible results, and contributors as product-health metrics.

## Non-negotiable community rules

- No bought or automated stars, votes, comments, testimonials, or benchmark submissions.
- No identical cross-posting, vote requests, undisclosed sponsorship, or private-message blasts.
- No generated or AI-edited HN submission text or replies; no automated HN posting.
- No `r/LocalLLaMA` project post until the maintainer has meaningful non-promotional participation and the account remains below the current self-promotion limit.
- Respect each community's current self-promotion rules.
- Lead with reproducible evidence and disclose limitations before calls to action.
- Correct benchmark mistakes publicly and retain the original data with an explanation.
