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

- **Alpha gate:** tagged source release, checksum, clean secret scan, license, privacy/security documents, Discussions, and repeatable tests. Complete in `v0.1.1-alpha`.
- **Design-partner gate:** at least 10 external Windows/NVIDIA users, three distinct GPU families, five sanitized hardware reports, and no unresolved destructive or privilege-boundary bug.
- **Technical-preview gate:** compiled .NET application, versioned settings migration, simulated telemetry tests, clean-machine install/uninstall, rollback-tested helper, and a short demo.
- **Launch gate:** measured Ollama/llama.cpp or ComfyUI power curve, public methodology, readable first-screen README, tagged binaries, active CI, and issue-response coverage for launch week.

## Distribution sequence

1. Recruit design partners through GitHub Discussions and direct, individual outreach. Do not ask for stars; ask for one defined test.
2. Publish the first reproducible RTX 3090 power/throughput study. Share the method and raw sanitized table before mentioning the product.
3. Post a tailored result to `r/LocalLLaMA`; answer every technical question and document corrections in the repository.
4. Post the overlay and supported-limit safety story to `r/nvidia` only after subreddit rules and promotion frequency have been checked that day.
5. Launch the compiled technical preview as `Show HN`, linking directly to the repository and stating Windows/NVIDIA limitations in the first paragraph.
6. Give local-AI creators a personalized reproduction package: one workload, one expected chart, exact commands, and a clear disclosure that there is no sponsorship unless that changes.
7. Turn repeated questions into documentation and ship small releases during the first week.

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

Use stars as a distribution metric. Use successful installs, retained users, reproducible results, and contributors as product-health metrics.

## Non-negotiable community rules

- No bought or automated stars, votes, comments, testimonials, or benchmark submissions.
- No identical cross-posting, vote requests, undisclosed sponsorship, or private-message blasts.
- Respect each community's current self-promotion rules.
- Lead with reproducible evidence and disclose limitations before calls to action.
- Correct benchmark mistakes publicly and retain the original data with an explanation.
