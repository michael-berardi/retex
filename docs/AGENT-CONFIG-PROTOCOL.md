# Agent Configuration Protocol

A generic, plug-and-play format for powering a conversational agent from a
Retex vault. Any runtime that speaks this protocol can boot an agent from two
things: **one configuration file** and **one vault**. The vault is the
agent's entire mind — identity, knowledge, and behavior live there as plain
Markdown, versioned in its own Git repository.

## 1. Vault layout (the agent's mind)

```
<vault-root>/
├── persona.md        ← who the agent is: name, role, voice, boundaries
├── faq.md            ← curated answers the agent should know verbatim
└── knowledge/        ← domain notes (one topic per file, linked freely)
```

Rules:
- Every file is plain Markdown (Retex-managed). No secrets in the vault —
  runtime credentials come from the host environment only.
- `persona.md` is required; the agent must not boot without it.
- Everything else is optional and free-form; the runtime surfaces vault notes
  to the model as read-only knowledge unless the config opts into writes.

## 2. Agent configuration file (`agent.yaml`)

```yaml
agent_id: my-agent            # unique, lowercase, [a-z0-9-]
name: "My Agent"              # display name (also the trigger word)
identity:
  theme: "one-line role"      # what the agent is
knowledge_vault: my-agent     # vault directory name under the vault root
knowledge_vault_repo: ""      # optional: private Git repo the vault syncs from
knowledge_mode: read          # "read" (default) | "write" (agent may update its vault)

# Runtime-specific bindings live under the runtime's own keys and must be
# ignorable by other runtimes (unknown keys are allowed and skipped).
```

### Trigger contract (universal)

Saying the agent's `name` as a standalone word — in a reply to the agent or
in a fresh message — is always a trigger for a response. Word-boundary match,
case-insensitive. Possessives ("My Agent's") contain the word and trigger.
Runtimes may add additional triggers (commands, @mentions, direct messages)
but may not remove the name trigger.

## 3. Vault-as-repo lifecycle

- The vault lives in its own **private Git repository** (one repo per agent).
- The hosting runtime clones it at startup (`VAULT_REPO_URL` +
  `VAULT_GITHUB_TOKEN` env pattern) and pulls on restart.
- Editing the vault and pushing is how you change the agent. No redeploy
  needed for knowledge changes pulled on restart; no code changes ever.

## 4. Validation

`schemas/agent-config.schema.json` in this repository validates an
`agent.yaml`. Runtimes SHOULD validate at boot and fail fast on a vault
missing `persona.md`.
