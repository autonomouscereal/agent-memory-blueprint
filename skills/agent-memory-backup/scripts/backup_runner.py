#!/usr/bin/env python3
"""Cron entrypoint for the agent-memory backup: run it under a watchdog and keep an exit receipt.

Installed by `backup_agent_memory_pg.sh install-cron`. Replaces the 2026-10-18
normal_backup_runner_20261018.py and writes the same receipt files:
state/normal-run-<stamp>.public.json per run and state/reliability-run-exit.public.json
for the latest. If the script ends non-zero without raising an alert itself (for
example after a SIGKILL from the watchdog), the runner raises one.
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import re
import subprocess
import syslog
import time

RUNNER_VERSION = "3.2.1"
SCRIPT = pathlib.Path(__file__).resolve().with_name("backup_agent_memory_pg.sh")
ENV_LINE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def read_env_file(path: pathlib.Path) -> dict:
    """KEY=VALUE pairs of the job's env file, by the rules of load_env_file in backup_agent_memory_pg.sh:
    blank lines and # comments skipped, an optional "export " and one pair of surrounding quotes removed,
    nothing expanded, the first line for a key wins. A missing file is empty."""
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = ENV_LINE.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values.setdefault(key, value)
    return values


# The same env file the script reads, so the runner's STATE_DIR and LOG_DIR always match the script's.
ENV_FILE = pathlib.Path(os.environ.get("AGENT_MEMORY_BACKUP_ENV") or SCRIPT.with_name("agent-memory-backup.env"))
FILE_SETTINGS = read_env_file(ENV_FILE)


def setting(name: str, default: str) -> str:
    """The environment wins over the env file; empty counts as unset, as with ${NAME:-default} in the script."""
    value = os.environ[name] if name in os.environ else FILE_SETTINGS.get(name, "")
    return value or default


HOME = pathlib.Path(setting("AGENT_MEMORY_BACKUP_HOME", str(pathlib.Path.home() / "agent-memory-backup")))
STATE_DIR = pathlib.Path(setting("STATE_DIR", str(HOME / "state")))
LOG_FILE = pathlib.Path(setting("LOG_DIR", str(HOME / "logs"))) / "cron.log"
TIMEOUT_SECONDS = int(setting("BACKUP_TIMEOUT_SECONDS", "21600"))

EXIT_MEANINGS = {
    0: "published; exactly one verified backup kept",
    1: "failed; previous backup kept",
    3: "published and verified; some superseded or stale paths could not be deleted",
    4: "paused: the paced copy stopped at the end of its window; partial and verified stage kept for the next run; previous backup kept",
    75: "skipped; another backup run holds the lock",
    124: "watchdog timeout; previous backup kept unless the log shows publication",
    137: "killed by the watchdog; previous backup kept unless the log shows publication",
}


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def write_exclusive(path: pathlib.Path, data: dict) -> None:
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
        json.dump(data, handle, indent=2)


def write_atomic(path: pathlib.Path, data: dict) -> None:
    temp = path.with_name(path.name + ".tmp")
    temp.unlink(missing_ok=True)
    write_exclusive(temp, data)
    temp.replace(path)


def wait_for_cleanup(limit_seconds: int = 90) -> float:
    """After a watchdog signal, timeout returns once the flock wrapper dies while
    the locked run is still deleting its partial transfer and raising its alert.
    Wait (bounded) for that process so the receipt sees the final state."""
    began = time.monotonic()
    while time.monotonic() - began < limit_seconds:
        probe = subprocess.run(["pgrep", "-f", f"{SCRIPT} run-locked"], capture_output=True)
        if probe.returncode != 0:
            break
        time.sleep(1)
    return round(time.monotonic() - began, 1)


def main() -> int:
    started = utc_now()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    alert_path = STATE_DIR / "alert.json"
    with LOG_FILE.open("ab") as log:
        result = subprocess.run(
            ["/usr/bin/timeout", "--kill-after=60s", str(TIMEOUT_SECONDS), str(SCRIPT), "run"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, cwd=str(HOME.parent),
        )
    code = result.returncode
    cleanup_wait_seconds = wait_for_cleanup() if code not in (0, 75) else 0.0
    completed = utc_now()

    alert_raised_by_script = alert_path.exists() and alert_path.stat().st_mtime >= started.timestamp()
    if code not in (0, 75) and not alert_raised_by_script:
        alert = {
            "severity": "error",
            "message": f"backup runner: script exited {code} without raising an alert ({EXIT_MEANINGS.get(code, 'unexpected exit')})",
            "phase": "runner",
            "raised_at_utc": completed.isoformat(),
            "script_version": RUNNER_VERSION,
        }
        write_atomic(alert_path, alert)
        with (STATE_DIR / "alerts.log").open("a") as handle:
            handle.write(f"[{completed.strftime('%Y-%m-%dT%H:%M:%SZ')}] error {alert['message']}\n")
        if setting("ALERT_SYSLOG", "1") == "1":
            syslog.openlog("agent-memory-backup")
            syslog.syslog(syslog.LOG_ERR, alert["message"])

    receipt = {
        "normal_entrypoint": f"{SCRIPT} run",
        "runner": str(pathlib.Path(__file__).resolve()),
        "runner_version": RUNNER_VERSION,
        "exit_code": code,
        "meaning": EXIT_MEANINGS.get(code, "unexpected exit"),
        "started_at_utc": started.isoformat(),
        "completed_at_utc": completed.isoformat(),
        "retention": "one-verified",
        "bandwidth_kib_s": setting("BWLIMIT_KBPS", "6000"),
        "timeout_seconds": TIMEOUT_SECONDS,
        "cleanup_wait_seconds": cleanup_wait_seconds,
        "retention_hold": (STATE_DIR / "retention-hold").exists(),
        "alert_present": alert_path.exists(),
    }
    stamp = completed.strftime("%Y%m%dT%H%M%SZ")
    write_exclusive(STATE_DIR / f"normal-run-{stamp}.public.json", receipt)
    write_atomic(STATE_DIR / "reliability-run-exit.public.json", receipt)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
