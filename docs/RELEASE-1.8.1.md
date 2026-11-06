# Retex 1.8.1 — hosted helper refreshes only what it serves

The hosted read-only helper polls a vault repository and serves one
subdirectory of it. Until now every new commit anywhere in that repository
triggered a full shallow clone, a copy of the whole tree and a swap, even
when the served subdirectory had not changed. One deployment measured about
110 GB of disk writes in 5 days from those refreshes.

- The refresher clones blobless and without checkout, reads the git tree id
  of the served subdirectory, and skips the refresh when it matches the tree
  already served. The status file still records the new revision.
- When the subdirectory did change, only that subdirectory is checked out
  (sparse checkout), validated and swapped in, as before.
- The hosted Dockerfile's default `RETEX_REF` is `v1.8.1` (it still named
  `v1.7.0`).

No CLI, vault format, MCP tool surface or sync protocol changed.
