#!/usr/bin/env python3
"""Warm writer for hook events spooled by agent_memory_spool_hook.py.

One instance per machine (an exclusive lock on logs/writer.lock). It decrypts
the database credential once, keeps one asyncpg connection open, and drains
logs/inbox/*.hook in file-name (fire time) order. Each event and its full
redacted archive commit in one transaction, built by the same
build_hook_record() the synchronous hook uses, with the cwd, environment and
fire time the hook process captured. A spool file is deleted only after its
transaction commits.

Failures keep data:
- database unreachable: the file stays in the inbox and the writer retries
  with backoff;
- the same event fails 3 times with a database error: it moves to the
  existing logs/pending zlib spool (replayed later, and by --replay-pending);
- a spool file that cannot be parsed or built: it moves to logs/inbox/bad/
  with an error-log line, so it can be replayed after a fix.

Raw SQL through asyncpg only. The credential never reaches argv, logs or
output.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
SPOOL_ROOT = BACKEND_DIR / "logs"
INBOX_DIR = SPOOL_ROOT / "inbox"
BAD_DIR = INBOX_DIR / "bad"
SHADOW_DIR = SPOOL_ROOT / "inbox-shadow"
SHADOW_CHECK_EVERY_S = 1.0
SHADOW_MAX_WAIT_S = 180.0
LOCK_PATH = SPOOL_ROOT / "writer.lock"
HEARTBEAT_PATH = SPOOL_ROOT / "writer.heartbeat"
POLL_S = float(os.getenv("AGENT_MEMORY_WRITER_POLL_S", "0.05"))
HEARTBEAT_EVERY_S = 5.0
SOURCE_CHECK_EVERY_S = 10.0
PENDING_REPLAY_EVERY_S = 30.0
MAX_EVENT_ATTEMPTS = 3


def acquire_lock():
    """Hold the single-instance lock for this process's lifetime, or None."""
    SPOOL_ROOT.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(LOCK_PATH), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


LOCK_FD = acquire_lock() if __name__ == "__main__" else None
if __name__ == "__main__" and LOCK_FD is None:
    sys.exit(0)  # Another writer is running.

import asyncio  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import traceback  # noqa: E402
from datetime import UTC, datetime  # noqa: E402
from typing import Any  # noqa: E402

sys.path.insert(0, str(BACKEND_DIR))
import asyncpg  # noqa: E402

import agent_memory as am  # noqa: E402
import agent_memory_hook as amh  # noqa: E402

SOURCE_FILES = [BACKEND_DIR / name for name in (
    "agent_memory_writer.py", "agent_memory_hook.py", "agent_memory.py", "agent_identity.py", ".env",
)]
CONNECTION_ERRORS = (
    OSError,
    asyncio.TimeoutError,
    TimeoutError,
    asyncpg.PostgresConnectionError,
    asyncpg.InterfaceError,
    asyncpg.ConnectionDoesNotExistError,
    asyncpg.CannotConnectNowError,
)


def now_iso() -> str:
    return datetime.now(UTC).isoformat()


def writer_log(record: dict[str, Any]) -> None:
    record.setdefault("created_at", now_iso())
    record.setdefault("pid", os.getpid())
    amh.safe_log("agent_memory_writer.jsonl", record)


def write_heartbeat() -> None:
    try:
        temp = HEARTBEAT_PATH.with_suffix(".tmp")
        temp.write_text(f"{os.getpid()} {time.time():.3f}\n", encoding="ascii")
        os.replace(temp, HEARTBEAT_PATH)
    except OSError:
        pass


def source_stamp() -> tuple:
    stamp = []
    for path in SOURCE_FILES:
        try:
            info = path.stat()
            stamp.append((path.name, info.st_mtime_ns, info.st_size))
        except OSError:
            stamp.append((path.name, 0, 0))
    return tuple(stamp)


def list_inbox(directory: Path = INBOX_DIR) -> list[Path]:
    try:
        with os.scandir(directory) as entries:
            names = sorted(entry.name for entry in entries if entry.name.endswith(".hook") and entry.is_file())
    except FileNotFoundError:
        return []
    return [directory / name for name in names]


def base_environment() -> dict[str, str]:
    """This writer's MEMORY_*/AGENT_MEMORY_* values, which come from .env."""
    return {key: value for key, value in os.environ.items() if key.startswith(("AGENT_MEMORY_", "MEMORY_"))}


def read_spool(path: Path) -> tuple[dict[str, Any], bytes]:
    data = path.read_bytes()
    newline = data.index(b"\n")
    header = json.loads(data[:newline].decode("ascii"))
    raw = data[newline + 1:]
    if not isinstance(header, dict) or header.get("v") != 1 or not isinstance(header.get("argv"), list):
        raise ValueError("unsupported spool header")
    if int(header.get("raw_len", -1)) != len(raw):
        raise ValueError("spool payload length mismatch")
    return header, raw


def build_from_spool(header: dict[str, Any], raw_bytes: bytes) -> tuple[Any, dict[str, Any]]:
    environ = base_environment()
    environ.update({str(k): str(v) for k, v in (header.get("env") or {}).items()})
    parser = amh.build_parser(environ=environ)
    try:
        args = parser.parse_args([str(item) for item in header["argv"]])
    except SystemExit as exc:
        raise ValueError(f"hook argv rejected: {header['argv']!r}") from exc
    # Same text the synchronous hook reads: UTF-8 stdin in text mode, so
    # universal newlines; undecodable bytes survive as surrogate escapes.
    text = raw_bytes.decode("utf-8", errors="surrogateescape").replace("\r\n", "\n").replace("\r", "\n")
    raw = amh.resolve_hook_input(args, text)
    if not args.event:
        raise ValueError("hook payload names no event and argv has no --event")
    received_at = datetime.fromtimestamp(int(header["received_ns"]) / 1e9, UTC)
    built = amh.build_hook_record(args, raw, cwd=str(header.get("cwd") or ""), environ=environ, received_at=received_at)
    return args, built


def quarantine(path: Path, reason: str) -> None:
    BAD_DIR.mkdir(parents=True, exist_ok=True)
    target = BAD_DIR / path.name
    try:
        os.replace(path, target)
    except OSError:
        target = path
    amh.safe_log("agent_memory_hook_errors.jsonl", {
        "ok": False,
        "created_at": now_iso(),
        "writer": "warm",
        "error_type": "SpoolRecordRejected",
        "error": reason[-4000:],
        "spool_file": str(target),
        "spooled": True,
        "pid": os.getpid(),
    })


class Writer:
    def __init__(self) -> None:
        self.conn: asyncpg.Connection | None = None
        self.config: dict[str, Any] | None = None
        self.attempts: dict[str, int] = {}
        self.read_attempts: dict[str, int] = {}
        self.committed: set[str] = set()
        self.backoff = 0.0
        self.started = time.monotonic()
        self.written = 0

    async def connection(self) -> asyncpg.Connection:
        if self.conn is not None and not self.conn.is_closed():
            return self.conn
        if self.config is None or not self.config.get("password"):
            # One credential-helper run per writer; cached only in memory.
            self.config = am.db_config()
        config = dict(self.config)
        config["timeout"] = amh.HOOK_CONNECT_TIMEOUT
        conn = await asyncio.wait_for(asyncpg.connect(**config), timeout=amh.HOOK_CONNECT_TIMEOUT + 2)
        try:
            for name in ("jsonb", "json"):
                await conn.set_type_codec(
                    name,
                    encoder=lambda value: json.dumps(value, ensure_ascii=False, default=am.json_default),
                    decoder=json.loads,
                    schema="pg_catalog",
                )
            await amh.apply_hook_session_settings(conn)
        except BaseException:
            conn.terminate()
            raise
        self.conn = conn
        writer_log({"ok": True, "event": "connected"})
        return conn

    def drop_connection(self) -> None:
        if self.conn is not None:
            try:
                self.conn.terminate()
            except Exception:
                pass
        self.conn = None

    def remove(self, path: Path) -> None:
        """Delete a committed spool file. A file another process holds open
        (antivirus, indexer) is retried on later passes, never rewritten."""
        for _ in range(5):
            try:
                path.unlink(missing_ok=True)
                self.committed.discard(path.name)
                return
            except OSError:
                time.sleep(0.05)
        self.committed.add(path.name)

    async def process(self, path: Path) -> str:
        """Write one spool file: "done", "deferred" (retry later) or "stop"."""
        if path.name in self.committed:
            self.remove(path)
            return "deferred" if path.name in self.committed else "done"
        try:
            header, raw = read_spool(path)
        except FileNotFoundError:
            return "done"
        except OSError as exc:
            # Windows sharing violation while a scanner holds the new file.
            attempts = self.read_attempts.get(path.name, 0) + 1
            self.read_attempts[path.name] = attempts
            if attempts == 1 or attempts % 50 == 0:
                writer_log({"ok": False, "event": "read_deferred", "spool_file": path.name, "attempt": attempts,
                            "error_type": type(exc).__name__, "error": str(exc)[:300]})
            return "deferred"
        except Exception as exc:
            quarantine(path, f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
            return "done"
        self.read_attempts.pop(path.name, None)
        try:
            args, built = build_from_spool(header, raw)
        except Exception as exc:
            quarantine(path, f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
            return "done"
        record = built["record"]
        started = time.monotonic()
        try:
            conn = await self.connection()
            result, archive_result = await asyncio.wait_for(
                amh.write_hook_record(conn, record),
                timeout=amh.HOOK_STATEMENT_TIMEOUT_MS / 1000 * 2 + 5,
            )
        except CONNECTION_ERRORS as exc:
            self.drop_connection()
            self.backoff = min(max(self.backoff * 2, 0.5), 10.0)
            writer_log({"ok": False, "event": "connection_error", "error_type": type(exc).__name__,
                        "error": str(exc)[:500], "backoff_s": self.backoff})
            return "stop"
        except Exception as exc:
            attempts = self.attempts.get(path.name, 0) + 1
            self.attempts[path.name] = attempts
            if self.conn is not None and self.conn.is_in_transaction():
                self.drop_connection()
            if attempts < MAX_EVENT_ATTEMPTS:
                self.backoff = min(max(self.backoff * 2, 0.5), 10.0)
                writer_log({"ok": False, "event": "write_retry", "attempt": attempts, "spool_file": path.name,
                            "error_type": type(exc).__name__, "error": str(exc)[:500]})
                return "stop"
            pending_file = amh.spool_pending(record)
            self.remove(path)
            self.attempts.pop(path.name, None)
            amh.safe_log("agent_memory_hook_errors.jsonl", {
                "ok": False,
                "created_at": now_iso(),
                "writer": "warm",
                "event": args.event,
                "agent": args.agent,
                "source": args.source,
                "space": built["space"],
                "session_id": built["session_id"],
                "error_type": type(exc).__name__,
                "error": str(exc),
                "spooled": True,
                "pending_file": pending_file,
                "archive_payload_sha256": built["archive_sha256"],
                "driver": "asyncpg",
                "pid": os.getpid(),
            })
            return "done"
        self.remove(path)
        self.attempts.pop(path.name, None)
        self.backoff = 0.0
        self.written += 1
        received_ns = int(header["received_ns"])
        write_ms = (time.monotonic() - started) * 1000
        amh.safe_log("agent_memory_hook_events.jsonl", {
            "ok": True,
            "created_at": now_iso(),
            "duration_ms": round(write_ms, 2),
            "queue_ms": round((time.time_ns() - received_ns) / 1e6 - write_ms, 2),
            "received_at": record["created_at"],
            "writer": "warm",
            "hook_pid": header.get("hook_pid"),
            "event": args.event,
            "event_type": built["event_type"],
            "agent": args.agent,
            "source": args.source,
            "space": built["space"],
            "session_id": built["session_id"],
            "identity": built["identity"],
            "memory_id": result["id"],
            "inserted": result.get("inserted"),
            "archive_id": archive_result.get("id"),
            "archive_inserted": archive_result.get("inserted"),
            "archive_payload_sha256": archive_result.get("payload_sha256"),
            "archive_raw_chars": archive_result.get("raw_chars"),
            "archive_compressed_bytes": archive_result.get("compressed_bytes"),
            "event_uid": built["event_uid"],
            "content_sha256": hashlib.sha256(built["content"].encode("utf-8", errors="replace")).hexdigest(),
            "payload_chars": len(raw),
            "driver": "asyncpg",
            "pid": os.getpid(),
        })
        return "done"

    async def verify_shadow(self) -> None:
        """Check each shadow spool file against the row the synchronous hook
        stored. Writes nothing to the database."""
        for path in list_inbox(SHADOW_DIR):
            try:
                header, raw = read_spool(path)
                args, built = build_from_spool(header, raw)
            except FileNotFoundError:
                continue
            except Exception as exc:
                amh.safe_log("agent_memory_shadow.jsonl", {"ok": False, "created_at": now_iso(), "result": "build_error",
                                                           "error": f"{type(exc).__name__}: {exc}"[:800], "file": path.name})
                path.unlink(missing_ok=True)
                continue
            record = built["record"]
            age_s = (time.time_ns() - int(header["received_ns"])) / 1e9
            try:
                conn = await self.connection()
                row = await conn.fetchrow(
                    "SELECT id, space, content, created_at FROM agent_memory_events WHERE event_uid = $1",
                    built["event_uid"],
                )
            except Exception as exc:
                self.drop_connection()
                writer_log({"ok": False, "event": "shadow_query_error", "error_type": type(exc).__name__,
                            "error": str(exc)[:300]})
                return
            if row is None and age_s < SHADOW_MAX_WAIT_S:
                continue  # The synchronous hook may still be writing it.
            expected_content, _ = am.compact_indexed_content(str(record["event"]["content"]))
            amh.safe_log("agent_memory_shadow.jsonl", {
                "ok": row is not None and row["content"] == expected_content and row["space"] == built["space"],
                "created_at": now_iso(),
                "result": "found" if row is not None else "missing_after_wait",
                "content_match": row is not None and row["content"] == expected_content,
                "space_match": row is not None and row["space"] == built["space"],
                "event": args.event,
                "agent": args.agent,
                "session_id": built["session_id"],
                "space": built["space"],
                "event_uid": built["event_uid"],
                "memory_id": row["id"] if row is not None else None,
                "received_at": record["created_at"],
                "old_row_created_at": row["created_at"].isoformat() if row is not None else None,
                "verified_after_s": round(age_s, 2),
                "hook_pid": header.get("hook_pid"),
            })
            path.unlink(missing_ok=True)

    async def replay_pending(self) -> None:
        if not amh.pending_status()["pending"]:
            return
        try:
            conn = await self.connection()
            result = await amh.replay_pending_async(20, conn=conn)
            writer_log({"ok": result.get("ok"), "event": "pending_replay", **result})
        except Exception as exc:
            self.drop_connection()
            writer_log({"ok": False, "event": "pending_replay_error", "error_type": type(exc).__name__,
                        "error": str(exc)[:500]})

    async def run(self) -> str:
        INBOX_DIR.mkdir(parents=True, exist_ok=True)
        stamp = source_stamp()
        last_heartbeat = last_source = 0.0
        last_pending = time.monotonic() - PENDING_REPLAY_EVERY_S + 2
        last_shadow = 0.0
        writer_log({"ok": True, "event": "started", "python": sys.version.split()[0]})
        while True:
            now = time.monotonic()
            if now - last_heartbeat >= HEARTBEAT_EVERY_S:
                write_heartbeat()
                last_heartbeat = now
            files = list_inbox()
            progressed = False
            for path in files:
                outcome = await self.process(path)
                if outcome == "stop":
                    break
                progressed = progressed or outcome == "done"
                if time.monotonic() - last_heartbeat >= HEARTBEAT_EVERY_S:
                    write_heartbeat()
                    last_heartbeat = time.monotonic()
            if self.backoff:
                await asyncio.sleep(self.backoff)
                continue
            if progressed:
                continue
            if files:
                await asyncio.sleep(0.2)  # Only deferred files left: retry shortly.
            if now - last_shadow >= SHADOW_CHECK_EVERY_S:
                last_shadow = now
                await self.verify_shadow()
            if now - last_source >= SOURCE_CHECK_EVERY_S:
                last_source = now
                if source_stamp() != stamp:
                    return "source_changed"
            if now - last_pending >= PENDING_REPLAY_EVERY_S:
                last_pending = now
                await self.replay_pending()
            await asyncio.sleep(POLL_S)


def respawn() -> None:
    """Start a fresh writer on the new code after this one lets go of the lock."""
    import subprocess

    flags = 0
    if os.name == "nt":
        flags = (getattr(subprocess, "DETACHED_PROCESS", 0x8) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x200)
                 | getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000))
    for extra in (getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0x01000000) if os.name == "nt" else 0, 0):
        try:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve())], cwd=str(BACKEND_DIR),
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             close_fds=True, creationflags=flags | extra, start_new_session=os.name != "nt")
            return
        except OSError:
            continue


def main() -> int:
    writer = Writer()
    reason = "unknown"
    try:
        reason = asyncio.run(writer.run())
    except KeyboardInterrupt:
        reason = "interrupted"
    except BaseException as exc:
        reason = f"crashed: {type(exc).__name__}: {exc}"
        writer_log({"ok": False, "event": "crashed", "error": traceback.format_exc()[-4000:]})
    finally:
        writer.drop_connection()
        writer_log({"ok": True, "event": "stopped", "reason": reason, "written": writer.written,
                    "uptime_s": round(time.monotonic() - writer.started, 1)})
        if LOCK_FD is not None:
            try:
                os.close(LOCK_FD)
            except OSError:
                pass
    if reason == "source_changed":
        respawn()
    return 0


if __name__ == "__main__":
    sys.exit(main())
