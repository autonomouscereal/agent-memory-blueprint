"""Evidence-based harness/model identity. No transcript content enters metadata."""
from __future__ import annotations

import json
import os
import re
import socket
from datetime import UTC, datetime
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping

IDENTITY_VERSION = 1
ALIASES = {
    "model_id": ("model_id", "modelId", "model", "model_name", "modelName"),
    "model_provider": ("model_provider", "modelProvider", "provider"),
    "model_display_name": ("model_display_name", "modelDisplayName"),
    "harness": ("harness", "harness_name", "harnessName"),
    "harness_version": ("harness_version", "harnessVersion", "cli_version"),
    "session_id": ("session_id", "sessionId", "conversation_id", "conversationId"),
    "thread_id": ("thread_id", "threadId", "thread-id"),
    "parent_thread_id": ("parent_thread_id", "parentThreadId"),
    "agent_id": ("agent_id", "agentId"),
    "agent_path": ("agent_path", "agentPath"),
    "agent_type": ("agent_type", "agentType"),
    "agent_name": ("agent_name", "agentName", "agent_nickname"),
    "turn_id": ("turn_id", "turnId", "turn-id"),
    "run_id": ("run_id", "runId"),
    "reasoning_effort": ("reasoning_effort", "reasoningEffort", "effort"),
    "gpu_uuid": ("gpu_uuid", "gpuUuid"),
    "gpu_name": ("gpu_name", "gpuName"),
    "quantization": ("quantization",),
}


def scalar(value: Any) -> str | None:
    if isinstance(value, dict):
        value = value.get("id") or value.get("name") or value.get("level")
    if isinstance(value, (str, int, float)) and str(value).strip():
        return str(value).strip()[:512]
    return None


def field(obj: Any, *names: str) -> Any:
    if isinstance(obj, dict):
        for name in names:
            if obj.get(name) not in (None, ""):
                return obj[name]
    return None


def epoch(value: Any) -> float | None:
    if isinstance(value, datetime):
        return value.timestamp()
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def bounded_records(path: Path, full: bool = False) -> list[dict[str, Any]]:
    """Head + bounded tail for live hooks; bounded full scan for history repair."""
    limit = 32 * 1024 * 1024 if full else 2 * 1024 * 1024
    try:
        with path.open("rb") as stream:
            head = stream.readline(256 * 1024)
            stream.seek(0, 2)
            size = stream.tell()
            start = max(len(head), size - limit)
            stream.seek(start)
            if start > len(head):
                stream.readline()
            lines = [head] + stream.read(limit).splitlines()
    except (OSError, ValueError):
        return []
    records = []
    for line in lines:
        # Tool traces may be megabytes long. Only parse records that can carry
        # native identity; never decode their embedded tool content for matching.
        if not re.search(rb'"type"\s*:\s*"(?:session_meta|turn_context|assistant)"', line[:512]):
            continue
        try:
            record = json.loads(line)
            if isinstance(record, dict):
                records.append(record)
        except (ValueError, UnicodeError):
            pass
    return records


@lru_cache(maxsize=64)
def transcript_facts(path_text: str, size: int, mtime_ns: int, full: bool) -> tuple[dict, list]:
    header: dict[str, Any] = {}
    observations = []
    for record in bounded_records(Path(path_text), full=full):
        stamp = record.get("timestamp")
        if record.get("type") == "session_meta" and not header:
            raw = record.get("payload") or {}
            header = {k: raw[k] for k in ("id", "session_id", "parent_thread_id", "agent_path", "agent_nickname", "cli_version", "model_provider", "thread_source") if k in raw}
        if record.get("type") == "turn_context":
            raw = record.get("payload") or {}
            if scalar(raw.get("model")):
                observations.append({"at": stamp, "model_id": scalar(raw["model"]), "turn_id": raw.get("turn_id"), "reasoning_effort": scalar(raw.get("effort")), "kind": "turn_context"})
        if record.get("type") == "assistant" and isinstance(record.get("message"), dict):
            msg = record["message"]
            model = scalar(msg.get("model"))
            if model and model != "<synthetic>":
                observations.append({"at": stamp, "model_id": model, "session_id": record.get("sessionId"), "agent_id": record.get("agentId"), "kind": "assistant_message", "tool_ids": [c.get("id") for c in msg.get("content", []) if isinstance(c, dict) and c.get("type") == "tool_use"]})
    return header, observations


def transcript_identity(payload: dict, identity: dict, *, full: bool = False) -> dict:
    path_text = scalar(field(payload, "transcript_path", "transcriptPath"))
    session = identity.get("session_id")
    thread = identity.get("thread_id")
    harness = identity.get("harness", "")
    # Never select the newest session globally or infer identity from cwd.
    if not path_text and harness == "codex":
        lookup_id = thread or session
        if lookup_id and re.fullmatch(r"[0-9a-fA-F-]{36}", lookup_id):
            root = Path(os.getenv("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions"
            matches = list(root.glob(f"*/*/*/*-{lookup_id}.jsonl"))
            if len(matches) == 1:
                path_text = str(matches[0])
    if not path_text:
        return {}
    path = Path(path_text)
    agent_id = identity.get("agent_id")
    if harness == "claude_code" and agent_id:
        # Claude hook transcript_path can point to the parent for a child agent.
        child = path.parent / path.stem / "subagents" / f"agent-{agent_id}.jsonl"
        if path.stem != f"agent-{agent_id}":
            if not child.is_file():
                matches = list((path.parent / path.stem / "subagents").glob(f"workflows/*/agent-{agent_id}.jsonl"))
                if len(matches) != 1:
                    return {"model_lookup": "subagent_transcript_missing"}
                child = matches[0]
            path = child
    try:
        stat = path.stat()
    except OSError:
        return {"model_lookup": "transcript_unavailable"}
    # A Codex turn_context is written once, before potentially long tool output.
    # The short Claude tail would lose model attribution during long Codex turns.
    header, observations = transcript_facts(str(path), stat.st_size, stat.st_mtime_ns, full or harness == "codex")
    result: dict[str, Any] = {}
    if header:
        matches = {str(header.get("id", "")), str(header.get("session_id", ""))}
        if (thread and thread != header.get("id")) or (session and session not in matches):
            return {"model_lookup": "transcript_identity_mismatch"}
        result = {"session_id": header.get("session_id") or header.get("id"), "thread_id": header.get("id"), "parent_thread_id": header.get("parent_thread_id"), "agent_path": header.get("agent_path"), "agent_name": header.get("agent_nickname"), "harness_version": header.get("cli_version"), "model_provider": header.get("model_provider"), "agent_type": header.get("thread_source")}
    cutoff = epoch(field(payload, "timestamp", "recorded_at")) or datetime.now(UTC).timestamp()
    tool_id = scalar(field(payload, "tool_use_id", "toolUseId"))
    turn_id = identity.get("turn_id")
    candidates = []
    for obs in observations:
        if epoch(obs.get("at")) is None or epoch(obs["at"]) > cutoff:
            continue
        if obs.get("session_id") and session and obs["session_id"] != session:
            continue
        if obs.get("agent_id") and agent_id and obs["agent_id"] != agent_id:
            continue
        if turn_id and obs.get("turn_id") and obs["turn_id"] != turn_id:
            continue
        candidates.append(obs)
    exact = [o for o in candidates if tool_id and tool_id in o.get("tool_ids", [])]
    if tool_id and harness == "claude_code" and not exact:
        result["model_lookup"] = "tool_model_unresolved"
        return {key: value for key, value in result.items() if value not in (None, "")}
    chosen = max(exact or candidates, key=lambda o: epoch(o["at"])) if candidates else None
    if chosen:
        result.update({"model_id": chosen["model_id"], "model_status": "observed", "model_source": f"transcript.{chosen['kind']}", "model_observed_at": chosen["at"], "model_evidence_path": str(path), "model_match": "tool_use_id" if exact else ("turn_id" if turn_id and chosen.get("turn_id") == turn_id else "latest_before_event")})
        if chosen.get("reasoning_effort"):
            result["reasoning_effort"] = chosen["reasoning_effort"]
    return {key: value for key, value in result.items() if value not in (None, "")}


def build_identity(payload: Any, *, agent: str = "", source: str = "", session_id: str = "", environ: Mapping[str, str] | None = None, full_transcript: bool = False) -> dict[str, Any]:
    payload = payload if isinstance(payload, dict) else {}
    env = os.environ if environ is None else environ
    supplied = field(payload.get("metadata"), "identity") or payload.get("identity") or {}
    identity: dict[str, Any] = {"schema_version": IDENTITY_VERSION, "agent_label": agent, "model_status": "unknown"}
    provenance = {}
    for key, aliases in ALIASES.items():
        value = scalar(field(supplied, *aliases)) or scalar(field(payload, *aliases))
        origin = "hook_payload" if value else "environment"
        value = value or scalar(env.get("AGENT_MEMORY_" + key.upper()))
        if value:
            identity[key] = value
            provenance[key] = origin
    if not identity.get("session_id") and session_id:
        identity["session_id"] = session_id
        provenance["session_id"] = "hook_argument"
    known = {"codex_hook": "codex", "claude_hook": "claude_code", "hermes_hook": "hermes"}
    if not identity.get("harness") and source in known:
        identity["harness"] = known[source]
        provenance["harness"] = "hook_source"
    if identity.get("harness") == "codex" and not identity.get("thread_id") and not field(payload, "transcript_path", "transcriptPath"):
        tid = scalar(env.get("CODEX_THREAD_ID"))
        if tid:
            identity["thread_id"] = tid
            provenance["thread_id"] = "environment.CODEX_THREAD_ID"
    reported_model = bool(identity.get("model_id"))
    facts = transcript_identity(payload, identity, full=full_transcript)
    for key, value in facts.items():
        if key not in identity or (key == "model_status" and not reported_model):
            identity[key] = value
            provenance[key] = "session_matched_transcript"
    if identity.get("model_id") and provenance.get("model_id") in ("hook_payload", "environment"):
        identity["model_status"] = "reported" if provenance["model_id"] == "hook_payload" else "configured"
        identity["model_source"] = provenance["model_id"]
        # Do not attach evidence for a different transcript model to reported metadata.
        if facts.get("model_id") != identity["model_id"]:
            for key in ("model_observed_at", "model_evidence_path", "model_match"):
                identity.pop(key, None)
                provenance.pop(key, None)
    identity["provenance"] = provenance
    identity["ingestion_host"] = socket.gethostname()
    actor_parts = [identity.get("harness"), identity.get("thread_id") or identity.get("session_id"), identity.get("agent_id")]
    if actor_parts[0] and actor_parts[1]:
        identity["actor_key"] = ":".join(part for part in actor_parts if part)
    return identity
