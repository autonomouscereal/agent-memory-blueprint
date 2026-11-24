#!/usr/bin/env python3
"""Run the deployed agent memory backup script on the database host through server-manager.

The host, the server-manager skill and the remote script path come from the command line or from
AGENT_MEMORY_BACKUP_SERVER, SERVER_MANAGER_SKILL_DIR and AGENT_MEMORY_BACKUP_REMOTE_SCRIPT. A remote path
that starts with ~/ is resolved in the remote account's home directory.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


DEFAULT_SERVER_MANAGER = Path.home() / ".agents" / "skills" / "server-manager"
DEFAULT_REMOTE_SCRIPT = "~/agent-memory-backup/bin/backup_agent_memory_pg.sh"
DEFAULT_SERVER = "ai"
DEFAULT_RUN_TIMEOUT_SECONDS = 0
DEFAULT_OTHER_TIMEOUT_SECONDS = 300
# dry-run and verify hash the published dump (and any pending stage) over CIFS.
DEFAULT_VERIFY_TIMEOUT_SECONDS = 3600


def build_remote_command(args: argparse.Namespace, remote_timeout_seconds: int | None) -> str:
    env_parts = []
    if args.bwlimit_kbps is not None:
        env_parts.append(f"BWLIMIT_KBPS={int(args.bwlimit_kbps)}")
    if args.cron_schedule:
        env_parts.append("CRON_SCHEDULE=" + shell_quote(args.cron_schedule))

    env_prefix = ""
    if env_parts:
        env_prefix = " ".join(env_parts) + " "

    command_args = shell_quote(args.command)
    if args.command == "verify" and args.backup_id:
        command_args += " " + shell_quote(args.backup_id)
    plain_command = f'{env_prefix}"$REMOTE_SCRIPT" {command_args}'
    lines = [
        "set -euo pipefail",
        f"REMOTE_SCRIPT={remote_path(args.remote_script)}",
        'if [ ! -x "$REMOTE_SCRIPT" ]; then',
        '  echo "Missing executable remote backup script: $REMOTE_SCRIPT" >&2',
        "  exit 2",
        "fi",
    ]
    if remote_timeout_seconds is None:
        lines.append(plain_command)
    else:
        timed_command = (
            f"{env_prefix}timeout --foreground --signal=TERM --kill-after=15s "
            f"{int(remote_timeout_seconds)}s \"$REMOTE_SCRIPT\" {command_args}"
        )
        lines.extend(
            [
                "if command -v timeout >/dev/null 2>&1; then",
                f"  {timed_command}",
                "else",
                f"  {plain_command}",
                "fi",
            ]
        )
    lines.append("")
    return "\n".join(lines)


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def remote_path(value: str) -> str:
    """Shell text for a remote path; a leading ~/ becomes the remote $HOME."""
    if value.startswith("~/"):
        return '"$HOME"/' + shell_quote(value[2:])
    return shell_quote(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["run", "dry-run", "verify", "status", "list", "install-cron", "uninstall-cron", "restore-help"],
        help="Remote backup command to run.",
    )
    parser.add_argument("backup_id", nargs="?", default=None, help="verify only: backup id (default: latest).")
    parser.add_argument(
        "--server",
        default=os.environ.get("AGENT_MEMORY_BACKUP_SERVER", DEFAULT_SERVER),
        help="server-manager server key.",
    )
    parser.add_argument(
        "--server-manager-dir",
        default=os.environ.get("SERVER_MANAGER_SKILL_DIR", str(DEFAULT_SERVER_MANAGER)),
        help="Path to the server-manager skill directory.",
    )
    parser.add_argument(
        "--remote-script",
        default=os.environ.get("AGENT_MEMORY_BACKUP_REMOTE_SCRIPT", DEFAULT_REMOTE_SCRIPT),
        help="Remote script path (~/ = the remote home directory).",
    )
    parser.add_argument("--bwlimit-kbps", type=int, default=None, help="Override rsync throttle.")
    parser.add_argument("--cron-schedule", default=None, help="Override cron schedule for install-cron.")
    parser.add_argument(
        "--command-timeout",
        type=int,
        default=None,
        help="Remote command timeout in seconds. Run defaults to 0 (disabled); dry-run and verify default to 3600; others to 300.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    server_manager_dir = Path(args.server_manager_dir)
    ssh_client = server_manager_dir / "ssh_client.py"
    if not ssh_client.exists():
        print(f"server-manager ssh_client.py not found: {ssh_client}", file=sys.stderr)
        return 2

    if args.command_timeout is not None:
        command_timeout = args.command_timeout
    elif args.command == "run":
        command_timeout = DEFAULT_RUN_TIMEOUT_SECONDS
    elif args.command in ("dry-run", "verify"):
        command_timeout = DEFAULT_VERIFY_TIMEOUT_SECONDS
    else:
        command_timeout = DEFAULT_OTHER_TIMEOUT_SECONDS
    command_timeout = int(command_timeout)
    if command_timeout < 0:
        print("--command-timeout must be zero or a positive integer", file=sys.stderr)
        return 2
    remote_timeout = None if command_timeout == 0 else max(1, command_timeout - 30)
    command = build_remote_command(args, remote_timeout)
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False, encoding="utf-8", newline="\n") as handle:
        handle.write(command)
        command_file = handle.name

    try:
        proc = subprocess.run(
            [
                sys.executable,
                str(ssh_client),
                "--server",
                args.server,
                "--command-file",
                command_file,
                "--command-timeout",
                str(command_timeout),
            ],
            check=False,
        )
        return int(proc.returncode)
    finally:
        try:
            os.unlink(command_file)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
