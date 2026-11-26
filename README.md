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
- [Privacy](PRIVACY.md) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Updates

Retex checks once a day, anonymously, for a newer stable release and prints a
short notice after interactive commands. There is no default channel; choose
it yourself:

```sh
export RETEX_UPDATE_REPO=michael-berardi/retex
retex update            # verified install, previous binary kept for rollback
retex update --auto on  # optional; automatic installs are off by default
```

Details, `--check` exit codes and opt-outs: [docs/updates.md](docs/updates.md).

## Privacy

Notes leave the machine only through sync or export. Once you choose a
release channel, Retex makes one anonymous HTTPS GET a day to it, with no
identifier or usage data; never without a terminal, in CI or for machine
output. `RETEX_NO_UPDATE_CHECK=1` turns it off. No telemetry. Local state stays
owner-only under `<vault>/.retex/`. Details: [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE). `RetexCore` is also available as a Swift package library.

---

Part of [Pareto Cybernetics](https://paretocybernetics.com/projects/retex/): free, private, open-source tools for working with AI agents.
