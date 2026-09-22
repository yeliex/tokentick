# Product requirements

This document defines TokenTick's product scope and behavior for users and maintainers. The [README](../README.md) covers installation and CLI examples; [architecture and maintenance](technical-design.md) explains the implementation.

## Scope

TokenTick helps Codex users understand local token consumption, estimated API-equivalent costs, and subscription-limit usage. It targets macOS 26 or later on Apple Silicon, with a native SwiftUI app and an independent CLI sharing Swift Core and SQLite.

The current app has three main pages: Overview, Usage details, and Plan usage, plus a menu-bar panel and a separate Settings window. Codex disk-space analysis is agreed future work, described below; it is not a current feature.

The scope excludes other model providers, Intel support, a cross-platform CLI, a cloud synchronization service, and an independent background daemon. Amounts are estimates based on public model prices, not subscription charges.

## Usage records and attribution

- Retain each valid usage event with its available response ID, turn ID, source ordinal, timestamp, UTC date/hour/minute, model, token components, applied prices, and source location.
- Preserve real source identifiers. Missing historical IDs remain null; do not generate a response ID from a turn or ordinal.
- Across tasks containing the same turn, retain only the source task created earliest. A fork's new turns count normally. Discovering the original later changes ownership transactionally without adding duplicate consumption.
- Count old and new reports of the same consumption once. Equal token counts alone do not make two distinct responses duplicates.
- Include unknown-account usage in global totals. Account filters include only matching evidence; the current login does not fill historical account gaps.
- Keep unknown models in token totals and expose incomplete pricing. Missing values and zero are different.
- Use the latest task title and project mapping. Project renames or reassignment update historical grouping without changing tokens or timestamps. Projects with the same resolved name share a group.
- Resolve projects from Codex's saved projects and explicit task assignments. An arbitrary working-directory basename is not a project. Explicit projectless tasks use the `Chat` group; missing information alone is not proof of projectless status.

## Collection and privacy

Local activity, archived logs, reverted rollouts, forked histories, remote histories already saved locally, and compressed logs are collection inputs.

Each operation reads the process's current `CODEX_HOME`, defaulting to `~/.codex` if empty or unset, and fixes that root for the operation. There is no app directory picker or `--codex-home` option.

Collection is read-only against Codex files. Moving, compressing, reverting, or removing a source file does not refund previously recorded consumption. TokenTick stores statistical fields and required attribution, not conversation bodies, tool output, or credentials.

The scanner streams bounded data and commits batches. It must recover safely from append, partial lines, interruption, truncation, replacement, archive moves, and compression changes. A cursor advances only with its committed records. Rescans, restarts, and concurrent app/CLI activity must not duplicate usage or corrupt the database.

The app synchronizes while running using filesystem notifications, startup/wake checks, and periodic reconciliation. Synchronization can be cancelled and retried; quitting stops collection. An unavailable source must not discard successful work from other sources.

## App diagnostics

The macOS app reports crashes, sanitized operational errors, and foreground sessions to Sentry. Count active installations using the SDK-generated anonymous installation ID, including installations without errors; group session users by the installed release and build. This measures reporting installations, not unique people or all downloads. Clearing the SDK cache may reset the identity. Development and production environments remain separate; previews and tests do not initialize reporting. The CLI does not report telemetry.

Report operational failures across queries, synchronization, storage, caches, settings and updates with fixed stages/reasons, error types and numeric codes. Preserve actual HTTP/RPC status and aggregate invalid-data counts without usage records. Rate-limit identical handled errors and exclude expected cancellation, cache misses, empty source folders and normal updater outcomes. Include actionable error descriptions, RPC error messages, and relevant file locations after credential redaction, bounded to 2,048 characters. Include RPC method and elapsed time, and retain one representative error per scan reason. Do not attach Codex identity, conversation contents, usage records, credentials, arbitrary error userInfo, or full API response bodies. Automatic network and UI breadcrumbs, tracing, profiling, replay, and app-hang tracking are not required for this scope.

Handled errors include a bounded chain of underlying causes so wrapped update and network failures remain actionable. Source database open failures include the actual file location and access conditions without reading database contents for diagnostics.

## Costs and prices

Prices come from the OpenAI portion of models.dev, with a bundled JSON catalog for offline and historical coverage. A successful refresh is needed at most once per day; unchanged prices do not create another dated snapshot.

Prices are recorded by model, UTC date, and service tier. Each tier has base rates and, where supported, a long-context threshold and rates. Explicit combined tier/context prices take precedence. When those are absent, derive each component using that component's standard long/base ratio and retain the derivation basis. Unsupported context rules do not silently use base rates.

Use confirmed Fast evidence from rollouts or matching Codex trace records. If no tier evidence exists, price using the standard tier while preserving the unknown observation. A confirmed Fast request with no Fast price must not fall back to standard.

Input includes cached tokens; output includes reasoning. Avoid double charging either subset. Determine long-context pricing from an individual request's input, not cumulative turn input. Preserve missing rates and costs as null while exposing calculable components. Calculations use decimal arithmetic and integer nanoUSD, never floating-point accumulation.

Price or rule changes can reprice history and invalidate derived statistics. Repricing is resumable; rebuilding the statistics cache is transactional.

## Server reference usage

Server daily buckets provide dates and total tokens, not a reliable daily model or input/output breakdown. Keep account summaries and daily buckets in process memory.

The reference difference is the server total minus local coverage, including unknown-model records and remote logs already collected locally. Display a negative difference as zero additional tokens while preserving the raw difference. Do not add this reference to local usage, price it, or call it exact usage from other devices when account coverage and bucket timezone are uncertain.

Discard an observation if the account changes during the request. Failed or empty results must not leave a previous account's daily buckets visible.

## Subscription limits

### Current account

Current-limit cards belong to the confirmed Codex login. Cache the latest API display snapshot in `api.json`, scoped to the Codex root and authentication-file metadata. Restore matching cached cards at startup, retaining their original observation time, then refresh in the background. Do not cache authentication contents or raw API responses. Cached data does not confirm a live login session or seed forecasts. Run startup API requests and local log collection concurrently. Publish validated API results without waiting for log collection, database write locks, or pricing. Failure to obtain limits must not block local collection.

Fresh logs may advance API-confirmed windows within the same login session. Window changes, resets, or missing identity require API confirmation. Clear old snapshots and forecasts on login changes and reject late results from the previous session. A recent historical log cannot establish the currently signed-in account.

Show the main `codex` bucket prominently and other buckets as secondary cards. Windows with the same limit ID share a card, with separate percentages and periods. Use the API's plan name, credit balance, available reset count, and returned expiry details when present; do not infer missing balances, plan multipliers, or expiry dates. Reset credits are information, not an action to redeem them.

The default percentage text shows remaining allowance, configurable to used percentage. This preference changes only the text; the progress bar always fills from left to right with used percentage, and all markers use the same used-percentage coordinates. Weekly tick divisions use 4, 5, or 7 equal parts (default 5), plus 50% and 80% used markers. Five-hour windows omit those equal divisions. The time marker reflects elapsed natural time; the setting does not skip weekends or change the window duration.

The current-limits module shows a small upper-right loading indicator while requesting the API, without replacing cached cards. A failed refresh retains the last known snapshot; a confirmed missing account clears it. Cache files are disposable, atomically replaced on successful refresh, and stored beside the TokenTick database. Invalid or missing files fall back to live fetching.

Within the same login session, an expired observation may remain visible as the latest known snapshot while the app silently refreshes on window activation. Stale observations cannot support forecasts.

### Forecasts

Compare observed usage with elapsed natural time in the current window. Label usage above that pace **Ahead** and usage at or below it **Allowance**, showing the absolute percentage-point difference. This comparison uses the current time and does not require forecast samples.

Estimate exhaustion and remaining allowance at reset from recent percentage observations of the same account and window. After the first fresh, API-confirmed observation, use the current window’s used percentage divided by elapsed time at that observation as an initial average rate. Starting with the second observation, blend in the recent consumption rate on every update. Its weight grows with the observed time span, reaching full weight at ten minutes; there is no minimum sample-count gate. Do not infer allowance from tokens or money, or combine observations across resets. Forecasts are estimates and require fresh observations and valid boundaries. An initial estimate requires positive elapsed time; zero consumption does not predict exhaustion. Missing estimates do not need an explanatory placeholder in the main card; details can explain their state.

### Historical windows

Persist only completed seven-day windows of the main `codex` bucket, identified by a duration of 10,080 minutes, not by `primary` or `secondary` naming. Five-hour and additional-model windows are excluded from history.

A stable reset deadline provides the inferred start seven days earlier. A new window observed before the previous deadline establishes an early reset; use the first new-window observation as an approximate boundary when the exact event is unavailable. Do not distinguish a reset credit from another early reset without evidence. Idle zero-use deadline movement must not generate overlapping cycles.

Store the last observed percentage, not a claimed final billed percentage. Persist local record counts, tokens, complete costs, and known cost components for each ended cycle during synchronization. Attribute usage using the turn start, falling back to its occurrence time when unavailable. Update aggregates after new logs, boundary corrections, or repricing. Resume historical detection from minimal scan checkpoints without persisting full current snapshots or individual observations.

## App experience

### Overview

The six periods are Today, 7 days, 30 days, 90 days, 1 year, and Lifetime. Today starts at local calendar midnight; the other finite ranges roll back from now, with one year defined as 365 days. Lifetime includes all saved usage. All usage sections share the selected interval; the current-account limits remain independent.

Show total tokens and known estimated costs together with input, output, reasoning, cache-read, and cache-write components. Use a combined token-bar/cost-line trend, with distinct units and hover values. Group one year by Monday-based weeks, Lifetime by months, and the other periods by days. Include zero-use buckets in averages; missing costs must not become zero.

Three concentric rings break usage down by model, mutually exclusive mode (standard, Fast, long context, Fast plus long context), and recorded reasoning effort. They share the token/cost selector and period, and link hover states with their lists. Keep unknown categories last. Reasoning effort comes from the log's setting, not reasoning-token counts.

Recent tasks show only consumption within the selected interval and are ordered by the latest usage in that interval. Opening a task carries the exact interval into Usage details.

### Usage details

Keep daily/project/task grouping, dates, search, project, model, account when applicable, and sorting in a compact filter row. Project and model choices come from usage within the selected date scope. Custom dates use an apply/cancel popover; no duplicate date editor is needed.

Show tokens, costs, and event counts above a paginated table. Selecting a day or project updates the visible filters and shows contributing tasks. A task opens a request sheet; summary details open a statistics sheet. Closing a sheet preserves grouping, filters, and pagination. Open details use a stable snapshot; older asynchronous queries cannot replace newer results.

### Plan usage

Show ended cycles in a list with the selected cycle's details alongside it. Date presets are 30 days, 90 days, 1 year, and Lifetime, plus custom dates. Show account selection only when multiple known accounts exist, while global results retain unknown-account usage.

The detail card combines percentage, progress, local tokens, estimated costs, and event counts. Its heading shows the start and actual end boundary including time; early-reset cycles additionally show the scheduled deadline. Keep these extra times out of the list. The current window belongs in Overview.

### Menu bar and windows

Use one main window and a separate Settings scene, with native keyboard, selection, and accessibility behavior. Closing the last visible or minimized ordinary window hides the Dock icon but leaves the menu-bar process running; reopening restores it. Do not add multiple main windows, tabs, or global shortcuts.

The menu-bar label uses a template icon with the rounded main-limit percentage, preferring the weekly window. Missing or reset-expired limits fall back to the plain icon when the label updates. Tooltips and accessibility text include the period and full percentage.

The compact menu panel shares current main-limit data and shows Today/7/30/90-day usage plus a 30-day token/cost chart. Keep the chart's hover interaction, daily averages, and independent peaks. Its only page/action rows are Overview, Usage details, Plan usage, and Quit; ⌘, still opens Settings.

### Settings, language, and presentation

Settings has General, Data, and About sections for login items, limit display, synchronization and prices, update controls, CLI installation, and paths/database size. General includes a persistent theme preference: Follow System (default), Light, or Dark. Changes apply immediately to the main window, Settings, and menu-bar panel. General settings creates `/usr/local/bin/tokentick` as a symbolic link to the bundled CLI without administrator privileges. Existing files and other links are never overwritten; installation reports conflicts and permission failures. The linked CLI updates with the app. App usage follows system timezone changes and automatic synchronization is part of normal operation.

General includes an opt-in reset reminder switch and a method picker: Notification only (default), Confetti, Fireworks, or Random (chooses one of the two effects). All methods send normal system notifications, subject to macOS permission and delivery settings. Request notification permission when enabling reminders, show a System Settings action after denial, and refresh permission state on activation. A Test reminder action previews the selected delivery without changing usage or reset detection.

Reminders cover API-confirmed main five-hour and weekly resets while the app runs. Startup, account/plan changes, and newly appearing windows establish a baseline without notification. Do not replay missed reminders or infer resets from cached data, logs, or countdown expiry alone. Coalesce windows reset in one observation into one notification and one effect.

Celebrations follow CodexBar's presentation behavior: transparent full-screen overlays on the system primary display only, no focus or mouse interception, no overlapping celebrations, and automatic dismissal after three seconds. Confetti bursts from the center of the primary display, then slows, tumbles, and falls. Fireworks bloom directly at their burst positions without launch trails. Respect Reduce Motion. System notification delivery always remains under macOS control.

Use native SwiftUI surfaces, restrained colors, rounded geometry, translucent backgrounds, and consistent light/dark appearances. Keep product copy short and user-oriented; put technical caveats in relevant details or help. Preserve hover, selection, scrolling, and drill-down state when background results have not changed. Distinguish initial loading, empty results, errors, and cancellation.

English is the development and fallback language; Simplified Chinese is selected through macOS's native app-language mechanism. There is no in-app language selector. Display strings are localized separately from English internal identifiers. Use **Lifetime** for cumulative history.

## Codex disk-space analysis

See the [README](../README.md) for a feature overview and Storage screenshot.

Storage measures current Codex local data independently of token usage. The About section continues to show TokenTick database file sizes.

- Restore the latest matching `storage.json` snapshot at startup without scanning. Scan the current `CODEX_HOME` in an independent background task on the first entry into the Storage page per app launch or when requesting Refresh. Keep scan state in memory; do not create a database table or historical trend.
- Storage detail shows projectless tasks (their immediate directories), worktrees (their immediate directories, without a redundant `worktrees` row) and conversation records (`sessions` and `archived_sessions`, without deeper expansion). Logs, plugins and skills, generated content (`generated_images` plus `visualizations`) appear only in the summary. Other data is the remaining Codex home usage and always appears last. Projectless task storage reads `desktop.projectlessWorkspaceRoot` from `config.toml`, falling back to `~/Documents/Codex`.
- Add a storage summary below model usage in Overview and a dedicated Storage page in the main sidebar, outside Settings. Both share one result and scan state; only the first entry into Storage triggers an automatic scan; subsequent navigation, Overview, and usage-period changes do not. Show last-scan time in the Storage page toolbar at the upper right, followed by a Refresh button that becomes a disabled spinner while scanning. The Overview module uses a small upper-right refresh indicator.
- Classify conversation records, worktrees (including dependencies/builds), logs, plugins/skills, generated content, projectless tasks, and other data. Categories are mutually exclusive and cover unknown files as well. Existing backups are ordinary files, not a backup-management feature.
- Use the system `du` command for approximate disk usage. Do not maintain a separate per-file accounting algorithm or logical-size metric. Count compressed files as stored, do not follow symlink targets, and leave hard-link accounting to the system.
- Exclude Codex.app, external projects other than the configured projectless task directory, caches outside the root, and other devices. The Storage page only covers Codex; it does not query or display the TokenTick database.
- Scan metadata only. Do not read conversation bodies or modify, compress, or delete source files. APFS shared blocks mean measured size is not guaranteed reclaimable space.
- Provide manual refresh, category and directory drill-down, copyable paths, and Finder reveal. Allow one scan at a time. Retain prior results until the first live totals arrive, then update category and directory sizes during the scan. Mark the display as scanning; intermediate totals are lower bounds. Save only the completed snapshot. Unavailable sizes display as zero without scan error messages; restore the previous completed results if a scan fails or is canceled, and display observation time.
- Validate large directories, symlinks, hard links, permission failures, disappearing files, archive/compression changes, cancellation, and restart. The UI and token synchronization must remain responsive.

## Quality requirements

App and CLI results must agree for the same filters and timezone. Validate deduplication, exact cost math, null semantics, account isolation, reset boundaries, crash recovery, and agreement between facts and caches. Changes to UI behavior require native interaction checks, including window sizing, sheets, keyboard actions, loading/error states, and both appearances.

Performance claims require measured workloads, with first, unchanged, and incremental scan results, memory use, and query latency where relevant. A successful build is not evidence of UI correctness or live API behavior. Record unresolved verification limits in the delivery summary rather than retaining a growing archive of implementation reports in product documentation.

## Product website

The `pages/` project is a single-page English product website built with Next.js, Tailwind CSS, and shadcn/ui. Lead with the menu-bar screenshot, then alternate app screenshots and feature copy for limits/reset times, token/cost analysis, task/project details, and storage. FAQ addresses privacy, resource use, permissions, and background operation. Downloads, installation instructions, releases, and support link to GitHub rather than separate website documentation. Use the app's light warm-white/amber and dark graphite/mint brand colors, and preserve sample-data labels and estimated-cost boundaries.

The website uses Vercel Web Analytics for visitor and page-view statistics. This is separate from the native app diagnostics described above.
