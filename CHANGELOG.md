# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.1] - 2026-11-17

### Fixed

- Closing a window while it is still connecting now stops that connection and its SSH tunnel, instead of leaving them open with no window.
- SSH tunnels no longer become an OpenSSH connection-sharing master when `~/.ssh/config` sets `ControlMaster auto`, so closing one window can't break another window's tunnel to the same host. A master you started yourself is still used.
- A connection handed to a new window (New Window with This Connection, Open in New Window) is dropped from memory after a minute if no window takes it, so its credentials don't stay in memory until the app quits.

## [1.3.0] - 2026-11-17

### Added

- **Multiple windows, easy to find.** Every window has its own connection.
  - **File → New Window with This Connection** (⇧⌘N), also the **New Window** toolbar button in a connected window, opens another window connected the same way. It reuses the credentials already in use, in memory only, so it also works for connections opened with `--connect` and for passwords that are not saved. SSH connections get their own tunnel.
  - **Open in New Window** in a saved connection's context menu.
  - A **New Window** toolbar button on the connection screen (same as **File → New CcinnMongo Window**, ⌘N).
  - Closing a window disconnects only that window. Windows that macOS reopens after a restart show the connection screen and never connect by themselves.
- `--duplicate-window` launch argument (with `--connect`) for automated checks.

### Changed

- `--snapshot` renders the frontmost window.

### Fixed

- Cancelling while a `--connect` launch connection is opening no longer leaves the window connected.

## [1.2.0] - 2026-11-16

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnMongo shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day, on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnMongo on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

### Changed

- Automated `--snapshot` launches no longer take focus from the active app.

## [1.1.0] - 2026-11-14

### Added

- **MCP server for AI clients.** `CcinnMongo.app/Contents/MacOS/CcinnMongo mcp [--profile <name|id>] [--read-only]` runs a headless Model Context Protocol server over stdio, so Claude Code, Claude Desktop, Codex and other MCP clients can use your saved connections on every server from MongoDB 2.6 to 8.x, including SSH tunnels.
- MCP tools: `list_connections`, `server_info`, `list_databases`, `list_collections`, `collection_schema`, `list_indexes`, `find`, `aggregate`, `count_documents` and `explain`; for connections with read & write access also `insert_one`, `update_many` and `delete_many`, bounded by `max_documents` and with dry runs.
- Per-connection **AI access via MCP** (Disabled / Read-only / Read & write, disabled by default) in the connection editor and in the new **Settings → MCP** pane, which also shows copy-ready setup for Claude Code, Codex and Claude Desktop.
- Read-only enforcement by CcinnMongo itself (no `$out`/`$merge`, `$changeStream`, server-side JavaScript or credential collections), result limits (200 documents by default, at most 1,000 and about 256 KB per call), per-call time limits (30 s by default, at most 120 s), cancellation, and an audit log in `mcp-audit.jsonl`.
- `--settings <general|ai|mcp>` and `--editor-section <name>` launch arguments for automated screenshots.

### Fixed

- Editing a saved connection no longer resets its last-connected time, so it stays in Recents.

## [1.0.0] - 2026-11-14

First public release.

### Added

- Pure-Swift MongoDB stack supporting MongoDB **2.6 through 8.x**: lossless BSON codec (including Decimal128), `OP_MSG` and legacy `OP_QUERY`/`OP_REPLY`/`OP_GET_MORE`/`OP_KILL_CURSORS`, and version-aware operations.
- Authentication with SCRAM-SHA-256, SCRAM-SHA-1, MONGODB-CR and PLAIN (LDAP), with automatic negotiation.
- `mongodb://` and `mongodb+srv://` connection strings, replica-set discovery, read preferences, TLS options and SSH tunnels through the system OpenSSH client.
- Connection manager with favourites, recents, colour tags, a URI ⇄ form editor, connection testing and Keychain-backed secrets.
- Documents: typed tree, JSON and table views, paging, counts, query history, insert/edit/clone/delete, bulk update/delete, import (JSON/NDJSON) and export (JSON/NDJSON/CSV).
- Shell-syntax query editor with highlighting, validation and completion.
- Aggregation workbench with per-stage previews, schema analysis, index management with usage statistics, and a visual explain plan (classic, SBE and legacy formats).
- Server overview, live performance charts and a command console.
- Optional AI assistant powered by locally installed Claude Code or Codex CLI: natural-language query and pipeline generation, plus interactive read-only Q&A over the data.

[Unreleased]: https://github.com/whiteCcinn/ccinnmongo/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/whiteCcinn/ccinnmongo/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/whiteCcinn/ccinnmongo/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnmongo/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnmongo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnmongo/releases/tag/v1.0.0
