# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/whiteCcinn/ccinnmongo/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/whiteCcinn/ccinnmongo/releases/tag/v1.0.0
