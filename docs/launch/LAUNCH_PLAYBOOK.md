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
- **Technical-preview gate — partial:** compiled .NET application, versioned settings migration, and a privacy-safe demo are complete. Simulated telemetry providers, clean-machine install/uninstall, signing, and the hardened apply/reset helper remain open.
- **Launch gate — blocked on evidence:** the deterministic share-card generator is ready, but launch still requires a measured Ollama/llama.cpp or ComfyUI power curve, public methodology and raw results, active CI, tagged signed binaries, and issue-response coverage for launch week.

## What current communities reward

The October 2026 check changes the launch strategy:

- `r/LocalLLaMA` now enforces a self-promotion ceiling around 10% of account activity and expects meaningful participation in other people's threads first. Its moderators also reject undisclosed copy-pasted LLM prose. A benchmark post must be written and discussed by the maintainer, not automatically posted. See the [rule update](https://www.reddit.com/r/LocalLLaMA/comments/1su3ao4/rlocalllama_rule_updates/) and a [recent enforcement example](https://www.reddit.com/r/LocalLLaMA/comments/1wyf12e/removed/).
- The topic itself has strong demand: a recent power-limit experiment drew hundreds of votes, while earlier RTX 3090 studies drew detailed method criticism. The recurring requests are token/Joule, exact board/model/quant, full commands, repeated runs, wall-power context, and separate prompt-processing from token-generation results. See [Stop wasting electricity](https://www.reddit.com/r/LocalLLaMA/comments/1tayu5t/stop_wasting_electricity/), [relative performance at different limits](https://www.reddit.com/r/LocalLLaMA/comments/1hg6qrd/relative_performance_in_llamacpp_when_adjusting/), and [tokens per watt-hour discussion](https://www.reddit.com/r/LocalLLaMA/comments/1jc1nw1/actual_electricity_consumption_and_cost_to_run/).
- `r/StableDiffusion` permits open-source, free, or local tools once per tool/guide/update, but it is only a fit after a real ComfyUI or diffusion power curve exists. Re-check the [current rules](https://www.reddit.com/r/StableDiffusion/comments/1f4zznt/updated_rules_for_this_subreddit/) immediately before posting.
- Show HN requires something people can run without a signup, discourages asking anyone to vote, and explicitly bans generated or AI-edited submission text and comments. CA AutoConfig can supply a fact sheet, but the maintainer must write the HN title, launch text, and replies personally. See the official [Show HN](https://news.ycombinator.com/showhn.html) and [HN](https://news.ycombinator.com/newsguidelines.html) guidelines.

The practical conclusion is simple: the first growth asset is a reproducible Windows RTX 3090 power curve, not another promotional screenshot.

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
