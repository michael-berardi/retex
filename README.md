# Retex

Retex is a Markdown vault CLI for people and agents. Query notes and custom
records, follow wiki links, and edit properties without moving your files into
a database. Agents can use compact JSON or the built-in, read-only-by-default
MCP server. Your Markdown stays readable in any editor.

## Install

Build from source with Swift 6.0+ (macOS 14+, Linux, or Windows):

```sh
git clone https://github.com/michael-berardi/retex.git && cd retex && swift build -c release -j 4
.build/release/retex --help
```

On Windows, run `.build\release\retex.exe --help`. Put the built executable
on your `PATH` to use `retex` below.

Prefer a binary? [Releases](https://github.com/michael-berardi/retex/releases/latest)
provide macOS universal and Linux archives with `SHA256SUMS`.
For macOS, download and verify in an empty directory:

```sh
curl -fLO https://github.com/michael-berardi/retex/releases/latest/download/retex-universal.zip
curl -fLO https://github.com/michael-berardi/retex/releases/latest/download/SHA256SUMS
grep ' retex-universal.zip$' SHA256SUMS | shasum -a 256 -c -
unzip retex-universal.zip
codesign --verify --strict --verbose=2 retex
```

Only install after both verification commands succeed. Linux assets are
`retex-linux-x86_64.tar.gz` and `retex-linux-aarch64.tar.gz`; verify the matching
checksum with `sha256sum -c` before extracting. Windows requires a source build.

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

## License

[MIT](LICENSE). `RetexCore` is also available as a Swift package library.
