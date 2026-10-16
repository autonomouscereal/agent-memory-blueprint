# Agent Memory Blueprint

Long-term memory for coding agents, in plain PostgreSQL.

Hooks in the agent harness (Claude Code, Codex, Hermes, or anything that can
pipe JSON to a command) record every prompt, tool call and session event. The
agent later searches that history by project. Search blends pgvector,
PostgreSQL full-text and trigram matching in one query. There is no separate
vector database, no ORM and no model server.

This is the code we run every day, not a demo. Since May 2026 one database on a
home-lab server has taken writes from Claude Code, Codex and several other
agents: about a million events in 1,800+ project spaces, 45 GB on PostgreSQL 16
with pgvector 0.8.

## Why it works for us

- **Nothing depends on the model deciding to save something.** Hooks capture
  everything automatically, so "what did we try last week?" has an answer even
  if nobody thought to write it down. Explicit notes (`add`) sit on top for
  decisions worth calling out.
- **Recall is scoped.** Every event lands in a `space`, derived from the
  working directory by default. Agents search the current project first and go
  `--all-spaces` only on purpose, which keeps unrelated work out of the
  context.
- **Search rows stay small; full payloads are kept.** The searchable row is
  compact. The complete redacted payload is stored compressed beside it and
  pulled in with `trace` only when needed.
- **Memory can't take the agent down.** Every hook has bounded timeouts, stays
  silent and exits 0. If the database is unreachable, the event is spooled to
  disk and replayed later.
- **It is just Postgres.** Backups, replication, access control, `psql`, and
  boring SQL you can read. One database, one source of truth.
- **Memory is treated as guidance.** The skill and agent instructions say
  current files and live checks beat anything recalled.

## Quick start

Needs Python 3.11+ and Docker (or any PostgreSQL 16+ with the `vector` and
`pg_trgm` extensions).

```bash
git clone https://github.com/autonomouscereal/agent-memory-blueprint.git
cd agent-memory-blueprint
cp .env.example .env              # then set MEMORY_DB_PASSWORD
docker compose up -d
python -m pip install -r requirements.txt
python agent_memory.py init
python agent_memory.py --json self-test
```

Try it by hand:

```bash
python agent_memory.py add --agent me --space demo --memory-kind decision \
  --content "Search the current project space before going cross-project."
python agent_memory.py search "cross-project search" --space demo
```

Then wire up the hooks, which is where it starts paying off.

## Wire up a harness

**Claude Code:** merge [`hooks/claude_settings.example.json`](hooks/claude_settings.example.json)
into `~/.claude/settings.json` and replace `/path/to/agent-memory-blueprint`
with the absolute path. **Codex:** do the same with
[`hooks/codex_hooks.example.json`](hooks/codex_hooks.example.json) into
`~/.codex/hooks.json`. Anything else: pipe the event JSON to
`agent_memory_hook.py --event <Name> --agent <Name>`. See
[docs/harness-integration.md](docs/harness-integration.md).

Then tell the agent the memory exists. Add a short section to `CLAUDE.md` /
`AGENTS.md` (there's one ready to paste in the integration doc) or install
[`skills/agent-memory-blueprint`](skills/agent-memory-blueprint/SKILL.md).
Hooks fill the database; the instructions are what make the agent look things
up.

## Everyday commands

```bash
python agent_memory.py --json search "hook timeout on large payload" --space workspace/my-api --limit 10
python agent_memory.py --json search "how we fixed the deploy" --all-spaces
python agent_memory.py --json grep "ProgramLimitExceededError" --space workspace/my-api   # exact text, IDs, paths
python agent_memory.py trace --event-id 123456 --content-only --limit 1                  # full archived payload
python agent_memory.py --json audit --agent ClaudeCode --limit 20                         # recent activity
python agent_memory.py --json audit --model-id claude-opus-5-5 --limit 20                 # by model
python agent_memory.py spaces
python agent_memory.py --json status
python agent_memory.py ingest-path ./docs --recursive --space workspace/my-api --tags docs
python agent_memory_hook.py --pending-status          # hooks waiting to be replayed
python agent_memory_hook.py --replay-pending
```

`relate`, `entities` and `graph` maintain a small entity graph for explicit
notes. `backfill-identities`, `ingest-codex-transcript` and `ingest-error-log`
are recovery tools; [docs/architecture.md](docs/architecture.md) covers them.

## How it fits together

```text
 harness hook (stdin JSON)
        │
        ▼
 agent_memory_hook.py ── redact ── compact ── choose space ── attach model/session identity
        │                                                      │
        │  one transaction                                     │  DB down?
        ▼                                                      ▼
 agent_memory_events  (compact row: embedding,            logs/pending/*.zlib
   tsvector, trigram, space, tags, JSONB metadata)        replayed by the next hook
 agent_memory_payload_archives  (full redacted payload, zlib BYTEA, SHA-256)

 search ─► HNSW + full-text candidates ─► rerank 0.68 vector + 0.22 FTS + 0.10 trigram
 trace  ─► hydrate the archive for one hit
```

The details are in [docs/architecture.md](docs/architecture.md): every table,
the write and read paths, what gets redacted, the search cache, and identity
tracking. A schema dump is in [`schema/`](schema/agent_memory_schema.sql).

## Configuration

`agent_memory.py` reads `MEMORY_*` and `AGENT_MEMORY_*` keys from the `.env`
next to it; real environment variables win. It never reads a `.env` from the
hook's working directory, so a project's own `.env` can't redirect memory.

| Variable | Default | Meaning |
|---|---|---|
| `MEMORY_DB_HOST` / `_PORT` / `_NAME` / `_USER` | `127.0.0.1` / `25490` / `agent_memory` / `agent_memory` | Where the database is. |
| `MEMORY_DB_PASSWORD` | | Password. Also tried: `PGPASSWORD`, then the two below. |
| `MEMORY_DB_PASSWORD_FILE` | | Read the password from a file (Docker/K8s secrets). |
| `MEMORY_DB_PASSWORD_COMMAND` | | Run a command that prints it (a vault CLI, `op read ...`). `{python}` = the hook's interpreter. |
| `AGENT_MEMORY_WORKSPACE_SPACES` | | `dir=space,dir2=team/space` rules for naming spaces from the cwd. |
| `AGENT_MEMORY_SPACE` | | Pin everything to one space. Set it per launcher, not in `.env`. |
| `AGENT_MEMORY_MIN_SEARCH_SCORE` | `0.18` | Score floor for `search`. |
| `AGENT_MEMORY_SEARCH_CACHE` | `1` | `0` turns off the result cache (diagnostics only). |
| `AGENT_MEMORY_HOOK_CONNECT_TIMEOUT` | `4` | Seconds per connect attempt (2 attempts). |
| `AGENT_MEMORY_HOOK_STATEMENT_TIMEOUT_MS` / `_LOCK_TIMEOUT_MS` | `15000` / `3000` | Hook SQL bounds. |
| `AGENT_MEMORY_HOOK_MAX_CONTENT_CHARS` | `60000` | Searchable text kept per hook event; the archive keeps everything. |
| `AGENT_MEMORY_LOG_DIR` / `AGENT_MEMORY_PENDING_DIR` | `./logs` / `./logs/pending` | Error log and failed-hook spool. |

## Security

- The password never needs to be in a command line, a hook config or the repo.
  Use `.env` (gitignored), a password file, or a password command.
- Compose binds Postgres to `127.0.0.1` by default. If you open it to a LAN,
  firewall it to your own machines.
- Hooks redact structured secret fields, auth and cookie headers, credential
  URLs, private keys, JWTs and common API token formats before storing
  anything. Treat that as a backstop. The database still holds everything your
  agents saw, so protect it like source code plus shell history.
- `.gitignore` here is an allowlist, so the folder can double as a live
  install without logs, spooled payloads or local notes ever getting committed.

## Limits

- The built-in embedder is a deterministic lexical feature hash, not a neural
  model. It is fast and needs no GPU, but it won't connect synonyms that share
  no words. Full-text and trigram scoring cover most of that gap for agent
  work. You can swap in a neural embedder in `cpu_embedding()`; existing rows
  then need re-embedding.
- No retention policy is built in. Everything is kept. Prune by `space` or
  `created_at` with SQL if you need to.
- Image/OCR/speech understanding isn't included. Media is indexed by metadata
  and same-name sidecar files (`.txt`, `.srt`, `.vtt`, ...).

## Tests

```bash
python -m unittest test_agent_identity -v   # identity attribution, no database needed
python test_identity_postgres.py            # live: 40 concurrent hook processes, redaction, archives, search
```

The live test writes to space `agent-memory/identity-test` under agent
`IdentityTest`.

## Background reading

- pgvector: https://github.com/pgvector/pgvector
- PostgreSQL full-text search: https://www.postgresql.org/docs/current/textsearch.html
- `pg_trgm`: https://www.postgresql.org/docs/current/pgtrgm.html
- Claude Code hooks: https://code.claude.com/docs/en/hooks
- OpenAI Agents SDK sessions: https://openai.github.io/openai-agents-python/sessions/
- LangGraph memory concepts: https://docs.langchain.com/oss/python/concepts/memory
