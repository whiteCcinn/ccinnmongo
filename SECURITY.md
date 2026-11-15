# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnMongo.

| Version | Supported |
|---|---|
| 1.1.x | ✅ |
| 1.0.x | ❌ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnmongo/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (MongoDB version, connection options, sample data if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Passwords and SSH secrets are stored in the macOS Keychain; saved profiles on disk never contain them.
- The optional AI assistant never receives connection strings, host names or credentials. Queries requested by the agent are executed by CcinnMongo under a read-only policy. Issues that let an agent bypass this policy are considered security vulnerabilities.
- The MCP server (`CcinnMongo mcp`) only uses connections the user enabled for AI access and enforces read-only access itself. Any way for an MCP client to write through a read-only connection, run server-side JavaScript, read credential collections, exceed the documented limits, or obtain passwords or SSH secrets is a security vulnerability.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnMongo/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's release downloads, at the size the release lists, and with the SHA-256 published in the same release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new`: changed host keys are rejected.
