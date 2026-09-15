# TokenTick

A native macOS app and CLI for tracking **Codex usage limits, token usage, and estimated API costs**. A Codex-focused alternative to [CodexBar](https://github.com/steipete/CodexBar) and [ccusage](https://ccusage.com/guide/).

- Explore usage by day, task, project, and model.
- Monitor current limits and review completed weekly windows.
- Check recent activity from the menu bar.
- Export detailed usage as JSON with the CLI.
- Keep repeated scans and resource use down with incremental log collection, batched SQLite writes, and cached aggregates.
- Account for Fast and long-context pricing, avoid double-counting cached input and reasoning output, and deduplicate inherited usage in forked tasks.

Requires **macOS 26+ and Apple Silicon**. Supports English and Simplified Chinese through macOS language settings. Costs are USD estimates based on public API prices, not subscription charges.

<img src="assets/screenshots/dashboard.png" alt="Dashboard with sample data" width="1120">

<img src="assets/screenshots/menu.png" alt="Menu bar panel with sample data" width="344">

## Installation

Download an archive from [GitHub Releases](https://github.com/yeliex/tokentick/releases). Verify it with the matching checksum file:

```sh
shasum -a 256 -c <archive-name>.zip.sha256
```

### App

Extract the archive, move `TokenTick.app` to Applications, and open it. If macOS blocks the ad-hoc signed app, allow it in System Settings → Privacy & Security after confirming the download's source.

Update through **Check for Updates…** in the app menu or Settings → About.

### CLI

The full distribution includes `bin/tokentick` and its required resource bundle. From the extracted directory:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/tokentick "$HOME/.local/bin/tokentick"
ditto bin/TokenTick_TokenTickCore.bundle "$HOME/.local/bin/TokenTick_TokenTickCore.bundle"
```

Add `$HOME/.local/bin` to your PATH. The CLI runs independently of the app and is updated manually.

## CLI

```sh
tokentick sync --scope all
tokentick usage --group day --json
tokentick records --limit 100
tokentick current-limits
```

Run `tokentick --help` for filtering, pricing, and export options.

## Documentation

- [Product requirements](docs/requirements.md)
- [Architecture and maintenance](docs/technical-design.md)
- [Contributor and agent guidance](AGENTS.md)
- [Icon assets](assets/icons/README.md)
