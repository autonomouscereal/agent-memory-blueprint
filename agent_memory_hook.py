#!/usr/bin/env python3
"""
Async hook adapter for the PostgreSQL-only agent memory backend.

Reads hook JSON from stdin first, then argv fallback. Errors are logged and the
hook exits zero so memory failures never break the agent harness.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import sys
import time
import zlib
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from agent_memory import LOG_DIR, add_event_async, archive_payload_async, connect, json_default, normalize_space, parse_json_arg
from agent_identity import build_identity


SENSITIVE_EXACT_KEYS = {
    "api_key",
    "apikey",
    "auth",
    "auth_token",
    "authorization",
    "bearer",
    "client_secret",
    "connection_uri",
    "cookie",
    "credentials",
    "dsn",
    "passphrase",
    "passwd",
    "password",
    "private_key",
    "proxy_authorization",
    "refresh_token",
    "secret",
    "set_cookie",
    "token",
    "access_token",
}
SENSITIVE_KEY_SUFFIXES = (
    "_api_key",
    "_auth_token",
    "_client_secret",
    "_credential",
    "_credentials",
    "_passphrase",
    "_passwd",
    "_password",
    "_private_key",
    "_refresh_token",
    "_secret",
    "_access_token",
)
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?i)([\"']?(?:api[_-]?key|apikey|auth[_-]?token|authorization|client[_-]?secret|connection[_-]?uri|"
    r"credentials?|dsn|passphrase|passwd|password|private[_-]?key|proxy[_-]?authorization|refresh[_-]?token|"
    r"secret|access[_-]?token|token)[\"']?\s*[:=]\s*[\"']?)([^\s,;\"'}]{4,})"
)
AUTH_HEADER_RE = re.compile(
    r"(?i)((?:authorization|proxy-authorization)\s*[:=]\s*(?:(?:bearer|basic)\s+)?)([A-Za-z0-9._~+/=-]{8,})"
)
COOKIE_HEADER_RE = re.compile(r"(?i)((?:cookie|set-cookie)\s*[:=]\s*)([^\r\n]{4,})")
CREDENTIAL_URL_RE = re.compile(r"(?i)(\b[a-z][a-z0-9+.-]*://[^\s:/@]+:)([^\s@/]+)(@)")
PEM_PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----",
    re.DOTALL,
)
JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
PROVIDER_TOKEN_RE = re.compile(
    r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b"
)
DATA_URL_RE = re.compile(r"^data:([^;,]+)?(?:;[^,]*)?,", re.IGNORECASE)
MAX_HOOK_STRING_CHARS = int(os.getenv("AGENT_MEMORY_HOOK_MAX_STRING_CHARS", "12000"))
MAX_HOOK_CONTENT_CHARS = int(os.getenv("AGENT_MEMORY_HOOK_MAX_CONTENT_CHARS", "60000"))
MAX_HOOK_LIST_ITEMS = int(os.getenv("AGENT_MEMORY_HOOK_MAX_LIST_ITEMS", "50"))
PENDING_DIR = Path(os.getenv("AGENT_MEMORY_PENDING_DIR", str(LOG_DIR / "pending")))
HOOK_CONNECT_ATTEMPTS = max(1, min(int(os.getenv("AGENT_MEMORY_HOOK_CONNECT_ATTEMPTS", "2")), 5))
HOOK_CONNECT_TIMEOUT = max(1.0, min(float(os.getenv("AGENT_MEMORY_HOOK_CONNECT_TIMEOUT", "4")), 30.0))
HOOK_STATEMENT_TIMEOUT_MS = max(1000, min(int(os.getenv("AGENT_MEMORY_HOOK_STATEMENT_TIMEOUT_MS", "15000")), 60000))
HOOK_LOCK_TIMEOUT_MS = max(500, min(int(os.getenv("AGENT_MEMORY_HOOK_LOCK_TIMEOUT_MS", "3000")), 30000))
HOOK_REPLAY_LIMIT = max(0, min(int(os.getenv("AGENT_MEMORY_HOOK_REPLAY_LIMIT", "1")), 20))


def audit_safe_text(text: str, limit: int | None = 4000) -> str:
    """Keep hook payload text UTF-8 safe without dropping audit content."""
    if not text:
        return ""
    value = text if limit is None else text[:limit]
    value = value.replace("\x00", "\\x00")
    return value.encode("utf-8", errors="backslashreplace").decode("utf-8")


def truncate_with_digest(text: str, limit: int | None, label: str) -> str:
    if limit is None or len(text) <= limit:
        return text
    digest = hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()
    return f"{text[:limit]}\n<agent-memory {label}: original_chars={len(text)} sha256={digest}>"


def is_sensitive_key(key: Any) -> bool:
    normalized = re.sub(r"[^a-z0-9]+", "_", str(key).strip().lower()).strip("_")
    return normalized in SENSITIVE_EXACT_KEYS or normalized.endswith(SENSITIVE_KEY_SUFFIXES)


def redact_secret_text(text: str) -> str:
    value = audit_safe_text(text, None)
    value = PEM_PRIVATE_KEY_RE.sub("<redacted-private-key>", value)
    value = CREDENTIAL_URL_RE.sub(r"\1<redacted>\3", value)
    value = AUTH_HEADER_RE.sub(r"\1<redacted>", value)
    value = COOKIE_HEADER_RE.sub(r"\1<redacted>", value)
    value = SECRET_ASSIGNMENT_RE.sub(r"\1<redacted>", value)
    value = JWT_RE.sub("<redacted-token>", value)
    value = PROVIDER_TOKEN_RE.sub("<redacted-token>", value)
    return value


def redact_text(text: str, limit: int = 4000) -> str:
    if not text:
        return ""
    redacted = redact_secret_text(text)
    return truncate_with_digest(redacted, limit, "text truncated")


def redact_full_text(text: str) -> str:
    if not text:
        return ""
    return redact_secret_text(text)


def sanitize_text(text: str) -> str:
    safe = audit_safe_text(text, None)
    match = DATA_URL_RE.match(safe)
    if match and len(safe) > 512:
        digest = hashlib.sha256(safe.encode("utf-8", errors="replace")).hexdigest()
        mime = match.group(1) or "unknown"
        return f"<agent-memory data-url omitted: mime={mime} original_chars={len(safe)} sha256={digest}>"
    return redact_text(safe, MAX_HOOK_STRING_CHARS)


def sanitize_value(value: Any) -> Any:
    if isinstance(value, dict):
        clean = {}
        for key, item in value.items():
            if is_sensitive_key(key):
                clean[key] = "<redacted>"
            else:
                clean[key] = sanitize_value(item)
        return clean
    if isinstance(value, list):
        clean = [sanitize_value(item) for item in value[:MAX_HOOK_LIST_ITEMS]]
        if len(value) > MAX_HOOK_LIST_ITEMS:
            clean.append({"omitted_items": len(value) - MAX_HOOK_LIST_ITEMS})
        return clean
    if isinstance(value, str):
        return sanitize_text(value)
    return value


def sanitize_value_for_archive(value: Any) -> Any:
    if isinstance(value, dict):
        clean = {}
        for key, item in value.items():
            if is_sensitive_key(key):
                clean[key] = "<redacted>"
            else:
                clean[key] = sanitize_value_for_archive(item)
        return clean
    if isinstance(value, list):
        return [sanitize_value_for_archive(item) for item in value]
    if isinstance(value, str):
        return redact_full_text(value)
    return value


def safe_log(filename: str, record: dict[str, Any]) -> None:
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        append_jsonl_locked(LOG_DIR / filename, record)
    except Exception:
        pass


def append_jsonl_locked(path: Path, record: dict[str, Any]) -> None:
    line = json.dumps(record, ensure_ascii=False, default=json_default, sort_keys=True) + "\n"
    with path.open("a+", encoding="utf-8", newline="\n") as handle:
        locked = False
        if os.name == "nt":
            import msvcrt

            for _ in range(100):
                try:
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    locked = True
                    break
                except OSError:
                    time.sleep(0.01)
        else:
            try:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                locked = True
            except (ImportError, OSError):
                locked = False
        if not locked:
            raise OSError(f"could not acquire JSONL lock: {path}")
        try:
            handle.seek(0, os.SEEK_END)
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            if locked:
                try:
                    if os.name == "nt":
                        import msvcrt

                        handle.seek(0)
                        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                    else:
                        import fcntl

                        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                except Exception:
                    pass


def parse_payload(raw: str) -> tuple[Any, str]:
    raw = raw.lstrip("\ufeff").strip()
    if not raw:
        return {}, ""
    try:
        return json.loads(raw), raw
    except json.JSONDecodeError:
        try:
            return json.loads(raw.replace('\\"', '"')), raw
        except json.JSONDecodeError:
            lax = parse_json_arg(raw, None)
            if isinstance(lax, dict):
                return lax, raw
            return {"raw": raw}, raw


HOOK_PAYLOAD_ALIASES: dict[str, tuple[str, ...]] = {
    "hook_event_name": ("hook_event_name", "hookEventName"),
    "session_id": ("session_id", "sessionId", "conversation_id", "conversationId"),
    "thread_id": ("thread_id", "threadId", "thread-id"),
    "tool_name": ("tool_name", "toolName"),
    "tool_use_id": ("tool_use_id", "toolUseId"),
    "call_id": ("call_id", "callId"),
    "turn_id": ("turn_id", "turnId", "turn-id"),
    "agent_id": ("agent_id", "agentId"),
    "duration_ms": ("duration_ms", "durationMs"),
    "status": ("status",),
    "transcript_path": ("transcript_path", "transcriptPath"),
    "cwd": ("cwd",),
    "workspace_root": ("workspace_root", "workspaceRoot"),
    "timestamp": ("timestamp",),
}


def payload_field(payload: Any, canonical_name: str) -> Any:
    if not isinstance(payload, dict):
        return None
    for key in HOOK_PAYLOAD_ALIASES.get(canonical_name, (canonical_name,)):
        if key in payload and payload[key] not in (None, ""):
            return payload[key]
    return None


def extract_text(payload: Any) -> str:
    if isinstance(payload, dict):
        for keys in (
            ("prompt", "userPrompt"),
            ("message", "userMessage"),
            ("content",),
            ("last_assistant_message", "lastAssistantMessage"),
        ):
            value = next((payload[key] for key in keys if payload.get(key) not in (None, "")), None)
            if isinstance(value, str) and value.strip():
                return redact_text(value, MAX_HOOK_CONTENT_CHARS)
        if "payload" in payload:
            nested = extract_text(payload["payload"])
            if nested:
                return nested
    serialized = json.dumps(payload, ensure_ascii=False, indent=2, default=json_default)
    return truncate_with_digest(serialized, MAX_HOOK_CONTENT_CHARS, "content truncated")


def normalize_event(event: str) -> tuple[str, str]:
    mapping = {
        "UserPromptSubmit": ("user_prompt", "user"),
        "SessionStart": ("session_start", "system"),
        "PreToolUse": ("tool_start", "tool"),
        "AssistantMessage": ("assistant_message", "assistant"),
        "PostToolUse": ("tool_call", "tool"),
        "PostToolUseFailure": ("tool_call_failure", "tool"),
        "Stop": ("session_stop", "assistant"),
        "StopFailure": ("stop_failure", "system"),
        "SessionEnd": ("session_end", "system"),
        "PreCompact": ("pre_compact", "system"),
    }
    return mapping.get(event, (event.lower(), "system"))


def build_metadata(args: argparse.Namespace, payload: Any) -> dict[str, Any]:
    metadata = {
        "hook_event": args.event,
        "cwd": os.getcwd(),
        "recorded_at": datetime.now(UTC).isoformat(),
    }
    if isinstance(payload, dict):
        for canonical_name in (
            "tool_name",
            "tool_use_id",
            "call_id",
            "turn_id",
            "agent_id",
            "duration_ms",
            "status",
            "transcript_path",
            "cwd",
            "workspace_root",
            "timestamp",
        ):
            value = payload_field(payload, canonical_name)
            if value is not None:
                metadata[canonical_name] = sanitize_value(value)
    metadata["identity"] = sanitize_value(build_identity(
        payload, agent=args.agent, source=args.source,
        session_id=str(payload_field(payload, "session_id") or args.session_id or ""),
    ))
    return metadata


def configured_workspace_spaces() -> list[tuple[str, str]]:
    """Parse AGENT_MEMORY_WORKSPACE_SPACES="dir-name=space,other-dir=team/space"."""
    rules: list[tuple[str, str]] = []
    for item in os.getenv("AGENT_MEMORY_WORKSPACE_SPACES", "").split(","):
        name, separator, space = item.partition("=")
        if separator and name.strip() and space.strip():
            rules.append((name.strip().lower(), space.strip()))
    return rules


def derive_space(args: argparse.Namespace, payload: Any) -> str:
    if args.space:
        return normalize_space(args.space)
    env_space = os.getenv("AGENT_MEMORY_SPACE", "").strip()
    if env_space:
        return normalize_space(env_space)
    cwd = ""
    if isinstance(payload, dict):
        cwd = str(payload_field(payload, "cwd") or payload_field(payload, "workspace_root") or "")
        if not cwd:
            raw_payload = payload.get("raw_payload")
            cwd = str(payload_field(raw_payload, "cwd") or payload_field(raw_payload, "workspace_root") or "")
    cwd = cwd or os.getcwd()
    normalized = cwd.replace("\\", "/").strip("/")
    parts = [part for part in normalized.split("/") if part]
    lowered = [part.lower() for part in parts]
    if "codex" in lowered:
        idx = lowered.index("codex")
        tail = parts[idx + 1 : idx + 4]
        if tail:
            return normalize_space("codex/" + "/".join(tail))
    for name, space in configured_workspace_spaces():
        if name in lowered:
            return normalize_space(space)
    if parts:
        return normalize_space("workspace/" + parts[-1])
    return "global"


def make_hook_event_uid(
    *,
    agent: str,
    source: str,
    event_type: str,
    session_id: str,
    payload_sha256: str,
) -> str:
    seed = "\x00".join(("agent-memory-hook-v2", agent, source, event_type, session_id, payload_sha256))
    return hashlib.sha256(seed.encode("utf-8", errors="backslashreplace")).hexdigest()


def pending_status() -> dict[str, Any]:
    PENDING_DIR.mkdir(parents=True, exist_ok=True)
    pending = list(PENDING_DIR.glob("*.pending.zlib"))
    processing = list(PENDING_DIR.glob("*.processing.*.zlib"))
    corrupt = list(PENDING_DIR.glob("*.corrupt.zlib"))
    files = pending + processing + corrupt
    return {
        "ok": True,
        "pending_dir": str(PENDING_DIR),
        "pending": len(pending),
        "processing": len(processing),
        "corrupt": len(corrupt),
        "compressed_bytes": sum(path.stat().st_size for path in files if path.exists()),
    }


def spool_pending(record: dict[str, Any]) -> str:
    PENDING_DIR.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(record, ensure_ascii=True, separators=(",", ":"), default=json_default).encode("utf-8")
    compressed = zlib.compress(raw, level=6)
    digest = hashlib.sha256(raw).hexdigest()
    stem = f"{time.time_ns()}-{os.getpid()}-{digest[:16]}"
    final_path = PENDING_DIR / f"{stem}.pending.zlib"
    temp_path = PENDING_DIR / f"{stem}.tmp"
    with temp_path.open("xb") as handle:
        handle.write(compressed)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_path, final_path)
    return str(final_path)


def recover_stale_processing(max_age_seconds: int = 300) -> int:
    if not PENDING_DIR.exists():
        return 0
    recovered = 0
    cutoff = time.time() - max_age_seconds
    for path in PENDING_DIR.glob("*.processing.*.zlib"):
        try:
            if path.stat().st_mtime > cutoff:
                continue
            stem = re.sub(r"\.processing\.\d+\.zlib$", "", path.name)
            target = PENDING_DIR / f"{stem}.pending.zlib"
            if not target.exists():
                path.replace(target)
                recovered += 1
        except OSError:
            continue
    return recovered


def claim_pending(path: Path) -> Path | None:
    stem = re.sub(r"\.pending\.zlib$", "", path.name)
    claimed = path.with_name(f"{stem}.processing.{os.getpid()}.zlib")
    try:
        path.replace(claimed)
        return claimed
    except OSError:
        return None


def load_pending(path: Path) -> dict[str, Any]:
    raw = zlib.decompress(path.read_bytes())
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("event"), dict) or not isinstance(value.get("archive"), dict):
        raise ValueError("invalid pending hook record")
    return value


async def connect_for_hook():
    last_error: Exception | None = None
    for attempt in range(HOOK_CONNECT_ATTEMPTS):
        try:
            return await asyncio.wait_for(connect(), timeout=HOOK_CONNECT_TIMEOUT)
        except Exception as exc:
            last_error = exc
            if attempt + 1 < HOOK_CONNECT_ATTEMPTS:
                await asyncio.sleep(min(0.2 * (2**attempt), 1.0))
    assert last_error is not None
    raise last_error


async def store_hook_record(record: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    event = record["event"]
    archive = record["archive"]
    conn = await connect_for_hook()
    try:
        await conn.execute(f"SET statement_timeout = {HOOK_STATEMENT_TIMEOUT_MS}")
        await conn.execute(f"SET lock_timeout = {HOOK_LOCK_TIMEOUT_MS}")
        await conn.execute(f"SET idle_in_transaction_session_timeout = {HOOK_STATEMENT_TIMEOUT_MS + 5000}")
        async with conn.transaction():
            result = await add_event_async(
                agent=str(event["agent"]),
                event_type=str(event["event_type"]),
                space=str(event["space"]),
                memory_kind="hook",
                role=str(event.get("role") or ""),
                source=str(event.get("source") or ""),
                session_id=str(event.get("session_id") or ""),
                content=str(event.get("content") or ""),
                tags=[str(item) for item in event.get("tags") or []],
                metadata=dict(event.get("metadata") or {}),
                event_uid=str(event["event_uid"]),
                index_entities=False,
                conn=conn,
            )
            archive_result = await archive_payload_async(
                event_id=result["id"],
                event_uid=result["event_uid"],
                payload=str(archive.get("payload") or ""),
                payload_kind="hook_payload",
                payload_format=str(archive.get("payload_format") or "json"),
                redacted=True,
                space=str(event["space"]),
                session_id=str(event.get("session_id") or ""),
                agent=str(event["agent"]),
                event_type=str(event["event_type"]),
                source=str(event.get("source") or ""),
                metadata=dict(archive.get("metadata") or {}),
                conn=conn,
            )
        return result, archive_result
    finally:
        await conn.close()


async def replay_pending_async(limit: int = 100) -> dict[str, Any]:
    PENDING_DIR.mkdir(parents=True, exist_ok=True)
    recovered = recover_stale_processing()
    replayed = 0
    failed = 0
    last_error = ""
    for path in sorted(PENDING_DIR.glob("*.pending.zlib"), key=lambda item: item.name)[: max(0, limit)]:
        claimed = claim_pending(path)
        if claimed is None:
            continue
        try:
            record = load_pending(claimed)
            result, archive_result = await store_hook_record(record)
            claimed.unlink(missing_ok=True)
            replayed += 1
            safe_log(
                "agent_memory_hook_replays.jsonl",
                {
                    "ok": True,
                    "created_at": datetime.now(UTC).isoformat(),
                    "memory_id": result.get("id"),
                    "archive_id": archive_result.get("id"),
                    "event_uid": result.get("event_uid"),
                    "source_file": claimed.name,
                },
            )
        except Exception as exc:
            failed += 1
            last_error = f"{type(exc).__name__}: {exc}"
            original_stem = re.sub(r"\.processing\.\d+\.zlib$", "", claimed.name)
            original = PENDING_DIR / f"{original_stem}.pending.zlib"
            try:
                if claimed.exists() and not original.exists():
                    claimed.replace(original)
            except OSError:
                pass
            break
    status = pending_status()
    return {
        "ok": failed == 0,
        "replayed": replayed,
        "failed": failed,
        "recovered_stale": recovered,
        "remaining": status["pending"],
        "last_error": last_error,
    }


async def run_hook(args: argparse.Namespace, raw: str, started: float) -> int:
    payload, raw_payload = parse_payload(raw)
    if not args.event and isinstance(payload, dict):
        args.event = str(payload_field(payload, "hook_event_name") or "")
    event_type, role = normalize_event(args.event)
    session_id = args.session_id
    if isinstance(payload, dict):
        session_id = str(payload_field(payload, "session_id") or session_id or "")

    archive_payload = sanitize_value_for_archive(payload) if isinstance(payload, dict) else redact_full_text(raw_payload)
    archive_text = json.dumps(archive_payload, ensure_ascii=False, default=json_default) if not isinstance(archive_payload, str) else archive_payload
    archive_sha256 = hashlib.sha256(archive_text.encode("utf-8", errors="backslashreplace")).hexdigest()
    clean_payload = sanitize_value(payload)
    content = extract_text(clean_payload)
    metadata = build_metadata(args, clean_payload)
    session_id = session_id or str(metadata["identity"].get("session_id") or "")
    space = derive_space(args, clean_payload)
    event_uid = make_hook_event_uid(
        agent=args.agent,
        source=args.source,
        event_type=event_type,
        session_id=session_id,
        payload_sha256=archive_sha256,
    )
    metadata["memory_space"] = space
    metadata["trace_archive"] = {
        "stored": True,
        "payload_sha256": archive_sha256,
        "payload_chars": len(archive_text),
        "redacted": True,
        "redaction_version": "v2-structured-20260710",
        "compression": "zlib",
    }
    record = {
        "version": 1,
        "created_at": datetime.now(UTC).isoformat(),
        "event": {
            "event_uid": event_uid,
            "agent": args.agent,
            "event_type": event_type,
            "space": space,
            "role": role,
            "source": args.source,
            "session_id": session_id,
            "content": content,
            "tags": [args.agent, event_type, args.source, "asyncpg", space],
            "metadata": metadata,
        },
        "archive": {
            "payload": archive_text,
            "payload_format": "json" if isinstance(archive_payload, (dict, list)) else "text",
            "metadata": {
                "hook_event": args.event,
                "payload_sha256": archive_sha256,
                "redaction_version": "v2-structured-20260710",
                "identity": metadata["identity"],
            },
        },
    }

    try:
        result, archive_result = await store_hook_record(record)
        replay_result = {"replayed": 0, "remaining": pending_status()["pending"]}
        if HOOK_REPLAY_LIMIT > 0 and replay_result["remaining"]:
            try:
                replay_result = await replay_pending_async(HOOK_REPLAY_LIMIT)
            except Exception:
                pass
        safe_log(
            "agent_memory_hook_events.jsonl",
            {
                "ok": True,
                "created_at": datetime.now(UTC).isoformat(),
                "duration_ms": round((time.monotonic() - started) * 1000, 2),
                "event": args.event,
                "event_type": event_type,
                "agent": args.agent,
                "source": args.source,
                "space": space,
                "session_id": session_id,
                "identity": metadata["identity"],
                "memory_id": result["id"],
                "inserted": result.get("inserted"),
                "archive_id": archive_result.get("id"),
                "archive_inserted": archive_result.get("inserted"),
                "archive_payload_sha256": archive_result.get("payload_sha256"),
                "archive_raw_chars": archive_result.get("raw_chars"),
                "archive_compressed_bytes": archive_result.get("compressed_bytes"),
                "event_uid": event_uid,
                "replayed_pending": replay_result.get("replayed", 0),
                "pending_remaining": replay_result.get("remaining", 0),
                "content_sha256": hashlib.sha256(content.encode("utf-8", errors="replace")).hexdigest(),
                "payload_chars": len(raw or ""),
                "driver": "asyncpg",
                "pid": os.getpid(),
            },
        )
        if args.emit_json:
            print(json.dumps({"continue": True, "suppressOutput": True}, ensure_ascii=False))
        return 0
    except Exception as exc:
        pending_file = ""
        spool_error = ""
        try:
            pending_file = spool_pending(record)
        except Exception as spool_exc:
            spool_error = f"{type(spool_exc).__name__}: {spool_exc}"
        safe_log(
            "agent_memory_hook_errors.jsonl",
            {
                "ok": False,
                "created_at": datetime.now(UTC).isoformat(),
                "duration_ms": round((time.monotonic() - started) * 1000, 2),
                "event": args.event,
                "agent": args.agent,
                "source": args.source,
                "space": space,
                "session_id": session_id,
                "error_type": type(exc).__name__,
                "error": str(exc),
                "spooled": bool(pending_file),
                "pending_file": pending_file,
                "spool_error": spool_error,
                "payload_excerpt": redact_text(raw or "", 1200),
                "payload_sha256": hashlib.sha256((raw or "").encode("utf-8", errors="replace")).hexdigest(),
                "archive_payload_sha256": archive_sha256,
                "driver": "asyncpg",
                "pid": os.getpid(),
            },
        )
        if args.emit_json:
            print(json.dumps({"continue": True, "suppressOutput": True}, ensure_ascii=False))
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Record harness hook payload in async agent memory")
    parser.add_argument("--event", default="")
    parser.add_argument("--agent", default=os.getenv("AGENT_MEMORY_AGENT", "agent"))
    parser.add_argument("--source", default="hook")
    parser.add_argument("--space", default=os.getenv("AGENT_MEMORY_SPACE", ""))
    parser.add_argument("--session-id", default=os.getenv("CLAUDE_CODE_SESSION_ID", os.getenv("AGENT_MEMORY_SESSION_ID", "")))
    parser.add_argument("--emit-json", action="store_true", help="Emit Codex/Claude hook-control JSON for explicit tests only")
    parser.add_argument("--pending-status", action="store_true", help="Show the durable failed-hook spool status")
    parser.add_argument("--replay-pending", action="store_true", help="Replay durable failed-hook spool files")
    parser.add_argument("--limit", type=int, default=100, help="Maximum pending files to replay")
    parser.add_argument("payload", nargs="*")
    return parser


def main() -> int:
    started = time.monotonic()
    args = build_parser().parse_args()
    if args.pending_status:
        print(json.dumps(pending_status(), indent=2, ensure_ascii=False))
        return 0
    if args.replay_pending:
        result = asyncio.run(replay_pending_async(max(0, min(args.limit, 100000))))
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result["ok"] else 2
    stdin_raw = ""
    if not sys.stdin.isatty():
        stdin_raw = sys.stdin.read()
    argv_raw = " ".join(args.payload).strip()
    raw = stdin_raw.strip() or argv_raw
    if not args.event:
        payload, _ = parse_payload(raw)
        if isinstance(payload, dict):
            args.event = str(payload_field(payload, "hook_event_name") or "")
    if not args.event:
        raise SystemExit("--event is required unless the hook payload names its event")
    return asyncio.run(run_hook(args, raw, started))


if __name__ == "__main__":
    raise SystemExit(main())
