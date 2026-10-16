---
name: agent-memory-blueprint
description: Deploy, wire, search and troubleshoot the PostgreSQL/pgvector agent memory backend (agent_memory.py + agent_memory_hook.py). Use when setting up durable memory for Claude Code, Codex, Hermes or a custom harness, wiring prompt/tool/session hooks, searching past work by project space, hydrating a full trace, or draining the failed-hook spool.
---

# Agent Memory Blueprint

A PostgreSQL-only memory backend. Hooks record every prompt, tool call and
session event; agents search it by project `space`. Set `MEMORY_HOME` below to
the folder that holds `agent_memory.py`.

## Install

1. `cp .env.example .env` and set `MEMORY_DB_PASSWORD` (or a password file or command).
2. `docker compose up -d` (or point `.env` at an existing PostgreSQL that has `vector` and `pg_trgm`).
3. `python -m pip install -r requirements.txt` (Python 3.11+).
4. `python agent_memory.py init`, then `python agent_memory.py --json self-test`.
5. Merge `hooks/claude_settings.example.json` or `hooks/codex_hooks.example.json` into the harness config with absolute paths.

## Use

```bash
python $MEMORY_HOME/agent_memory.py --json search "task keywords" --space "workspace/my-project" --limit 10
python $MEMORY_HOME/agent_memory.py --json search "task keywords" --all-spaces --limit 10   # deliberate cross-project recall
python $MEMORY_HOME/agent_memory.py --json grep "exact error text" --space "workspace/my-project"
python $MEMORY_HOME/agent_memory.py trace --event-id <id> --content-only --limit 1
python $MEMORY_HOME/agent_memory.py add --agent ClaudeCode --space "workspace/my-project" --memory-kind decision --content "Why we chose X"
python $MEMORY_HOME/agent_memory.py --json audit --agent ClaudeCode --limit 20
python $MEMORY_HOME/agent_memory.py spaces
```

## Rules

- Search the current project's space first. `--all-spaces` is a deliberate choice, not the default habit.
- Memory is guidance, not truth. Current files, current user instructions and live checks win over anything recalled.
- `search` is for recall; `grep` is for exact strings, IDs and paths.
- Raw SQL with `asyncpg` only. Do not add an ORM, SQLAlchemy, Pydantic, SQLite or a second vector store.
- Never commit `.env`, `logs/`, spooled payloads, exports or database dumps.
- Never put the database password in a hook command line.
- A hook must never break the harness: it stays silent and exits 0. Check failures with the commands below.

## Troubleshoot

```bash
python $MEMORY_HOME/agent_memory_hook.py --pending-status            # failed hooks waiting to be replayed
python $MEMORY_HOME/agent_memory_hook.py --replay-pending --limit 100
python $MEMORY_HOME/agent_memory.py --json ingest-error-log --dry-run --limit-groups 20
python $MEMORY_HOME/agent_memory.py --json status
```

Read `docs/architecture.md` before changing the schema, redaction, search scoring or hook transaction.
