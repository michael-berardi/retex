# Privacy

Retex is local-first. Notes leave the machine only through sync or export,
which you run yourself. The only automatic request is the update check below,
and it never sends notes, vault paths, identifiers or usage data.

## Update check

Only when you have chosen a release channel (`RETEX_UPDATE_REPO`, or the
channel saved by `retex update --auto on`), Retex makes **one anonymous HTTPS
GET** to that repository's public GitHub `releases/latest` record after an
interactive command. The request uses the fixed User-Agent
`retex-update-check` and carries no version, identifier, machine data or
usage data. Nothing is uploaded.

- At most one check per 24 hours, with a 4-second timeout, in the background.
  A failure is recorded, not printed and not retried until the next day.
- No check runs without a terminal, in CI, for machine output (`--json`,
  `--lean`, `--raw-json`), for the MCP server, with `RETEX_NO_UPDATE_CHECK=1`,
  or after `retex update --checks off`.
- `retex update`, `--check` and `--skip` contact the same endpoint when you run
  them. Installing also downloads the release asset and its `SHA256SUMS` from
  GitHub.

## What is stored

One private (`0600`) file in the platform cache directory,
`retex/update-state.json`, holds the last check time, latest version, failure
cause, skipped version, the check and auto switches, the saved channel, and
when the last notice was shown.

Automatic installs are off by default. When on, a background job writes one
log (`~/.config/retex/logs/retex-update.log`, kept under 256 KB). Download
directories are deleted on success and failure. The one `.previous` rollback
copy is deleted after the new version has run successfully.
`retex update --auto off` removes the job; `retex update --uninstall` removes
the job, the state file, the log and the rollback copy.

## Other data

Retex has no account, no vendor service and no analytics. Exports and sync are
explicit operations against your own server with your own credentials.
