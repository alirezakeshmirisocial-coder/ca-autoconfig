# Product

<!-- impeccable:product-schema 1 -->

## Platform

Windows desktop

## Users

Primary users are local-AI power users running Windows workstations, especially multi-GPU NVIDIA systems. They need continuous telemetry and reproducible efficiency evidence without losing focus, pointer input, privacy, or control of privileged hardware changes.

Contributors and design partners reproduce installation, display placement, telemetry, and workload-power behavior across hardware. They need strict evidence boundaries and low-friction privacy-safe reports.

## Product Purpose

CA AutoConfig is a tiny click-through workstation HUD and conservative GPU power companion. It makes the current system state visible, verifies whether an explicitly configured GPU profile actually applied, and helps users measure power-versus-throughput tradeoffs before considering a limit.

Success means reliable normal-user monitoring, explicit and reversible hardware changes, reproducible workload evidence, useful cross-hardware contributions, and genuine open-source adoption. The public growth objective is 5,000 genuine GitHub stars, treated as a distribution outcome rather than proof of quality or a metric to manufacture.

## Positioning

CA AutoConfig joins four normally separate jobs: unobtrusive multi-monitor HUD placement, current-boot GPU-profile verification, vendor-range-aware read-only starting points, and privacy-checked local-AI power curves. It does not present one maintainer's wattage as a universal recommendation.

## Operating Context

The HUD starts at Logon and SessionUnlock, stays click-through while locked, and runs as the standard user. Users choose a real display from its topology, position the HUD, and define a global lock shortcut. Optional GPU writes remain in a separate UAC/elevated path. Ollama, llama.cpp, ComfyUI, and generic benchmark workflows produce local anonymized JSON, Markdown reports, and evidence-gated SVG cards.

GitHub Releases, Issues, Discussions, the hardware matrix, and reproducible benchmark artifacts are the public collaboration surface. Camera presence and the unlock guard remain separate opt-in experiments rather than the default product promise.

## Capabilities and Constraints

- Current public alpha: Windows 10/11, self-contained .NET 8 WinForms, NVIDIA telemetry and optional limit control.
- Tiny explicit lock/unlock control; locked HUD is click-through and does not take focus.
- Visual monitor topology, persistent per-display position, configurable shortcut and opacity.
- CPU, RAM, drive, CUDA/SM, VRAM, watts/cap, temperature, and clock telemetry.
- Read-only advisor stays inside driver-reported ranges, never raises an existing lower cap, and requires real workload evidence before stronger profile claims.
- Monitoring has no application network client or product analytics. Benchmark adapters are local/loopback-first and omit prompts, outputs, workflows, paths, machine identifiers, and GPU UUIDs from exports.
- GPU mutation is opt-in, explicit, elevated, UUID-pinned, preflighted, verified, and rollback-aware. Unknown or malformed evidence fails closed/red.
- AMD/Intel telemetry, signed artifacts, active Windows build/package CI, clean-machine coverage, and hardened native privilege isolation remain open work. GitHub default CodeQL analysis is active for C# and Python, but it does not satisfy those platform/release gates.

## Brand Commitments

The product name is **CA AutoConfig**. Public language is direct, technical, evidence-led, and calm. It must disclose alpha status, unsupported hardware, fixture data, missing repetitions, privacy limits, and safety boundaries before calls to action. No bought stars, automated endorsements, brigading, hidden sponsorships, universal-limit claims, or fabricated benchmark/customer evidence.

## Evidence on Hand

- Live maintainer evidence: Windows 10 Pro for Workstations, mixed-DPI three-display topology, two RTX 3090 cards, current 280 W / 1700 MHz configured profile, and an installed self-contained HUD.
- A bounded 120-second observation of the installed `v0.2.5-alpha.2` HUD retained 60 responsive samples and publishes normalized CPU plus memory samples without PID/path/identity. This is one idle-host measurement, not a universal footprint promise or a comparison with the current release.
- Deterministic evidence: telemetry failure/identity cases, benchmark schema/report/card tests, Ollama/llama.cpp/ComfyUI fixture adapters, and adaptive thermal-policy simulations.
- Public assets: a no-tracking project homepage, application-only HUD demo, architecture/privacy/security documents, evidence-tiered hardware matrix, checksummed prereleases, and a focused design-partner intake.
- No accepted external hardware reproduction, real workload power curve, customer testimonial, or creator reproduction exists yet. Future work must not imply otherwise.

## Product Principles

1. Evidence before automation: observe and reproduce before recommending or applying.
2. Least privilege by construction: monitoring stays unprivileged; hardware writes are separate and explicit.
3. Unknown is not success: missing, stale, malformed, or mismatched data stays visible and fails closed.
4. Privacy without hidden telemetry: local processing, inspectable exports, and no automatic upload.
5. Community trust over vanity growth: publish raw method and failures, correct mistakes publicly, and earn adoption without manipulating votes.

## Accessibility & Inclusion

The HUD and Settings use keyboard-accessible native controls, an explicit lock state, accessible names/descriptions, readable contrast, DPI-aware rendering, and color plus text rather than color alone for health states. Generated evidence cards include SVG title/description metadata and retain all essential warnings as visible text.
