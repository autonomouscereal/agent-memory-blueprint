# Harness Integration

## General Contract

Any harness can use this memory backend if it can run a command with JSON on stdin.

Recommended events:

- Prompt submit: user text, cwd, session id, model, workspace.
- Tool use: tool name, arguments with secret fields redacted, output summary, status.
- Session stop: session id, cwd, final state, duration.

The hook command should be best-effort and should not block or fail the model run.

## Codex Desktop

Use the harness hook file supported by your Codex installation. Point each hook command at:

```text
python /absolute/path/to/agent-memory-blueprint/src/agent_memory.py hook --event-type UserPromptSubmit --agent Codex --source codex_hook
```

Set environment:

```text
MEMORY_DB_HOST
MEMORY_DB_PORT
MEMORY_DB_NAME
MEMORY_DB_USER
MEMORY_DB_PASSWORD
AGENT_MEMORY_SPACE
```

Use one `AGENT_MEMORY_SPACE` per project or thread family.

## Claude Code-Style Hooks

Use `hooks/claude_settings.example.json` as the shape, then replace the absolute path and agent name.

The hook reads JSON from stdin. Avoid shell interpolation of prompt text. Let stdin carry the payload.

## Hermes Or Custom Harnesses

Wrap the agent command with a small runner that:

1. Calls `agent_memory.py hook --event-type UserPromptSubmit`.
2. Runs the model/harness.
3. Calls the hook for each tool event if the harness exposes them.
4. Calls `agent_memory.py hook --event-type Stop`.

## Retrieval Pattern

At the start of substantial work:

```bash
python src/agent_memory.py search "current task keywords" --space "$AGENT_MEMORY_SPACE" --limit 8
```

Use `--all-spaces` only when deliberately searching for reusable knowledge across projects.

## Redaction

The reference hook redacts obvious metadata keys such as `password`, `token`, `secret`, `api_key`, `authorization`, and `cookie`. Do not rely on that as your only security layer. Upstream hooks should avoid sending secrets in the first place.
