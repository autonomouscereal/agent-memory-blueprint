import asyncio
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

import agent_memory
import agent_memory_hook as hook


def connection():
    conn = Mock()
    conn.set_type_codec = AsyncMock()
    conn.execute = AsyncMock()
    conn.close = AsyncMock()
    conn.transaction.return_value = AsyncMock()
    return conn


def record():
    return {
        "version": 1,
        "event": {"event_uid": "stable-event-identity", "agent": "test",
                  "event_type": "tool", "space": "test/cleanup",
                  "session_id": "stable-session", "content": "test payload"},
        "archive": {"payload": '{"test":"original archive"}',
                    "metadata": {"payload_sha256": "unchanged-proof"}},
    }


class ConnectionSetupTests(unittest.IsolatedAsyncioTestCase):
    async def test_each_codec_failure_terminates_unreturned_connection(self):
        for failed_codec in (0, 1):
            with self.subTest(codec=failed_codec):
                conn = connection()
                failure = RuntimeError("codec setup failed")
                conn.set_type_codec.side_effect = [None] * failed_codec + [failure]
                with patch.object(agent_memory, "db_config", return_value={}), patch.object(
                    agent_memory.asyncpg, "connect", AsyncMock(return_value=conn)
                ):
                    with self.assertRaises(RuntimeError) as raised:
                        await agent_memory.connect()
                self.assertIs(raised.exception, failure)
                conn.terminate.assert_called_once_with()
                conn.close.assert_not_awaited()

    async def test_setup_cancellation_terminates_and_propagates(self):
        conn = connection()
        entered = asyncio.Event()
        async def setup(*args, **kwargs):
            entered.set()
            await asyncio.Event().wait()
        conn.set_type_codec.side_effect = setup
        with patch.object(agent_memory, "db_config", return_value={}), patch.object(
            agent_memory.asyncpg, "connect", AsyncMock(return_value=conn)
        ):
            task = asyncio.create_task(agent_memory.connect())
            await entered.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        conn.terminate.assert_called_once_with()

    async def test_termination_failure_does_not_mask_setup_error(self):
        conn = connection()
        failure = ValueError("original")
        conn.set_type_codec.side_effect = failure
        conn.terminate.side_effect = RuntimeError("cleanup")
        with patch.object(agent_memory, "db_config", return_value={}), patch.object(
            agent_memory.asyncpg, "connect", AsyncMock(return_value=conn)
        ):
            with self.assertRaises(ValueError) as raised:
                await agent_memory.connect()
        self.assertIs(raised.exception, failure)

    async def test_success_transfers_connection_without_termination(self):
        conn = connection()
        with patch.object(agent_memory, "db_config", return_value={}), patch.object(
            agent_memory.asyncpg, "connect", AsyncMock(return_value=conn)
        ):
            self.assertIs(await agent_memory.connect(), conn)
        self.assertEqual([call.args[0] for call in conn.set_type_codec.await_args_list], ["jsonb", "json"])
        conn.terminate.assert_not_called()

    async def test_hook_connect_timeout_cleans_first_connection_before_retry(self):
        first, second = connection(), connection()
        async def blocked_setup(*args, **kwargs):
            await asyncio.Event().wait()
        first.set_type_codec.side_effect = blocked_setup
        with patch.object(agent_memory, "db_config", return_value={}), patch.object(
            agent_memory.asyncpg, "connect", AsyncMock(side_effect=[first, second])
        ), patch.object(hook, "HOOK_CONNECT_TIMEOUT", .02), patch.object(hook, "HOOK_CONNECT_ATTEMPTS", 2):
            self.assertIs(await hook.connect_for_hook(), second)
        first.terminate.assert_called_once_with()
        second.terminate.assert_not_called()


class HookCloseTests(unittest.IsolatedAsyncioTestCase):
    async def test_close_wait_before_driver_timeout_is_bounded(self):
        conn = connection()
        cancelled = asyncio.Event()
        async def stuck_close(**kwargs):
            # Model asyncpg waiting on cancel_waiter before applying timeout.
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()
        conn.close.side_effect = stuck_close
        started = time.monotonic()
        with patch.object(hook, "HOOK_CLOSE_TIMEOUT", .02):
            with self.assertRaises(TimeoutError):
                await hook.close_for_hook(conn)
        self.assertLess(time.monotonic() - started, .5)
        self.assertTrue(cancelled.is_set())
        conn.terminate.assert_called_once_with()

    async def test_cancelled_close_terminates_without_swallowing_cancellation(self):
        conn = connection()
        entered = asyncio.Event()
        async def close(**kwargs):
            entered.set()
            await asyncio.Event().wait()
        conn.close.side_effect = close
        task = asyncio.create_task(hook.close_for_hook(conn))
        await entered.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        conn.terminate.assert_called_once_with()

    async def test_normal_close_does_not_terminate(self):
        conn = connection()
        await hook.close_for_hook(conn)
        conn.close.assert_awaited_once_with(timeout=hook.HOOK_CLOSE_TIMEOUT)
        conn.terminate.assert_not_called()

    async def test_write_error_or_cancellation_survives_close_error(self):
        for failure in (ValueError("original write"), asyncio.CancelledError("original cancellation")):
            with self.subTest(error=type(failure).__name__):
                conn = connection()
                conn.execute.side_effect = failure
                conn.close.side_effect = RuntimeError("cleanup error")
                with patch.object(hook, "connect_for_hook", AsyncMock(return_value=conn)):
                    with self.assertRaises(type(failure)) as raised:
                        await hook.store_hook_record(record())
                self.assertIs(raised.exception, failure)
                conn.terminate.assert_called_once_with()

    async def test_new_cancellation_during_failed_write_cleanup_propagates(self):
        conn = connection()
        conn.execute.side_effect = ValueError("write failed")
        entered = asyncio.Event()
        async def close(**kwargs):
            entered.set()
            await asyncio.Event().wait()
        conn.close.side_effect = close
        with patch.object(hook, "connect_for_hook", AsyncMock(return_value=conn)):
            task = asyncio.create_task(hook.store_hook_record(record()))
            await entered.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        conn.terminate.assert_called_once_with()

    async def test_close_failure_preserves_pending_identity_for_idempotent_replay(self):
        value = record()
        first, second = connection(), connection()
        first.close.side_effect = RuntimeError("close failed after commit")
        event_result = {"id": 42, "event_uid": value["event"]["event_uid"]}
        archive_result = {"id": 43}
        with tempfile.TemporaryDirectory() as directory, patch.object(hook, "PENDING_DIR", Path(directory)), patch.object(
            hook, "connect_for_hook", AsyncMock(side_effect=[first, second])
        ), patch.object(hook, "add_event_async", AsyncMock(return_value=event_result)) as add, patch.object(
            hook, "archive_payload_async", AsyncMock(return_value=archive_result)
        ) as archive, patch.object(hook, "safe_log"):
            pending = Path(hook.spool_pending(value))
            original_bytes = pending.read_bytes()
            failed = await hook.replay_pending_async(limit=1)
            self.assertEqual((failed["replayed"], failed["failed"], failed["remaining"]), (0, 1, 1))
            self.assertEqual(pending.read_bytes(), original_bytes)
            self.assertEqual(hook.load_pending(pending), value)
            passed = await hook.replay_pending_async(limit=1)
            self.assertEqual((passed["replayed"], passed["failed"], passed["remaining"]), (1, 0, 0))
            self.assertFalse(pending.exists())
            self.assertEqual([call.kwargs["event_uid"] for call in add.await_args_list], [value["event"]["event_uid"]] * 2)
            self.assertEqual([call.kwargs["payload"] for call in archive.await_args_list], [value["archive"]["payload"]] * 2)
            self.assertEqual([call.kwargs["event_id"] for call in archive.await_args_list], [42, 42])
        first.terminate.assert_called_once_with()
        second.terminate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
