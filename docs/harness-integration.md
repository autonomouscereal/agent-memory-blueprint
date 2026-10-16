# Harness Integration

Any harness works if it can run a command and pipe JSON to its stdin on these
moments: user prompt, tool call (and ideally tool failure), turn end, session
end. The hook stays silent on stdout/stderr and always exits 0, so it is safe
to put on every event.

```text
python /abs/path/agent_memory_hook.py --event <EventName> --agent <AgentName> --source <source_tag>
```

- `--event`: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PostToolUseFailure`, `Stop`, `StopFailure`, `PreCompact`, `SessionStart`,
  `SessionEnd`. Unknown names are stored as-is.
- `--agent`: who wrote it (`ClaudeCode`, `Codex`, `Hermes`, ...). This is what
  `--agent` filters on later.
- `--source`: free-form tag for the integration (`claude_hook`, `codex_hook`).
- `--space`: optional; normally inferred from the payload's `cwd`.

Use an absolute path to the interpreter that has `asyncpg` installed. Keep the
password out of the command line; put it in `.env` or use
`MEMORY_DB_PASSWORD_COMMAND`.

## Claude Code

Merge `hooks/claude_settings.example.json` into `~/.claude/settings.json` (all
projects) or `.claude/settings.json` (one project), then fix the path. It
covers `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Stop`,
`StopFailure`, `PreCompact` and `SessionEnd`.

Claude's payload includes `session_id`, `cwd`, `transcript_path`, tool names,
inputs and responses. The identity resolver reads model IDs from the
transcript the payload points at, including sub-agent transcripts, and never
from "the newest file on disk".

## Codex

Codex reads `~/.codex/hooks.json` in the same shape. Start from
`hooks/codex_hooks.example.json`. When a Codex hook was skipped, recover the
session afterwards:

```bash
python agent_memory.py ingest-codex-transcript ~/.codex/sessions/2026/10/16/rollout-...-<thread-id>.jsonl          # preview
python agent_memory.py ingest-codex-transcript ~/.codex/sessions/2026/10/16/rollout-...-<thread-id>.jsonl --apply  # write
```

## Hermes and custom harnesses

Wrap the agent loop and pipe one JSON object per event:

```bash
echo '{"session_id":"run-42","cwd":"/work/my-api","model_id":"my-served-model","tool_name":"shell","tool_input":{"cmd":"pytest"},"tool_response":{"exit_code":0}}' \
  | python agent_memory_hook.py --event PostToolUse --agent Hermes --source hermes_hook
```

Identity fields can be at the top level or under `metadata.identity`. Any
field the payload leaves out falls back to an `AGENT_MEMORY_<FIELD>`
environment variable, so a launcher can set them once: `AGENT_MEMORY_MODEL_ID`,
`AGENT_MEMORY_MODEL_PROVIDER`, `AGENT_MEMORY_HARNESS`,
`AGENT_MEMORY_HARNESS_VERSION`, `AGENT_MEMORY_THREAD_ID`,
`AGENT_MEMORY_AGENT_ID`, `AGENT_MEMORY_RUN_ID`, `AGENT_MEMORY_GPU_UUID`,
`AGENT_MEMORY_GPU_NAME`, `AGENT_MEMORY_QUANTIZATION`, and so on. Prefer the
served model ID over an alias.

If your harness has no hooks at all, call `agent_memory.py add` at the points
you care about. You lose the automatic audit trail, but recall works the same.

## Several agents, one database

This is how we run it: Claude Code, Codex and a few other agents all write to
one Postgres on a separate server. Each event carries `agent`, `space` and
identity metadata, so you can scope recall to one agent or read across all of
them. To do that:

- Open the compose port to your LAN (see the comment in `docker-compose.yml`)
  and firewall it to your own hosts.
- Give every machine the same `.env` host/port/user and its own way of getting
  the password.
- Pick consistent `--agent` names. They are just strings.

## Teaching the agent to use it

Hooks only fill the database. The agent also has to search it. Put something
like this in `CLAUDE.md` / `AGENTS.md`:

```markdown
## Memory
Before substantial work, search memory for this project first:
    python /abs/path/agent_memory.py --json search "<task keywords>" --space "<project space>" --limit 10
Use --all-spaces only when deliberately looking for something reusable from another project.
For exact errors, IDs or paths use `grep` instead of `search`.
Hydrate a hit's full payload with: python /abs/path/agent_memory.py trace --event-id <id> --content-only
Memory is guidance, not truth: current files, current instructions and live checks win.
```

`skills/agent-memory-blueprint/SKILL.md` packages the same guidance as a skill
for Claude Code (`~/.claude/skills/`) or Codex (`~/.codex/skills/`).

## Redaction is a backstop

The hook redacts common secret shapes before anything is stored (see
`docs/architecture.md`). Don't rely on that alone. Keep secrets out of prompts
and tool output upstream where you can, and treat the database as sensitive:
it holds everything your agents saw.
