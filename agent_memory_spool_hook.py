#!/usr/bin/env python3
"""Fast hook entry point: spool the event durably, then return.

Claude Code waits for every synchronous hook before it continues, so this
script does the least work that still guarantees the event is kept:

1. read the raw hook payload from stdin,
2. write it, with the hook's argv, cwd, fire time and memory-related
   environment, to logs/inbox/<time_ns>-<pid>-<rand>.hook (fsync, then an
   atomic rename),
3. make sure the warm writer (agent_memory_writer.py) is running, and exit 0.

The writer builds the record with the same code as agent_memory_hook.py and
commits it to PostgreSQL. A spool file is deleted only after its event and
archive commit, so a stopped writer delays events and never drops them.

Run with `python -I -S`: it imports only the standard library. Any failure
here falls back to the synchronous agent_memory_hook.py with the same input,
so an event is never lost to a spool problem. It always exits 0.
"""

import json
import os
import sys
import time

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
SPOOL_ROOT = os.path.join(BACKEND_DIR, "logs")
INBOX_DIR = os.path.join(SPOOL_ROOT, "inbox")
# --shadow spools to a separate inbox that the writer only verifies against
# rows the synchronous hook stored; it never writes. Used to prove a rollout.
SHADOW_DIR = os.path.join(SPOOL_ROOT, "inbox-shadow")
LOCK_PATH = os.path.join(SPOOL_ROOT, "writer.lock")
HEARTBEAT_PATH = os.path.join(SPOOL_ROOT, "writer.heartbeat")
SPAWN_MARK_PATH = os.path.join(SPOOL_ROOT, "writer.spawn")
LEGACY_HOOK = os.path.join(BACKEND_DIR, "agent_memory_hook.py")
WRITER = os.path.join(BACKEND_DIR, "agent_memory_writer.py")
SPOOL_VERSION = 1
SPAWN_THROTTLE_S = 5.0
STALE_HEARTBEAT_S = 300.0

# A session that points memory at another database, log or spool location
# keeps the synchronous path: the shared warm writer has one destination.
ROUTING_KEYS = (
    "MEMORY_DB_HOST", "MEMORY_DB_PORT", "MEMORY_DB_NAME", "MEMORY_DB_USER",
    "MEMORY_DB_PASSWORD", "MEMORY_DB_PASSWORD_FILE", "MEMORY_DB_PASSWORD_COMMAND",
    "PGPASSWORD", "AGENT_MEMORY_ENV_FILE", "AGENT_MEMORY_LOG_DIR", "AGENT_MEMORY_PENDING_DIR",
)
# Per-event values the record builder reads from the hook's environment.
CAPTURED_KEYS = ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CODEX_HOME")
CAPTURED_PREFIXES = ("AGENT_MEMORY_", "MEMORY_")
SECRET_MARKERS = ("PASSWORD", "PASSWD", "TOKEN", "SECRET", "CREDENTIAL", "COOKIE", "AUTH", "API_KEY", "PRIVATE")
LEGACY_FLAGS = ("--pending-status", "--replay-pending", "--emit-json")


def captured_environment():
    env = {}
    for key, value in os.environ.items():
        upper = key.upper()
        if upper in CAPTURED_KEYS or upper.startswith(CAPTURED_PREFIXES):
            if any(marker in upper for marker in SECRET_MARKERS):
                continue
            env[upper] = value
    return env


def run_legacy(argv, raw, *, show_output=False):
    """Synchronous fallback: the original hook, same argv and stdin bytes."""
    import subprocess

    quiet = None if show_output else subprocess.DEVNULL
    try:
        subprocess.run(
            [sys.executable, LEGACY_HOOK, *argv],
            input=raw,
            stdout=quiet,
            stderr=quiet,
            cwd=os.getcwd(),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            timeout=60,
        )
    except Exception:
        pass


def write_spool(argv, raw, received_ns, inbox=None):
    inbox = inbox or INBOX_DIR
    os.makedirs(inbox, exist_ok=True)
    header = {
        "v": SPOOL_VERSION,
        "received_ns": received_ns,
        "hook_pid": os.getpid(),
        "argv": argv,
        "cwd": os.getcwd(),
        "env": captured_environment(),
        "raw_len": len(raw),
    }
    data = json.dumps(header, ensure_ascii=True, separators=(",", ":")).encode("ascii") + b"\n" + raw
    stem = "%020d-%d-%s" % (received_ns, os.getpid(), os.urandom(4).hex())
    temp_path = os.path.join(inbox, stem + ".tmp")
    final_path = os.path.join(inbox, stem + ".hook")
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temp_path, final_path)
    return final_path


def writer_running():
    """True when another process holds the writer lock."""
    try:
        import msvcrt
    except ImportError:  # POSIX
        import fcntl

        fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        finally:
            os.close(fd)
        return False
    fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        except OSError:
            return True
        try:
            os.lseek(fd, 0, 0)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        except OSError:
            pass
        return False
    finally:
        os.close(fd)


def heartbeat():
    """(pid, age in seconds) from the writer heartbeat, or (0, inf)."""
    try:
        with open(HEARTBEAT_PATH, "r", encoding="ascii") as handle:
            pid_text, stamp_text = handle.read().split()[:2]
        return int(pid_text), time.time() - float(stamp_text)
    except Exception:
        return 0, float("inf")


def spawn_writer():
    try:
        if time.time() - os.path.getmtime(SPAWN_MARK_PATH) < SPAWN_THROTTLE_S:
            return
    except OSError:
        pass
    with open(SPAWN_MARK_PATH, "w", encoding="ascii") as handle:
        handle.write(str(os.getpid()))
    import subprocess

    exe = sys.executable
    windowless = os.path.join(os.path.dirname(exe), "pythonw.exe")
    if os.name == "nt" and os.path.exists(windowless):
        exe = windowless
    keep = (
        "SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "PATH", "PATHEXT", "TEMP", "TMP", "USERPROFILE",
        "HOMEDRIVE", "HOMEPATH", "HOME", "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "PROGRAMFILES",
        "COMPUTERNAME", "USERNAME", "USERDOMAIN", "OS", "PROCESSOR_ARCHITECTURE", "NUMBER_OF_PROCESSORS",
    )
    env = {key: os.environ[key] for key in keep if key in os.environ}
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    flags = 0
    if os.name == "nt":
        flags = (
            getattr(subprocess, "DETACHED_PROCESS", 0x8)
            | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x200)
            | getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        )
    breakaway = getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0x01000000) if os.name == "nt" else 0
    for extra in (breakaway, 0):
        try:
            subprocess.Popen(
                [exe, WRITER],
                cwd=BACKEND_DIR,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                creationflags=flags | extra,
                start_new_session=os.name != "nt",
            )
            return
        except OSError:
            continue  # A job that forbids breakaway refuses the first flag set.


def ensure_writer():
    if writer_running():
        pid, age = heartbeat()
        if pid and age > STALE_HEARTBEAT_S:
            try:
                import signal

                os.kill(pid, signal.SIGTERM)  # TerminateProcess on Windows.
            except Exception:
                return
            time.sleep(0.2)
            spawn_writer()
        return
    spawn_writer()


def main():
    received_ns = time.time_ns()
    argv = sys.argv[1:]
    shadow = "--shadow" in argv
    if shadow:
        argv = [item for item in argv if item != "--shadow"]
    raw = b""
    try:
        if not sys.stdin.isatty():
            raw = sys.stdin.buffer.read()
    except Exception:
        raw = b""
    if shadow:
        try:
            write_spool(argv, raw, received_ns, SHADOW_DIR)
            ensure_writer()
        except Exception:
            pass
        return 0
    if any(flag in argv for flag in LEGACY_FLAGS):
        run_legacy(argv, raw, show_output=True)
        return 0
    if any(key in os.environ for key in ROUTING_KEYS):
        run_legacy(argv, raw)
        return 0
    try:
        write_spool(argv, raw, received_ns)
    except Exception:
        run_legacy(argv, raw)
        return 0
    try:
        ensure_writer()
    except Exception:
        pass  # The event is on disk; the next hook starts the writer.
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except BaseException:
        code = 0
    sys.exit(code)
