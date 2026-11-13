# Contributing to CcinnMongo

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against real MongoDB servers.

```bash
git clone https://github.com/whiteCcinn/ccinnmongo.git
cd ccinnmongo
swift build
swift test
scripts/build-app.sh --open
```

### Integration tests

```bash
eval "$(scripts/it-up.sh)"            # MongoDB 2.6, 3.0, 3.2, 3.4, 3.6, 4.0 and 8.0 with auth
swift test --filter IntegrationTests
scripts/it-down.sh
```

`scripts/seed-demo.js` loads a small demo dataset (`shop.orders`, `shop.customers`, `shop.products`) that is handy for manual testing.

### Running the app against a server directly

```bash
dist/CcinnMongo.app/Contents/MacOS/CcinnMongo \
  --connect "mongodb://user:pass@127.0.0.1:27017/?authSource=admin" \
  --namespace shop.orders --section aggregations
```

## Project layout

| Module | Responsibility |
|---|---|
| `BSON` | BSON values and codec, Decimal128, shell-syntax/Extended JSON parser and formatter |
| `MongoWire` | Wire-protocol messages and framing (no I/O) |
| `MongoKit` | Transport, authentication, pooling, topology, SSH tunnels, version-aware operations |
| `CcinnMongoKit` | UI-independent app logic: profiles, query input, export/import, schema, explain, AI assistant |
| `CcinnMongo` | SwiftUI/AppKit application |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Protocol logic should be covered with the fake server in `Tests/MongoKitTests/Support`, and server-version behaviour with the integration suite.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data that comes from a server, a file or the user. Throw a descriptive error instead.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O or heavy formatting.
- **Version differences** belong in the strategy types selected by `ServerCapabilities`, not in scattered `if wireVersion >= …` checks.
- **Secrets** must never appear in logs, errors, prompts or files.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test` pass.
3. Describe what changed and how you tested it (including MongoDB versions, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
