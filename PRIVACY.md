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

## Other network use

Nothing else runs automatically. No telemetry, analytics, crash reporting,
install ID or machine fingerprint.

- **Sync:** `retex sync ...` sends an encrypted vault blob, the vault ID you
  chose and your bearer token to the server you configured, only when you run
  it. Your passphrase and plaintext notes never leave the machine; the server
  sees ordinary HTTP request metadata, including your IP address. The
  reference sync server does not log client IP addresses.
- **Fleet updater:** the optional scheduler (`retex fleet install-updater`)
  runs `retex update --auto --fleet` every six hours only if you install it,
  and logs to the same bounded, owner-only log.
- **Hosted serving:** if you deploy `deploy/readonly-mcp/`, clients send their
  queries and bearer tokens to your server. If you set `RETEX_VAULT_REPO`, its
  refresher polls that Git repository; nothing else is contacted
  automatically. The image disables pip's version check and sets
  `DO_NOT_TRACK=1`.

## Other local data

Your notes stay in your vault. Retex writes its own state under
`<vault>/.retex/` (undo history, sync state, agent-memory usage), encrypted
exports and the fleet registry with owner-only permissions (`0700` folders,
`0600` files). Retex has no account, no vendor service, no analytics SDKs and
no third-party fonts or scripts.

## Removing everything

Run `retex update --uninstall` and `retex fleet remove-updater`, then delete
`<vault>/.retex/`, `~/.config/retex/` and any encrypted exports you created.
Your Markdown notes are not deleted.
