# Retex 1.6.1 — hosted read-only helper fix

**Bottom line:** the read-only hosted helper (`deploy/readonly-mcp`) offers exactly
the read tools again. The `retex` CLI and MCP server behave as in 1.6.0.

- The hosted gateway exposes only the read tools and refuses the agent-memory
  tools that `retex mcp` added in 1.4.0.
- `pydantic` is pinned to 2.11.7; newer releases break `mcp` 1.16.0 at import.
- The helper's image builds from `v1.6.1` by default.
