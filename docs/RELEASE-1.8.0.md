# Retex 1.8.0 — neutrality and operator-owned update channel

Retex ships no built-in model, provider, fallback, paid-route or personal name.
This release removes the last hard-coded GitHub owner from the self-updater and
from the README release links, and adds a test that keeps the shipped tree
neutral.

- The self-updater now requires `RETEX_UPDATE_REPO` (the `owner/repo` it should
  track). `retex update` reports a clear error naming that variable when it is
  unset. No repository owner is compiled into the binary.
- README release links, badges and clone commands use the neutral placeholder
  owner `your-org`.
- New `NeutralityTests` scans `Sources/`, `docs/`, `skills/`, `scripts/` and
  `README.md` for model ids, provider choices and personal/project names.
  `LICENSE` and package metadata are excluded so legal attribution stays intact.

No vault format, CLI contract or sync protocol changed. Existing installations
keep working; only `retex update` needs `RETEX_UPDATE_REPO` set to the channel
the operator actually uses.
