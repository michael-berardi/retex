<!-- update-contract: v1 -->

# Updates

Retex tells you when a newer stable release exists and installs it in one
step after verifying it. Retex ships no built-in repository: you choose the
release channel, so a fork or private build keeps its own.

```sh
export RETEX_UPDATE_REPO=owner/repo
```

`retex update --auto on` saves that `owner/repo` so the background job can
use it without your shell.

## Daily check

After an interactive command finishes, Retex asks the channel's public GitHub
**latest release** record whether a newer version exists. This is one
anonymous HTTPS GET with the fixed User-Agent `retex-update-check`; it sends
no version, identifier, machine or usage data.

- At most once per 24 hours. The result, or the failure and its cause, is
  cached in one small `0600` file (see [State](#state)).
- The lookup runs in the background with a 4-second timeout. A failure is
  never printed and is not retried until the next day. `retex update --auto
  status` shows the recorded cause; `retex update --check` retries and prints
  it.
- Only stable `x.y.z` releases strictly newer than yours count. Drafts,
  prereleases and unparseable tags are ignored.
- No check runs when stdout or stderr is not a terminal (pipes, agent
  sessions), when `CI` is set, for `--json`, `--lean` or `--raw-json`,
  for `mcp`, `update` and `watch`, with `RETEX_NO_UPDATE_CHECK=1`, or after
  `retex update --checks off`.

## Notice

Printed to stderr after the command's own output:

```
retex 1.11.0 available (you have 1.10.0) · run: retex update
turn on automatic updates: retex update --auto on · skip: retex update --skip
```

The second line is dimmed. Each version is shown at most once a day.
`retex update --skip` hides that version until a newer one is published. If
Homebrew installed Retex, the notice says `run: brew upgrade retex` instead.

## Commands

| Command | Result |
| --- | --- |
| `retex update` | Shows current → new and the first release-note lines, asks `Install <new> now? [Y/n]` on a terminal, then installs. Without a terminal it installs without asking. |
| `retex update --check` | Report only, reusing a successful check from the last day. Exit `0` up to date, `10` update available, `1` check failed (cause on stderr). `retex update` always asks GitHub. |
| `retex update --skip` | Hide this version's notice. |
| `retex update --auto on\|off\|status` | Automatic installs (off by default). |
| `retex update --checks on\|off` | The daily check (on by default). |
| `retex update --rollback` | Restore the previous binary. |
| `retex update --uninstall` | Remove update jobs, the state file, logs and the rollback copy. |

After the first successful interactive install Retex asks once:
`Install future updates automatically? [y/N]`. The answer is remembered and
the question is not repeated; `--auto on|off` changes it later.

## Automatic installs

Off until you turn them on. `retex update --auto on` installs a low-priority
job that runs `retex update --auto-run --json` every six hours:

- macOS: `~/Library/LaunchAgents/org.retex.cli.update.plist`
- Linux: `~/.config/systemd/user/retex-self-update.timer`
- Windows: the scheduled task `Retex Self Update`

The job uses the same daily check. It installs a new, non-skipped release
with the same verification as `retex update`; the new version runs from the
next command. If it fails, the current binary keeps working, the cause is
shown by `retex update --auto status`, and the notice returns. Its output
goes to one log, `~/.config/retex/logs/retex-update.log`, kept under 256 KB.
`retex update --auto off` removes the job.

The separate `retex fleet install-updater` job verifies registered vault
fleets; see the [reference](REFERENCE.md#updates).

## Install safety

- The release asset is installed only if its SHA-256 matches the release's
  `SHA256SUMS` entry. On macOS the binary must also carry the project's
  Developer ID signature and pass Gatekeeper, and every candidate must report
  the expected version before it replaces anything.
- The swap is atomic. The old binary is kept as `<binary>.previous`;
  `retex update --rollback` restores it. Only one copy exists, and it is
  deleted after the new version has run a command successfully.
- Downloads go to a temporary directory that is deleted on success and on
  failure.
- A binary under Homebrew's `Cellar` is upgraded with `brew upgrade` and never
  overwritten.

## State

One file holds the check result and your choices:
`<cache dir>/retex/update-state.json` (macOS `~/Library/Caches`, Linux
`~/.cache`). It stores the check time, latest version, the last check and
install failure causes, skipped version, the check and auto switches, whether
the auto question was answered, the saved channel, and when the last notice
was shown. Requests use no HTTP cache or cookies, so a check writes nothing
else.
`retex update --uninstall` deletes it together with the job and logs.

Overrides for tests and release drills: `RETEX_UPDATE_STATE` (state file
path), `RETEX_UPDATE_API` (a loopback fixture server only),
`RETEX_UPDATER_ROOT` and `RETEX_SCHEDULER_DRY_RUN=1` (keep jobs away from the
real launcher). See [PRIVACY.md](../PRIVACY.md) for the data statement.
