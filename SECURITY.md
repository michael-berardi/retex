# Security policy

## Supported versions

Security fixes land on `main` and ship in the next release. Only the latest
release of Retex is supported.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/michael-berardi/retex/security/advisories/new).
Do not open a public issue for an undisclosed vulnerability.

Include the affected version, your operating system, reproduction steps and
the impact you observed. Leave out credentials, personal data and private
files; a minimal synthetic reproduction is enough.

You can expect an acknowledgement within 7 days. Reporters are credited in
the release notes if they want to be.

## Scope

In scope: path traversal or symlink escapes out of a vault, unsafe handling
of imported Notion or Obsidian archives, weaknesses in encrypted export,
update verification bypasses, MCP tools that write when they should only
read, and authentication flaws in `deploy/readonly-mcp/`. The optional
UltraCompact engine is distributed separately; report issues with it the
same way and they will be routed.
