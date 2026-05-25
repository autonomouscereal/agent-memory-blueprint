# Agent Memory Blueprint

A standalone deployment blueprint for agent memory using PostgreSQL, pgvector, JSONB metadata, full-text search, and hook ingestion.

It is designed for agent harnesses that can run shell hooks around user prompts, tool calls, and session lifecycle events. The reference implementation uses raw `psycopg2` and plain SQL. No ORM, no SQLAlchemy, no Pydantic, no private memories, and no environment-specific IPs.

## Why This Exists

Most agent memory setups fail in one of three ways:

- They append everything into context and eventually drown the model.
- They use a vector database as an unbounded junk drawer with no space, source, or lifecycle model.
- They store sensitive transcripts without clear audit and redaction boundaries.

This blueprint separates:

- Conversation/session history handled by the harness.
- Durable memory events stored in PostgreSQL.
- Semantic recall via pgvector.
- Keyword recall via PostgreSQL full-text search.
- Project boundaries through `space`.
- Hook audit through append-only events.

## Contents

- `schema/001_init.sql` - PostgreSQL schema with pgvector, full-text search, JSONB metadata, and indexes.
- `src/agent_memory.py` - small CLI for init, add, search, status, and hook ingestion.
- `hooks/` - example hook configs for compatible harnesses.
- `docs/harness-integration.md` - how to wire this into Codex, Claude Code-style hooks, Hermes-style wrappers, and custom agents.
- `.codex/skills/agent-memory-blueprint/SKILL.md` - installable skill for other agents.

## Quick Start

1. Copy `.env.example` to `.env` and fill a generated password.
2. Start Postgres:

```bash
docker compose up -d
```

3. Install dependencies:

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

On Windows PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

4. Initialize schema:

```bash
python src/agent_memory.py init
```

5. Add and search:

```bash
python src/agent_memory.py add --agent codex --event-type note --space demo --memory-kind decision --content "Use scoped memory before broad recall."
python src/agent_memory.py search "scoped memory" --space demo
```

## Hook Model

Use hook ingestion for the raw audit trail:

- `UserPromptSubmit`: store user intent.
- `PostToolUse`: store tool call metadata and output summary.
- `Stop`: store session end marker.

Hooks should be best-effort. Memory failure must not break the agent harness. This implementation exits zero for `hook` ingestion failures after logging to stderr.

## Security Defaults

- Store database passwords in env vars or a local credential manager.
- Never commit `.env`, runtime logs, transcripts, or vector snapshots.
- Redact obvious secret fields from metadata before insertion.
- Use `space` to avoid mixing unrelated projects.
- Treat retrieved memory as guidance, not truth. Current files and current user instructions win.

## Sources And Design Anchors

- OpenAI Agents SDK sessions define memory/session boundaries and custom session storage.
- OpenAI sandbox memory describes progressive disclosure and editable local memory notes.
- pgvector documents hybrid use with PostgreSQL full-text search.
- Current agent memory research increasingly separates state, episodic recall, and lifecycle handling rather than relying only on vector similarity.
