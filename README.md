# Retex

<p align="center">
  <a href="https://github.com/michael-berardi/retex/releases/latest"><img src="https://img.shields.io/github/v/release/michael-berardi/retex?label=release" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/michael-berardi/retex" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" alt="macOS, Linux and Windows" />
  <img src="https://img.shields.io/badge/MCP-server-8A2BE2" alt="MCP server" />
</p>

Retex is a Markdown vault CLI for people and agents. Query notes and custom
records, follow wiki links, and edit properties without moving your files into
a database. Agents can use compact JSON or the built-in, read-only-by-default
MCP server. Your Markdown stays readable in any editor.

## Install

```sh
curl -fsSL https://github.com/michael-berardi/retex/releases/latest/download/install.sh | sh
```

The installer downloads the [signed macOS universal binary](https://github.com/michael-berardi/retex/releases/latest/download/retex-universal.zip)
(macOS 14+) or the Linux static archive for your CPU, checks it against the
release `SHA256SUMS` (and the Developer ID signature on macOS), installs it
into `~/.local/share/retex/<version>`, and links `~/.local/bin/retex` to it.
Add `~/.local/bin` to your `PATH` if it is not there already:

```sh
export PATH="$HOME/.local/bin:$PATH"
retex --help
```

The link resolves to the real binary, so the built-in `retex update` keeps
working: it replaces that binary in the version folder and leaves a rollback
copy at `retex.previous`. Re-running the installer makes a fresh version
folder and repoints `~/.local/share/retex/current`. Existing files that the
installer did not create are never replaced. `RETEX_HOME`, `RETEX_BIN_DIR`,
`RETEX_VERSION` and `RETEX_RELEASE_BASE` override the locations and download
base for mirrors and tests. Windows requires a source build.

### Manual install

In an empty directory, download, verify, and run:

```sh
curl -fLO https://github.com/michael-berardi/retex/releases/latest/download/retex-universal.zip
curl -fLO https://github.com/michael-berardi/retex/releases/latest/download/SHA256SUMS
grep ' retex-universal.zip$' SHA256SUMS | shasum -a 256 -c -
unzip retex-universal.zip
codesign --verify --strict --verbose=2 retex
./retex --help
```

Only install after both verification commands succeed. Move `retex` into a
directory on your `PATH`. [Linux releases](https://github.com/michael-berardi/retex/releases/latest)
provide `retex-linux-x86_64.tar.xz` and `retex-linux-aarch64.tar.xz`; verify the
matching `SHA256SUMS` entry with `sha256sum -c` before extracting with
`tar -xJf <archive>.tar.xz`. Compatibility `.tar.gz` assets remain available
for the built-in updater.

### From source

With Swift 6.0+ (macOS 14+, Linux, or Windows):

```sh
git clone https://github.com/michael-berardi/retex.git && cd retex && swift build -c release -j 4
.build/release/retex --help
```

On Windows, run `.build\release\retex.exe --help`. Put the built executable
on your `PATH` to use `retex` below.

## First vault

Use a new directory for this example:

```sh
retex init --vault ./demo-vault --lean
retex create --vault ./demo-vault --type invoice --title "Example invoice" --set amount=120 --lean
retex query --vault ./demo-vault --type invoice --lean
retex recall "invoice" --vault ./demo-vault --budget 12000 --lean
retex mcp --vault ./demo-vault
```

The last command serves MCP over stdio until you stop it. Writes require
`--allow-write`. `--lean` returns the payload as compact JSON; `--json` adds a
versioned response envelope. Recall budgets count UTF-8 bytes, not tokens.

Retex also supports boards, saved views, undo, typed agent memory, Notion and
Obsidian imports, encrypted exports, and optional encrypted sync. Network
access is explicit through sync, updates, or hosted serving; ordinary local
vault commands need no account.

Keep `.retex/` when backing up a vault: it holds configuration, undo history,
and sync state. Encrypted exports preserve portable content but exclude that
state. Never point an untrusted agent at notes it should not read.

## Reference

- [CLI, output formats, vault format, import/export, sync and updates](docs/REFERENCE.md)
- [Agent memory and approval workflow](docs/AGENT-MEMORY.md)
- [Agent skill](skills/retex/SKILL.md)
- [Hosted read-only serving and refresh](docs/REALTIME-SYNC.md)
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Updates

The updater has no default repository. Select the release channel explicitly:

```sh
export RETEX_UPDATE_REPO=michael-berardi/retex
retex update --check --lean
```

Review the result before running `retex update`. Fleet and scheduler setup
are covered in the [reference](docs/REFERENCE.md#updates).

## Privacy

Retex sends nothing over the network unless you explicitly use a network feature. There is no telemetry, analytics, crash reporting or automatic update check, and no install ID or machine fingerprint is sent.

- **Sync:** `retex sync ...` sends an encrypted vault blob, the vault ID you chose and your bearer token to the server you configured, only when you run it. Your passphrase and plaintext notes never leave the machine; the server sees ordinary HTTP request metadata, including your IP address.
- **Updates:** `retex update` contacts `api.github.com` and GitHub release assets only after you set `RETEX_UPDATE_REPO`; `--check` only performs the lookup. The optional scheduler (`retex fleet install-updater`) runs that command every six hours only if you install it. Its macOS logs are owner-private and capped at 1 MiB.
- **Hosted serving:** if you deploy `deploy/readonly-mcp/`, clients send their queries and bearer tokens to your server. If you set `RETEX_VAULT_REPO`, its refresher polls that Git repository; nothing else is contacted automatically.

Your notes stay in your vault. Retex writes its own state under `<vault>/.retex/` (undo history, sync state, agent-memory usage), encrypted exports and the fleet registry with owner-only permissions. To remove Retex's local state, run `retex fleet remove-updater`, then delete `<vault>/.retex/`, `~/.config/retex/fleet.json`, the macOS `~/.config/retex/logs/` directory and any encrypted exports you created. Your Markdown notes are not deleted.

Retex has no analytics SDKs and no third-party fonts or scripts.

## License

[MIT](LICENSE). `RetexCore` is also available as a Swift package library.

---

Part of [Pareto Cybernetics](https://paretocybernetics.com/projects/retex/): free, private, open-source tools for working with AI agents.
