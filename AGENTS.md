# Contributor and agent guide

These instructions apply to the repository. They consolidate the product owner's decisions from TokenTick's development discussions on data ownership, schema simplification, native UI, localization, releases, and planned storage analysis. They are durable maintenance rules, not permission to execute past requests again.

## Start with the relevant contract

- Read [README.md](README.md) for user-facing behavior and commands.
- Read [docs/requirements.md](docs/requirements.md) for product scope and planned work.
- Read [docs/technical-design.md](docs/technical-design.md) for schema, algorithms, and maintenance.
- Inspect the current source, branch, and working tree before editing. Preserve unrelated changes, including deletions from another task.
- Keep README, documentation, code comments, script messages, and CLI help in English. Preserve Simplified Chinese translations and intentional multilingual test data. Respond in the user's requested language.

TokenTick targets **macOS 26+ and Apple Silicon only**, using Swift 6, native SwiftUI, shared Core, and SQLite. The default branch is `master`. Do not introduce Intel support, a cross-platform layer, a provider framework, WebView UI, cloud sync, or a persistent daemon without a scope decision.

## Keep changes small and evidence-based

Read the source and contracts needed for the change once, then work from them. Prefer existing capabilities. Extract helpers only when they express a clear responsibility or constraint; avoid speculative abstractions and redundant state. A refactor preserves business behavior and UI unless the request explicitly changes them.

Use `rtk` for inspection, searches, diffs, logs, and verification when available; use `rtk proxy` for commands that need unfiltered output. Keep large logs bounded in the conversation and retain complete output under `.build` when useful.

Collection, Pricing, Synchronization, Storage, and UI have separate responsibilities. Keep destination SQL in Storage and shared business rules in Core. Preserve existing transaction, batching, cancellation, and cross-process locking boundaries when moving code.

## Data invariants

- Local logs establish usage facts. API daily totals are in-memory reference data, never extra priced local usage.
- Store individual effective events. Cross-task deduplication is turn-based and retains the earliest source task; a fork's inherited turns do not create duplicate rows. Response IDs match events within that ownership rule.
- Do not invent response/turn IDs or use ordinals as response IDs. Distinct responses with equal tokens remain distinct.
- Unknown account, model, rate, and amount remain unknown. Never fill historical account attribution from the current login.
- Input includes caches and output includes reasoning. Use Decimal for rates and checked integer nanoUSD for amounts; never accumulate money in Double.
- Missing tier evidence may use standard pricing with an explicit basis. Confirmed Fast with a missing rate stays unpriced. Derive Fast/long combinations per component only when required rates exist.
- Persist only ended main seven-day limit cycles. Current display snapshots may be cached in `api.json`; API daily buckets and forecast samples stay in memory; minimal cursor summaries may support recovery.
- Historical cycle aggregates belong in `weekly_limit_cycles` and update during synchronization. Cross-dimensional usage filters aggregate `usage`; do not precompute every filter combination.
- Read Codex source files without modifying them. Store statistical fields and source locations, not bodies, tool output, or credentials. Let Codex manage authentication.

## Pre-release simplicity

The app has not launched. Do not preserve old TokenTick preferences, internal Chinese identifiers, output formats, or schema versions through compatibility shims. Use English identifiers and localized display labels. Keep one current schema and rebuild development databases from logs when it changes.

This does not remove support for historical Codex source formats, source identity checks, or restart/cancellation recovery. Those are current ingestion requirements. Minimal parser/file-state JSON is appropriate for checkpoints that are not queried field-by-field; full evidence and price-source JSON is not.

Do not recreate redundant turn, individual-limit-observation, or statistics-rebuild tables. Transactional statistics rebuilds roll back on failure; resumable repricing retains its own necessary checkpoint.

## UI and language

- Maintain native SwiftUI structure, restrained surfaces, translucency, and both appearances. Keep AppKit bridging narrow and justified by window/system behavior.
- Use one main window, a separate Settings scene, and the menu-bar entry point. Keep window activation and keyboard behavior intact.
- Keep product copy concise. Explain implementation details only when they help a user interpret data or act.
- Distinguish loading, empty, error, and cancelled states. Do not replace unchanged background results or discard hover, selection, scrolling, filters, and open-detail snapshots.
- Avoid periodically updating nested views inside the menu-bar label; use stable cached template images. Preserve chart hover behavior when changing surrounding labels.
- English is the development/fallback language; Simplified Chinese follows native macOS app-language preferences. Do not add an in-app language selector. Use **Lifetime** for cumulative history.
- Localize app text in `Localizable.xcstrings` and Core errors through package resources/`Bundle.module`. Do not translate API keys or user-provided task/project names.

Codex disk-space analysis restores `storage.json` at startup and runs an independent metadata scan only on the first Storage page visit per launch or manual refresh. It uses a disposable snapshot cache, an Overview section below model usage, and a main-sidebar Storage page. Keep it out of Settings and preserve read-only access to Codex files without adding database tables or historical trends.

## Verification and delivery

Use the documented Xcode targets and `script/build_and_run.sh`; SwiftPM provides Core libraries/tests, not the CLI executable. The run script stops existing TokenTick processes. Prefer isolated databases for verification, and restore any temporary launch settings you introduce.

Run checks appropriate to the change. For data changes, test actual failure boundaries: duplicates, unknown fields, account switches, time boundaries, cancellation, interrupted commits, and cache/fact agreement. For UI changes, inspect native interactions and both languages/appearances where affected. A passing build does not prove runtime or live API correctness. Performance claims require comparable measured workloads.

Keep durable requirements and technical design up to date. Do not commit a growing collection of process notes, temporary plans, validation reports, private transcripts, or local audit databases. Report checks performed and remaining limits in the delivery summary.

Before a requested commit, review the repository, branch, and exact diff; stage only intended files. Follow Conventional Commits and check whether changeset configuration exists. Prefer `Co-authored-by: Codex <codex@openai.com>`. Push requested commits unless local-only work was requested. A commit request does not authorize tagging, publishing, or merging.

Packaging extracts the root README's `## Installation` section. Verify that extraction after documentation changes. Distribution uses ad-hoc signing and Sparkle's separate Ed25519 update signature; never print or commit signing keys. Publishing a version tag triggers the release workflow and requires release authorization.
