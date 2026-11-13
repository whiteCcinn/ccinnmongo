# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnMongo.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

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
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new`: changed host keys are rejected.
