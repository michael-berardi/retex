# Retex 1.3.0 — correctness, safety, and performance

Every change below was reproduced against 1.2.2 first and then verified with
a regression test or a before/after measurement on the same machine.

## Measurements

The synthetic vault had 20,000 notes (79 MB, flat YAML, flow-list tags, 5% of
lines containing accented words). It ran on Linux x86_64 with 4 cores and a
release build without the UltraCompact engine. Each time is the best of 3
wall-clock runs, including process start.

| Command | 1.2.2 | 1.3.0 | Output |
| --- | ---: | ---: | --- |
| `list --all` (full scan) | 2.00 s | 0.50 s | identical |
| `query --type deal` | 1.90 s | 0.35 s | identical |
| `count` / `doctor` / `board` / `schema` | 1.8–1.9 s | 0.31–0.35 s | identical |
| `search release` | 2.11 s | 0.52 s | identical |
| `search --ranked` (2 terms) | 4.33 s | 0.61 s | identical |
| `recall` (limit 20) | 2.74 s | 0.75 s | identical |
| `recall` (limit 2000, 1 MB budget) | 20.9 s | 0.55 s | identical |
| `links` | 4.25 s | 1.29 s | identical |
| `vocabulary` | 50.3 s | 5.0 s | identical |
| MCP `get_stats` / `list_notes` | 2.6 s / 2.5 s | 0.57 s / 0.50 s | identical |
| `set` with a 29 MB undo journal | 1,253 ms | 17 ms | identical |
| Notion ZIP import, 3,000 pages | >10 min | 3.7 s | links now correct |

The causes were these:

- On Linux, Foundation string bridging (`String(contentsOf:)`,
  `components(separatedBy:)`, `trimmingCharacters`) was used on every note.
- `CharacterSet` values were rebuilt on every access.
- The recall byte budget re-encoded the growing record array for every hit,
  which is quadratic.
- Vocabulary candidates were copied, along with their source sets, on every
  update, which is quadratic.
- The undo journal was rewritten in full on every mutation.
- Notion link rewriting ran every path mapping over every note, which is
  quadratic.

## Fixes

### Crashes and data safety

- `retex links` and the MCP `get_links` tool crashed (SIGILL) when any note
  in the vault contained `[[]]` or `[[|alias]]`.
- Encrypted import overwrote files in a non-empty destination. A crafted
  archive could also write hidden paths such as `.git/config`, which led to
  code execution. Restores now require a new or empty destination and accept
  only the paths an export can contain.
- ZIP imports trusted the sizes declared in the archive, so a zip bomb could
  fill the disk. Real decompressed bytes are now counted before anything is
  written.
- A ZIP with duplicate entry names made `unzip` wait on stdin for a "replace?"
  answer, so the import hung.
- Notion collision renames wrote files under the process working directory.
  Links to nested pages broke. A CSV-derived table could overwrite a real
  note, and an ID-only folder could overwrite a sibling note.
- A single non-UTF-8 note aborted an import and left partial output that
  blocked any retry. Such notes are now copied byte for byte, and a failed
  import is rolled back.
- One deleted vault made every `fleet` command fail permanently, including
  `unregister`.

### Front matter fidelity

- Nested YAML leaked into the top level: an indented `title:` replaced the
  note title, block-scalar lines became properties, and `- http://…` list
  items became a property named `- http`.
- `tags: urgent` produced no tags. As a result, `retex create --set
  tags=urgent` followed by `query --tag urgent` found nothing.
- Values did not round-trip. `She said: "hi"` read back as `She said: \"hi\`.
  Values starting with `*`, `&`, `|`, `>`, `!`, or `-` were written as invalid
  or different YAML. Across 2,394 fuzzed values, 1.2.2 corrupted 180 of 479
  per run on round-trip; 1.3.0 corrupts none, and PyYAML reads every value
  identically.

### Search and recall

- `recall` could not find any note containing an accented word: `recall café`
  and `recall cafe` both missed "café". `search cafe` also missed "café",
  even though `search café` found "cafe". Matching is now case- and
  accent-insensitive in both directions for both commands.
- A stray `[[` could swallow text across lines up to a later `]]`, hiding the
  real link that followed.

### CLI and MCP

- `retex watch` output was block-buffered when piped, so events arrived late
  or were lost on exit.
- The passphrase prompt echoed input and trimmed spaces, unlike
  `--passphrase-env`. It no longer echoes and keeps spaces. For older exports,
  import retries once with the passphrase trimmed.
- Error JSON key order varied from run to run. Keys are now sorted.
- An oversized MCP request produced three error responses. It now produces
  one, and the requests after it are still served.
- `Package.swift` failed to type-check on Swift 6.0 and 6.1, although both are
  documented as supported.

### macOS release verification

- `update --fleet` parsed the candidate's `create --json` reply as plain JSON,
  but `--json` emits UltraCompact when the engine is linked. The mutation probe
  now requests `--raw-json`, and accepts the clone's `realpath` spelling:
  Foundation drops macOS's `/private` prefix while the CLI reports it.
- A quoted flow list (`tags: "[work, home]"`) produced the tags `[work` and
  `home]`; it reads as `work`, `home` again, as in 1.2.2.
- `retex export` skips symlinks, as documented, and now names each skipped
  symlink on stderr instead of omitting it silently.

## Upgrade note for fleet auto-update

`retex update --fleet` refuses an upgrade when `list` or `board` output changes
for a registered vault. Vaults that use scalar `tags: x`, nested YAML, or
escaped quoted values will report a compatibility mismatch. This is expected:
their tags, titles, or properties are now read correctly. Check them with
`retex fleet verify --candidate <new retex>`, then update without `--fleet`
once you accept the corrected output. Vaults written with the documented
`tags: [a, b]` form are unaffected.
