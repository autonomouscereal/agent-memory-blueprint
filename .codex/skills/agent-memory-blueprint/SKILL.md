---
name: agent-memory-blueprint
description: Deploy or integrate a standalone PostgreSQL/pgvector memory backend for AI agents. Use when setting up durable agent memory, hook ingestion for prompts/tool calls/session stops, semantic search, scoped memory spaces, or portable memory blueprints for Codex, Claude Code-style hooks, Hermes, and custom harnesses.
---

# Agent Memory Blueprint

Use this skill to install or wire the standalone memory backend in this repo.

## Workflow

1. Read the repo `README.md` for the deployment shape.
2. Copy `.env.example` to `.env` and set a generated `MEMORY_DB_PASSWORD`.
3. Start PostgreSQL with `docker compose up -d`.
4. Install `requirements.txt` into a local venv.
5. Run `python src/agent_memory.py init`.
6. Test with `add`, `search`, and `status`.
7. Wire hooks using `hooks/claude_settings.example.json`, `hooks/codex_hooks.example.json`, or a custom wrapper.

## Rules

- Use raw PostgreSQL and `psycopg2`; do not introduce ORM, SQLAlchemy, Pydantic, SQLite, or Chroma.
- Never commit `.env`, runtime logs, transcripts, or exported memories.
- Treat memory as guidance only. Current files, current user instructions, and live verification win.
- Use one memory `space` per project, ticket family, experiment, or major idea.
- Search the current space first; use `--all-spaces` deliberately.
- Hook failures must not break the harness.

## Useful Commands

```bash
python src/agent_memory.py init
python src/agent_memory.py status
python src/agent_memory.py add --space demo --agent codex --event-type note --memory-kind decision --content "Remember scoped search first."
python src/agent_memory.py search "scoped search" --space demo
```
