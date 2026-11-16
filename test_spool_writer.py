"""Offline tests for the spool hook and warm writer (no database needed).

python test_spool_writer.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import UTC, datetime
from pathlib import Path

BACKEND = Path(__file__).resolve().parent
sys.path.insert(0, str(BACKEND))

import agent_memory_hook as amh  # noqa: E402
import agent_memory_writer as amw  # noqa: E402

SPOOL_HOOK = BACKEND / "agent_memory_spool_hook.py"


def spool_in(inbox: str, argv: list[str], raw: bytes, cwd: str, env: dict[str, str]) -> Path:
    """Run the real spool hook under `python -I -S` with its inbox redirected."""
    code = (
        "import runpy, sys, time; m = runpy.run_path(sys.argv[1], run_name='spool');"
        "print(m['write_spool'](sys.argv[3:], sys.stdin.buffer.read(), time.time_ns(), sys.argv[2]))"
    )
    out = subprocess.run(
        [sys.executable, "-I", "-S", "-c", code, str(SPOOL_HOOK), inbox, *argv],
        input=raw, capture_output=True, cwd=cwd, env=env, check=True,
    )
    return Path(out.stdout.decode().strip().splitlines()[-1])


class SpoolWriterEquivalence(unittest.TestCase):
    def setUp(self) -> None:
        self.inbox = tempfile.mkdtemp(prefix="spool-test-")
        self.cwd = tempfile.mkdtemp(prefix="spool-cwd-")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("AGENT_MEMORY_", "MEMORY_"))}
        self.env["CLAUDE_CODE_SESSION_ID"] = "11111111-2222-3333-4444-555555555555"

    def build_both(self, argv: list[str], payload: dict) -> tuple[dict, dict]:
        raw = json.dumps(payload).encode("utf-8")
        path = spool_in(self.inbox, argv, raw, self.cwd, self.env)
        header, body = amw.read_spool(path)
        _, from_spool = amw.build_from_spool(header, body)
        environ = amw.base_environment()
        environ.update(header["env"])
        args = amh.build_parser(environ=environ).parse_args(argv)
        text = amh.resolve_hook_input(args, raw.decode("utf-8"))
        received = datetime.fromtimestamp(int(header["received_ns"]) / 1e9, UTC)
        direct = amh.build_hook_record(args, text, cwd=self.cwd, environ=environ, received_at=received)
        return json.loads(json.dumps(direct["record"], default=str)), json.loads(json.dumps(from_spool["record"], default=str))

    def test_prompt_stop_and_tool_records_match(self) -> None:
        cases = [
            (["--event", "UserPromptSubmit", "--agent", "Test", "--source", "claude_hook"],
             {"session_id": "s-1", "cwd": self.cwd, "prompt": "café — token=abcd1234efgh"}),
            (["--event", "Stop", "--agent", "Test", "--source", "claude_hook"],
             {"session_id": "s-1", "cwd": self.cwd, "last_assistant_message": "done"}),
            (["--event", "PostToolUse", "--agent", "Test", "--source", "claude_hook"],
             {"session_id": "s-1", "cwd": self.cwd, "tool_name": "Bash", "tool_input": {"password": "hunter2hunter2"},
              "tool_response": {"stdout": "x" * 20000}}),
        ]
        for argv, payload in cases:
            with self.subTest(event=argv[1]):
                direct, spooled = self.build_both(argv, payload)
                self.assertEqual(direct, spooled)
                self.assertNotIn("hunter2hunter2", json.dumps(spooled))
                self.assertNotIn("abcd1234efgh", json.dumps(spooled))

    def test_event_named_by_payload_only(self) -> None:
        direct, spooled = self.build_both(["--agent", "Test"], {"session_id": "s-2", "hook_event_name": "Stop"})
        self.assertEqual(direct, spooled)
        self.assertEqual(spooled["event"]["event_type"], "session_stop")

    def test_session_id_from_hook_environment(self) -> None:
        _, spooled = self.build_both(["--event", "Stop", "--agent", "Test"], {"last_assistant_message": "x"})
        self.assertEqual(spooled["event"]["session_id"], self.env["CLAUDE_CODE_SESSION_ID"])

    def test_secret_environment_is_never_spooled(self) -> None:
        env = dict(self.env)
        env["AGENT_MEMORY_API_TOKEN"] = "should-not-appear"
        env["AGENT_MEMORY_MODEL_ID"] = "model-x"
        path = spool_in(self.inbox, ["--event", "Stop"], b"{}", self.cwd, env)
        header, _ = amw.read_spool(path)
        self.assertNotIn("AGENT_MEMORY_API_TOKEN", header["env"])
        self.assertEqual(header["env"]["AGENT_MEMORY_MODEL_ID"], "model-x")
        self.assertNotIn(b"should-not-appear", path.read_bytes())

    def test_truncated_spool_is_rejected(self) -> None:
        path = spool_in(self.inbox, ["--event", "Stop"], b'{"a": 1}', self.cwd, self.env)
        path.write_bytes(path.read_bytes()[:-2])
        with self.assertRaises(ValueError):
            amw.read_spool(path)

    def test_spool_hook_is_fast_and_silent(self) -> None:
        # Uses a scratch copy so no real writer is started from the test.
        scratch = Path(tempfile.mkdtemp(prefix="spool-copy-"))
        copy = scratch / "agent_memory_spool_hook.py"
        copy.write_bytes(SPOOL_HOOK.read_bytes())
        (scratch / "agent_memory_writer.py").write_text("import sys; sys.exit(0)\n", encoding="utf-8")
        started = time.perf_counter()
        out = subprocess.run([sys.executable, "-I", "-S", str(copy), "--event", "Stop", "--agent", "Test"],
                             input=b'{"session_id": "s-3"}', capture_output=True, cwd=self.cwd, env=self.env)
        elapsed = time.perf_counter() - started
        self.assertEqual((out.returncode, out.stdout, out.stderr), (0, b"", b""))
        self.assertEqual(len(list((scratch / "logs" / "inbox").glob("*.hook"))), 1)
        self.assertLess(elapsed, 10.0)


    def test_health_flags_missing_writer_and_old_inbox(self) -> None:
        scratch = Path(tempfile.mkdtemp(prefix="spool-health-"))
        copy = scratch / "agent_memory_spool_hook.py"
        copy.write_bytes(SPOOL_HOOK.read_bytes())
        inbox = scratch / "logs" / "inbox"
        inbox.mkdir(parents=True)
        old_ns = time.time_ns() - 600 * 10**9
        (inbox / f"{old_ns:020d}-1-abcd.hook").write_bytes(b"{}\n")
        out = subprocess.run([sys.executable, "-I", "-S", str(copy), "--health"], capture_output=True)
        report = json.loads(out.stdout)
        self.assertEqual(out.returncode, 3)
        self.assertIn("writer_not_running", report["reasons"])
        self.assertIn("inbox_event_older_than_300s", report["reasons"])
        self.assertEqual(report["inbox_waiting"], 1)


class EventsLogParts(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="evlog-test-"))
        self.live = self.dir / "agent_memory_hook_events.jsonl"
        self.lines = [json.dumps({"i": i, "t": "café " + "x" * (i % 200)}, ensure_ascii=False) + "\n" for i in range(5000)]
        self.live.write_text("".join(self.lines), encoding="utf-8", newline="\n")
        self.logged: list[dict] = []
        self.original_log = amw.writer_log
        amw.writer_log = self.logged.append

    def tearDown(self) -> None:
        amw.writer_log = self.original_log

    def test_roll_compress_keeps_every_line(self) -> None:
        import gzip

        self.assertIsNone(amw.roll_events_log(self.dir, self.live.stat().st_size + 1))
        part = amw.roll_events_log(self.dir, 1)
        self.assertIsNotNone(part)
        self.assertFalse(self.live.exists())
        amw.compress_pending_parts(self.dir)
        target = part.with_name(part.name + ".gz")
        self.assertTrue(target.exists())
        self.assertFalse(part.exists())
        with gzip.open(target, "rt", encoding="utf-8", newline="") as stream:
            self.assertEqual(stream.read(), "".join(self.lines))
        self.assertTrue(self.logged[-1]["verified"])
        self.assertEqual(self.logged[-1]["lines"], len(self.lines))

    def test_held_open_log_is_not_renamed(self) -> None:
        with open(self.live, "a", encoding="utf-8"):
            if os.name == "nt":
                self.assertIsNone(amw.roll_events_log(self.dir, 1))
                self.assertTrue(self.live.exists())

    def test_killed_compression_resumes(self) -> None:
        part = self.dir / "agent_memory_hook_events.20990101T000000Z.jsonl"
        part.write_text("".join(self.lines[:7]), encoding="utf-8", newline="\n")
        (self.dir / (part.name + ".gz.tmp")).write_bytes(b"partial")
        amw.compress_pending_parts(self.dir)
        self.assertTrue((self.dir / (part.name + ".gz")).exists())
        self.assertFalse(part.exists())
        self.assertFalse((self.dir / (part.name + ".gz.tmp")).exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
