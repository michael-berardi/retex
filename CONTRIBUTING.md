# Contributing to Retex

Bug reports, focused fixes and documentation improvements are welcome.

## Before you start

- Search [existing issues](https://github.com/michael-berardi/retex/issues) first.
- For anything larger than a small fix, open an issue describing the problem
  and the change you have in mind, so the approach can be agreed before you
  spend time on it.
- Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep the change focused on one problem. Unrelated refactors make review slower.
3. Add or update tests for behavior you change.
4. Update the README and any affected docs in the same pull request.
5. Run the checks below and make sure they pass.

```sh
swift build
swift test
```

Markdown stays the source of truth: a change must never require a database or
hide data from ordinary text editors. Keep machine-readable output backwards
compatible, or version it explicitly. Source builds do not include the proprietary
UltraCompact engine; keep every feature working without it.

## Pull requests

Describe what changed and why, how you tested it, and anything a reviewer
should look at closely. Never include credentials, personal data, private
paths or real user content in code, fixtures, issues or screenshots.

By contributing you agree that your contribution is licensed under the
project's [MIT License](LICENSE).
