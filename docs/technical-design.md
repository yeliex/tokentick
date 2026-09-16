# Architecture and maintenance

This guide describes TokenTick's current data model, algorithms, and maintenance workflow. See [product requirements](requirements.md) for behavior and planned scope, the [README](../README.md) for user instructions, and [AGENTS.md](../AGENTS.md) for contribution rules.

## Project map

| Path | Responsibility |
| --- | --- |
| `TokenTick.xcodeproj` | Native macOS app and independent CLI targets, both arm64/macOS 26+ |
| `Package.swift` | Shared libraries, dependencies, and Core tests |
| `TokenTick/TokenTickApp.swift` | App lifecycle, main window, menu bar, and Settings commands |
| `TokenTick/cli.swift` | CLI parsing, commands, text output, and JSON encoding |
| `TokenTick/Core/Collection` | Log discovery, streaming, parsing, source identity, project metadata, and Codex API |
| `TokenTick/Core/Synchronization` | Shared sync orchestration and trigger scheduling |
| `TokenTick/Core/Pricing` | Bundled catalog, models.dev parsing, and exact cost calculations |
| `TokenTick/Core/Storage` | SQLite schema, transactions, ownership, queries, pricing, and caches |
| `TokenTick/UI` | SwiftUI views, query state, formatting, and app synchronization lifecycle |
| `TokenTick/Updates` | Sparkle updater integration |
| `Tests/TokenTickCoreTests` | Core behavior and regression coverage |
| `script` | Build/run, distribution packaging, and appcast generation |

The code uses Swift 6, SQLite WAL through GRDB, and in-process libzstd decompression. Core does not depend on SwiftUI or shell out to decompress logs. Dependency versions are defined in `Package.swift` and its resolved files; use SwiftPM tooling to change them.

Collection submits parsed data through `UsageStore`; destination SQL belongs in Storage. Ownership checks, deduplication, evidence updates, and cursor commits share the caller's transaction. Splitting files must not change transaction, lock, or batch boundaries.

## Runtime and source boundaries

The default database is `~/Library/Application Support/TokenTick/usage.sqlite`. CLI `--database` and app `TOKENTICK_DATABASE` can select an isolated database.

Each operation reads `CODEX_HOME` through the current process environment, with `~/.codex` as the empty/unset fallback. The scanner holds one root for the operation. Directory watcher rebinding follows environment changes. No app setting or CLI option duplicates this source selection.

Source files are read-only. The Codex app-server owns authentication; TokenTick does not copy credentials. Login-session tracking inspects `auth.json` identity, modification time, and size without reading its contents. API identity still comes from a confirmed account response. Authentication changes outside that file are detected through subsequent API checks rather than guaranteed immediate notification.

## Data types

| Value | Representation |
| --- | --- |
| Tokens | Nonnegative `Int64` / SQLite `INTEGER` |
| Timestamps | UTC Unix seconds, with fractional seconds where supported |
| Price dates and `usage_date` | UTC `YYYY-MM-DD` |
| Statistics timezone | IANA timezone identifier |
| Prices | Decimal strings in USD per million tokens |
| Amounts | Integer nanoUSD; `1 USD = 10^9 nanoUSD` |
| Unknown identity, time components, rates, or amounts | `NULL`, not zero or a fabricated value |

Input includes cache-read/write tokens and output includes reasoning tokens. Preserve the source total rather than inventing missing components or adding subsets twice. Floating-point conversion is allowed for drawing charts, not cost accumulation.

## Database

[StoreSchema.swift](../TokenTick/Core/Storage/StoreSchema.swift) is authoritative for columns, nullability, indexes, and triggers. The tables below explain why the fields exist without duplicating the DDL.

### `threads`

`thread_id` is the primary key; `title` and `project_name` hold the latest mapping. `Chat` represents explicit projectless tasks. There is no separate project history table or project column copied into every usage row. Joins apply new mappings to history; project changes invalidate statistics.

### `scan_files`

`rollout_id` is the stable logical source key. `thread_id`, `file_name`, and `current_path` identify the task and latest location. `scanned_line` and `scanned_offset` record committed complete lines and decompressed byte position; `last_scanned_at` records the last scan.

`file_state_json` tracks physical file state and validation information. `parser_state_json` retains the parser version, session/model/tier context, cumulative baselines, duplicate-report matching state, and minimal last-window summaries needed to resume historical limit detection.

These JSON fields are checkpoints, not an evidence archive. Keep only state needed to resume correctly. Cursors and their usage batch commit together. Parser format changes invalidate the checkpoint and trigger a deduplicated rescan.

### `prices`

The primary key is `(model, date, tier)`. Base component columns are `input_price`, `output_price`, `cache_read_price`, and `cache_write_price`; matching `long_*` columns and `long_context_threshold` describe long-context pricing.

`context_rule` is `uniform`, `requestInputGreaterThan`, or `unsupported`. `source_url`, `is_bundled`, `combination_rule`, and `combination_source` preserve the source and direct/derived combination basis. Raw `source_json`, cost payloads, and experimental payloads are not stored.

Normalize `default`/`standard` to `standard` and `priority`/`fast` to `fast`; preserve other explicit tier names. Fast is a separate row with its own long-context prices, not a set of `fast_*` columns.

### `usage`

Each row is one effective usage event, not an aggregate turn and not necessarily a network request.

| Field group | Purpose |
| --- | --- |
| `id`, `account_id`, `thread_id`, `turn_id`, `response_id`, `turn_key` | Record identity, observed ownership, and internal turn grouping |
| `occurred_at`, `usage_date`, `hour`, `minute` | Source time and UTC components; do not invent precision |
| `turn_started_at`, `source_created_at` | Cycle attribution and earliest-source fork ownership |
| `model`, `tier`, `reasoning_effort`, `is_long_context` | Observed settings and context classification |
| `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens`, `total_tokens` | Original usage components |
| `input_price`, `output_price`, `cache_read_price`, `cache_write_price` | Rates actually applied |
| `input_amount`, `output_amount`, `cache_read_amount`, `cache_write_amount`, `amount` | Component costs and complete total |
| `pricing_tier`, `pricing_source`, `price_date` | Applied pricing selection, separate from observed tier |
| `source`, `rollout_id`, `source_line`, `source_ordinal` | Structured source evidence and location |
| `legacy_total`, `legacy_input`, `legacy_output`, `legacy_cache_read`, `legacy_cache_write`, `legacy_reasoning` | Cumulative vectors for matching older Codex reports |

Do not persist report bodies, alternate reports, or `evidence_json`. The schema's source constraint permits `local` and `api`, but current daily API reference buckets are not inserted into this table.

Indexes cover occurrence time, thread/account/model time, UTC day/hour/minute, source position, turn key, and legacy matching. A partial unique index on `(turn_key, response_id)` protects identified responses; semantic deduplication still happens before insertion.

### `weekly_limit_cycles`

Store only ended main seven-day cycles. Identity and boundaries use `id`, `account_id`, `limit_id`, `started_at`, `scheduled_reset_at`, `ended_at`, and `reset_kind` (`natural` or `early`). `last_observed_at`, `last_used_percent`, `source_file`, and `source_line` retain the final known evidence.

`total_tokens`, `request_count`, `amount`, and `known_amount` are computed during synchronization. The history page reads these values directly; it does not aggregate all usage on every selection. New facts, changed boundaries, or repricing invalidate the cycle aggregates. No separate current-window or individual-observation table is needed.

### `statistics` and `app_metadata`

Statistics are unique by `(account_key, date, timezone, dimension, dimension_value)` and contain token/cost components, known/complete amounts, unpriced and unattributed counts, and record counts. Dimensions are `all`, `thread`, `project`, and `model`. Month/year queries combine days; cross-dimension and exact rolling filters query facts directly.

`app_metadata` tracks fact/cache revisions, dirty dates, timezone, price status, Fast evidence, and required maintenance checkpoints. UTC dirty dates invalidate adjacent local days as needed for timezone offsets. Project changes invalidate the full grouping cache. `weekly_cycles_revision` avoids recomputing unchanged cycle totals.

Do not add tables for every query combination, a `turn_usage` duplicate, or a statistics-rebuild staging area. Publish full cache rebuilds in one transaction; interruption rolls back. Repricing separately uses bounded resumable batches.

## Collection, deduplication, and mappings

### File identity and streaming

Recognize both `rollout-<time>-<thread_id>.jsonl` and `rollout-<time>-<thread_id>_<rollout_id>.jsonl`. A revert may create a new rollout for the same task. Archive paths, inodes, and modification times are physical state, not permanent usage identities. If a legacy filename cannot yield a verified UUID, use its normalized source identity without guessing an arbitrary UUID fragment.

Plain JSONL is read incrementally; a partial trailing line waits for the next scan. Zstandard files are streamed and skipped after a complete unchanged scan. Their decompressed offsets cannot be used as compressed byte seek positions. Interruption, representation changes, replacement, or truncation cause reconciliation and deduplicated rescanning.

When plain and compressed siblings coexist in one directory, prefer the plain representation, as Codex does. Do not decompress the sibling for a full comparison. Conflicting candidates in different locations require identity/content checks rather than arbitrary selection. Source disappearance or a revert does not remove previously observed consumption.

### Ownership and matching

1. Resolve turn ownership using `turn_key` and source creation time. Keep the earliest source task and exclude inherited fork copies. If the original arrives later, replace ownership and records transactionally. Missing turn IDs remain task-local rather than enabling speculative cross-task matching.
2. Match within the turn by real response ID or the full legacy cumulative vector, not just total tokens. Old/new dual reports count once; distinct responses with identical counts remain distinct.
3. Validate matched token components, known models, and observed tiers. A conflict rolls back without advancing the cursor. Prefer the identified response as the source position and enrich structured metadata without retaining report copies.

### Model, tier, and project evidence

Bind `thread_settings_applied` settings at the next task/turn start. A persistent setting change cannot rewrite an active or historical turn. Keep explicit-null and missing-field semantics distinct. Ambiguous compaction model evidence stays unknown until the context establishes it.

If tier evidence is missing, read matching top-level `response.create.service_tier` or actual TurnInput/UserInput evidence from Codex `logs_*.sqlite`. Match task and turn, not nearby timestamps or nested body fields. A settings submission ID is not a turn ID. Incremental trace cursors track database/WAL changes; SHM-only changes must not trigger a self-sustaining scan loop. Late evidence reprices affected usage.

Task mappings read the newest Codex state database and desktop project catalog. Explicit projectless IDs resolve to `Chat`; explicit project assignments precede historical projectless output-directory hints. Otherwise match saved project roots, preferring the most specific unambiguous root. Do not infer projects from arbitrary cwd basenames. Preserve remote Windows/UNC paths as remote paths rather than resolving them on the local filesystem.

## Pricing

The parser reads `openai.models` from models.dev's `api.json`. Standard `cost` components provide base rates. `cost.tiers[]` defines context thresholds, while experimental modes with explicit `cost` and `provider.body.service_tier` define independent service-tier rows. A context tier is not a service tier.

A row supports one long-context threshold. Multiple effective thresholds or ambiguous rules are unsupported. A legacy field name such as `context_over_200k` is not sufficient evidence to hard-code a threshold.

Prefer explicit combined mode/context rates. Otherwise derive each component independently:

```text
mode_long = mode_base × standard_long / standard_base
```

A missing required rate or zero denominator leaves that component unknown. Never assume Fast is always twice the standard price. Retain the derivation basis and mark it as an estimate.

Refresh successfully at most once per UTC day. Compare rates and rules, not display descriptions, before saving a new snapshot. A same-day correction replaces that day's row; no intraday version is modeled. Failures preserve existing prices.

Select the latest snapshot not later than the usage's UTC date, or the earliest snapshot for older usage. If no database snapshot exists for that model/tier, consult the bundled catalog. The first observed price date is not claimed as its true historical effective date. Unknown tier with no trace evidence uses standard pricing; confirmed Fast never falls back to standard.

```text
ordinary_input = input_tokens − cache_read_tokens − cache_write_tokens
component_nanoUSD = bankers_round(tokens × USD_per_million × 1000)
complete_amount = sum(the four rounded components), only when all are known
```

Use `Decimal` and checked `Int64` operations. Reasoning is already included in output. Long-context rates apply to the entire request when its input is strictly greater than the threshold, not only the excess or a turn's cumulative input. Invalid totals or cache counts cannot be priced as normal usage. Zero components cost zero; unknown/nonzero unpriced components remain null while calculable components remain available.

New prices, bundled data, or pricing rules mark history for repricing. `sync-prices` alone only fetches prices; `reprice` or shared synchronization updates costs and caches.

## API and limits

### Daily reference buckets

Use a short-lived Codex app-server stdio session. Bracket `account/usage/read` with account-bearing `account/rateLimits/read` responses and discard buckets when account identity changes. Account summaries and daily token buckets stay in memory.

Reference matching uses UTC dates because the upstream bucket timezone is not established. Local coverage includes the matching account plus unknown-account records, separately disclosed, and already-collected remote and unknown-model usage.

```text
raw_difference = api_tokens − local_coverage
additional_reference_tokens = max(0, raw_difference)
```

Neither value is priced or inserted into usage/statistics. A new failure or empty response clears old buckets; stale results cannot overwrite a newer account or failure.

### Historical cycles

Accept only the main `codex` bucket with a duration of 10,080 minutes. Exclude inherited/fork replay, expired observations, and implausible future boundaries. Merge reset timestamps within 60 seconds of a fixed anchor, not an indefinitely drifting chain of adjacent timestamps.

Order windows by first observation even when source files arrive out of order. A new window after the previous observation but before its planned deadline ends the old cycle early; otherwise the scheduled deadline ends it naturally. Persist completed windows with observed positive usage. Zero-use idle deadline movement must not create repeated cycles.

Minimal last-window summaries reside in parser checkpoints and commit with usage and ended cycles. Restore those before processing new files. These recovery summaries do not establish a current login or replace a live API snapshot.

Cycle usage is grouped by the earliest known start of each turn, falling back to occurrence time, within the cycle's half-open interval and matching account scope. This is an attribution rule, not per-response splitting at a reset boundary.

### Live account and forecasts

`CurrentLimitSession` uses a generation to reject results started before a login-environment change, even if the user switches back to the same account. Live snapshots remain in memory; a sanitized display snapshot is also atomically saved in `api.json` by `LocalDisplayCache`. Startup restores it only when the Codex root and auth-file metadata still match. Restoration preserves observation time and neither enables log ownership inference nor seeds forecasts. API transport failures retain the displayed snapshot; confirmed missing identity clears it and removes the cache. Preserve same-session stale cards while silently refreshing on main-window activation after 15 minutes; do not reuse stale predictions.

Logs can update only API-confirmed windows with matching duration/reset (60-second tolerance), increasing observation time, and nondecreasing percentage. They must be at most five minutes old and from the current session, excluding inherited replay. Unknown/new boundaries require API confirmation. Retained additional windows are not new forecast observations.

`LimitForecastHistory` groups by account and window identity, retaining at most six hours and 360 samples per series. Reject future/nonincreasing timestamps. A gap over 15 minutes, a decrease in percentage, or a changed duration/reset restarts sampling. Forecasts need at least three points spanning ten minutes, with the latest point no older than 15 minutes.

```text
rate = (last_percent − first_percent) / elapsed_seconds
exhausts_at = last_time + (100 − last_percent) / rate
remaining_at_reset = max(0, 100 − last_percent − rate × (reset_time − last_time))
forecast_progress_difference = last_percent − 100 × (last_time − inferred_start) / duration
display_progress_difference = window.used_percent − 100 × (now − inferred_start) / duration
```

Zero rate does not predict exhaustion; 100% is exhausted. Invalid/reset-expired windows do not predict. The forecast retains an observation-time comparison. The UI independently uses `CurrentLimitWindow.expectedUsedPercent(now:)` for both the green time marker and the **Ahead** (positive) / **Allowance** (nonpositive) label, without requiring forecast samples. Neither tokens nor costs participate in these formulas.

## Queries and synchronization

CLI date bounds are inclusive local calendar dates converted to half-open UTC intervals. Overview Today is `[local midnight, now)`; 7/30/90-day and one-year ranges are `[now − days × 86400, now)`, with 365 days per year. Calendar midnight respects DST. Records without precise timestamps are excluded from exact rolling ranges but retained in Lifetime.

Use the same range for summaries, charts, groups, and drill-down. Overview reads its sections in one database snapshot. Trend grouping is daily, Monday-based weekly for one year, or monthly for Lifetime. Recent tasks are selected by latest consumption inside the selected range, then aggregated within that same range.

Apply intersections, literal search, stable sorting, and pagination in SQL. Count groups after aggregation with the same snapshot/filters as the page. Never sum a limited page to produce a global total. Filter choices depend on date/timezone/account scope but ignore selected project/model/search to avoid locking users out of alternatives.

`UsageSynchronizer` fetches API limits and scans logs concurrently. Validated API limits are published before waiting for the database write lock; only synchronization status and completed weekly-cycle maintenance use the existing write coordination. After both sources finish, synchronization refreshes prices, reprices if necessary, and refreshes statistics according to scope. `remote` selects API and prices. Source errors remain independent; cancellation propagates to background work.

| Trigger | Schedule |
| --- | --- |
| Filesystem changes | Coalesce for 2 seconds, with at least 10 seconds between local scans |
| Reconciliation | Every 30 minutes with a watcher, every minute without one |
| API refresh | Every 5 minutes without fresh main-limit logs |
| Accepted main-limit logs | May defer API until 5 minutes after the observation, at most 30 minutes after the previous API start |
| Successful price refresh | Once per UTC day |
| Cancellation | At least 60 seconds of quiet time |
| Wake | Rebind watchers and reconcile once rather than replaying missed timers |

Only one synchronization runs at a time; additional work is coalesced. Current-schema WAL readers query committed facts without waiting for a complete scan. Cache rebuilds and schema recreation retain cross-process write coordination.

## UI and localization

General settings stores `appTheme` in UserDefaults through `@AppStorage`. `AppTheme` applies the selected appearance through `NSApp.appearance` at launch and when the picker changes; nil restores system appearance across windows and the menu-bar panel. Debug-only `TOKENTICK_APPEARANCE` overrides remain process-local.

Window-owned detail state preserves filters, grouping, pagination, and selected cycles across navigation. Request/statistics sheets hold their opening snapshot. Cancel old asynchronous work and check generation before assigning results. Unchanged background results must not replace content or clear hover/scroll state.

The menu-bar label uses cached template images, not a nested periodic `TimelineView`; repeated label invalidation can cause host layout churn. The menu chart maps tokens and costs independently for rendering, but tooltips retain original units. Missing amounts break the cost line. Menu averages divide by actual elapsed days; overview averages use the covered chart buckets, including empty buckets.

Use English internal identifiers and localize display titles separately. App strings live in `TokenTick/Resources/Localizable.xcstrings`; Core strings live in `TokenTick/Core/Resources` and load through `Bundle.module`. English is the fallback, Simplified Chinese follows macOS preferences, and cumulative history is labeled Lifetime. Chinese translations and multilingual test fixtures are intentional data.

TokenTick database/WAL/SHM sizes remain in About only, read without checkpointing. The Storage page does not query or display them.

`Core/DiskSpace/CodexStorageScanner.swift` runs `/usr/bin/du -k -P -d 1` over the root's immediate entries, including hidden entries. Arguments are passed directly to `Process`, not through a shell. System KiB totals are converted to bytes for display. This provides an approximate snapshot without reading file contents, decompressing records, following symbolic links, or maintaining a separate hard-link accounting algorithm. Only root-entry totals and one level of subdirectory totals are retained; individual descendant files are located through Finder. The root directory's own metadata is excluded.

Storage scanning includes the configured projectless directory in the system scan; an absent directory contributes zero. If it is nested inside Codex home, its bytes are deducted from its containing category to prevent double counting. Generated images and visualizations share one category. Worktree and projectless child directories are retained for drill-down; conversations show their two root directories. Remaining root entries form Other data, ordered last.

Root names `sessions` and `archived_sessions` map to conversations; `worktrees` to worktrees; `log`, `logs`, and `logs_*.sqlite` sidecars to logs; `plugins`, `skills`, and `skills.disabled` to plugins/skills; `generated_images` and `visualizations` to generated content. The configured projectless directory has its own category. Everything else, including hidden files and backups, maps to other data. Categories and entries sort by allocated bytes descending, with stable name tie-breakers; Other data always sorts last. A nonzero process exit or diagnostic output marks the snapshot as incomplete; available totals remain visible. Only the first 20 diagnostic lines are retained. Missing or unreadable roots contribute zero. Scan diagnostics are not displayed; available system totals remain visible and unavailable sizes display as zero. Cancellation terminates the child process and discards its incomplete output.

`CodexStorageModel` owns a utility-priority detached scan, cancellation propagation, the latest snapshot, and page expansion/scroll state. Application startup only restores the cached snapshot; it does not scan. The first entry into the Storage page per app launch, or requesting Refresh, starts a scan independently of the database and usage synchronization. One scan runs at a time, and the previous snapshot remains visible until completion. Canceled scans never publish partial success. The latest snapshot is atomically saved to `storage.json` beside the TokenTick database. Startup restores it when the Codex and configured projectless roots match, then waits for entry into the Storage page before scanning; UI state stays in memory. Older storage snapshots without newly added categories or a projectless root remain displayable until the background scan replaces them; missing categories are not filled with zero estimates. Missing or malformed cache files are ignored and cache write failures do not block live results. Overview displays the same snapshot below model usage (also available with no usage records); the main-sidebar Storage page exposes directory drill-down, copyable paths, and Finder reveal. Last-scan time and Refresh appear at the top right; the refresh button becomes a spinner during scanning.

## Development

Use Xcode with a macOS 26 or newer SDK. App and CLI are Xcode targets, not SwiftPM executable products.

```sh
# Build, stop any existing TokenTick process, launch, and verify process startup.
./script/build_and_run.sh --verify

# Build the CLI without launching the app.
xcodebuild -project TokenTick.xcodeproj -scheme tokentick \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build
.build/DerivedData/Build/Products/Debug/tokentick --help

# Test shared logic, or select a relevant suite.
swift test
swift test --filter UsagePricingTests
```

For an app build without launching or stopping processes, use the same `xcodebuild` command with `-scheme TokenTick`. The run script also supports `--debug`, `--logs`, `--telemetry`, and `--preview-limits`. Build products are in `.build/DerivedData` and logs in `.build/logs`.

Use isolated databases for validation:

```sh
.build/DerivedData/Build/Products/Debug/tokentick sync \
  --database .build/audit/usage.sqlite --scope local
```

For the app, pass `TOKENTICK_DATABASE` in its launch environment and use `TOKENTICK_AUTOSYNC=0` to disable startup autosync during inspection. Debug builds additionally support `TOKENTICK_APPEARANCE=light|dark` for process-local appearance checks; Release does not. Do not assume a shell export is inherited by an app launched through LaunchServices.

### Schema policy

TokenTick is pre-release. Maintain one current schema definition, with GRDB configured to erase a changed development schema and rescan original logs. Do not add compatibility migrations, old preference aliases, or old report-format defaults. Checkpoint version checks still protect interrupted scans and must not be confused with a product migration chain.

Use isolated databases for rebuild verification. Source logs remain read-only.

### Verification

Choose tests based on changed behavior: scanner/identity tests for ingestion, pricing tests for money, current-session/forecast tests for limits, and query/statistics tests for aggregation. Compile both targets when shared contracts or executable text changes. Exercise relevant native UI flows after UI changes, including English/Chinese display when identifiers change.

For documentation or script changes, check relative links, shell syntax, and distribution README extraction. Keep measured evidence and full logs under ignored `.build` paths when needed; public docs describe durable contracts, not past test counts or a transcript of implementation steps.

## Packaging and release

```sh
# Local ad-hoc distribution; does not install or publish.
./script/package_release.sh

# Explicit marketing version and increasing build number.
./script/package_release.sh 0.1.1 3

# Generate an appcast from the resulting App-only archive.
# The output directory must not already exist.
./script/generate_appcast.sh <App-update.zip> <release-notes.md> .build/appcast
```

The app target depends on the distinctly named `TokenTickCLI` target to avoid build-directory collisions on case-insensitive filesystems. It embeds its signed executable at `Contents/Helpers/tokentick`. An adjacent resource-bundle symlink lets the embedded CLI use the app’s shared Core resources; standalone distribution still requires its adjacent Core resource bundle. Settings creates `/usr/local/bin` if needed, installs an absolute symbolic link at `/usr/local/bin/tokentick`, and refuses to replace existing filesystem entries. Moving the app after installation requires removing the old link and installing it again.

Packaging builds arm64 Release app/CLI, signs and verifies them, and generates a full distribution plus `TokenTick-<version>.zip` containing only the app, with SHA-256 files. The full distribution includes the CLI's Core resource bundle, dependency licenses, signature details, and `BUILD.txt` recording revision, dirty state, toolchain, and architecture.

The packaging script extracts **`## Installation`** from the root README through the next level-two heading. Keep that section self-contained, preserve the extraction contract, and update the script if the heading changes.

Sparkle handles app updates using the feed configured in `TokenTick/Resources/Info.plist`, with hourly checks enabled by default. The app-linked CLI updates with Sparkle; independently copied CLI installations are updated manually. A feed URL in source is not proof that a release has been published.

Pushing a `vMAJOR.MINOR.PATCH` tag triggers `.github/workflows/release.yml` on `macos-26`, creates notes and a signed appcast, and publishes the latest GitHub Release. The marketing version comes from the tag; `CFBundleVersion` comes from `GITHUB_RUN_NUMBER`. Keep build numbers increasing when changing the workflow.

Release checkout includes full history and tags. `script/generate_release_notes.sh` lists commit subjects and links since the preceding reachable version tag (all history for the first release), followed by a full changelog link. GitHub Release and Sparkle use the same generated Markdown, including commits made without pull requests.

Actions uses `SPARKLE_PRIVATE_KEY`, matching `SUPublicEDKey` in Info.plist. The appcast script receives CI signing material through `TOKENTICK_SPARKLE_PRIVATE_KEY` and passes it over standard input; local signing uses the `tokentick` keychain account. Do not print, commit, or routinely regenerate the private key.

macOS code signing and Sparkle Ed25519 signatures serve different purposes. Distribution is ad-hoc signed without Apple notarization or a paid Developer Program account. Sign Sparkle components inside-out; the app's library-validation entitlement permits the dynamic framework without a Team ID. Creating a local package does not authorize tagging or publishing a release.
