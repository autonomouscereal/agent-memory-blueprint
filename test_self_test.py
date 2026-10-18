import unittest
from unittest.mock import AsyncMock, patch

import asyncpg

import agent_memory


class SelfTestTests(unittest.IsolatedAsyncioTestCase):
    async def test_initialized_database_runs_diagnostics_without_init(self):
        sentinel = "AGENT_MEMORY_SELF_TEST_20260512 asyncpg cpu embedder postgres semantic audit trace"
        with (
            patch.object(agent_memory, "init_db_async", AsyncMock()) as initialize,
            patch.object(agent_memory, "self_test_schema_async", AsyncMock(return_value={"ok": True})),
            patch.object(agent_memory, "add_event_async", AsyncMock(return_value={"id": 1})) as insert,
            patch.object(agent_memory, "relate_entities_async", AsyncMock(return_value={"id": 2})) as relate,
            patch.object(agent_memory, "search_events_async", AsyncMock(side_effect=[[{"content": sentinel}], []])) as search,
            patch.object(agent_memory, "graph_neighbors_async", AsyncMock(return_value=[{"id": 2}])) as graph,
        ):
            result = await agent_memory.self_test_async()
        initialize.assert_not_awaited()
        self.assertTrue(result["ok"])
        self.assertTrue(result["isolated"])
        self.assertEqual(insert.await_count, 2)
        self.assertEqual([call.kwargs["space"] for call in insert.await_args_list], ["self-test-alpha", "self-test-beta"])
        self.assertEqual(search.await_count, 2)
        self.assertTrue(all(call.kwargs["space"] == "self-test-alpha" for call in search.await_args_list))
        relate.assert_awaited_once()
        graph.assert_awaited_once()

    async def test_missing_schema_fails_before_writes_and_cli_returns_failure(self):
        connection = AsyncMock()
        connection.fetch.side_effect = [[], []]
        with (
            patch.object(agent_memory, "connect", AsyncMock(return_value=connection)),
            patch.object(agent_memory, "init_db_async", AsyncMock()) as initialize,
            patch.object(agent_memory, "add_event_async", AsyncMock()) as insert,
            patch.object(agent_memory, "print_result") as output,
        ):
            code = await agent_memory.run_cli(agent_memory.build_parser().parse_args(["--json", "self-test"]))
        result = output.call_args.args[0]
        self.assertEqual(code, 2)
        self.assertFalse(result["ok"])
        self.assertIn("python agent_memory.py init", result["error"])
        self.assertIn("agent_memory_events", result["missing_schema"])
        self.assertIn("extension:vector", result["missing_schema"])
        initialize.assert_not_awaited()
        insert.assert_not_awaited()
        self.assertEqual(connection.execute.await_args.args, (
            "SELECT set_config('statement_timeout', $1, false)", "5000",
        ))
        for call in connection.execute.await_args_list + connection.fetch.await_args_list:
            self.assertEqual(call.kwargs["timeout"], 5)
            self.assertTrue(call.args[0].strip().startswith("SELECT"))
            self.assertNotIn("ALTER TABLE", call.args[0])
            self.assertNotIn("CREATE ", call.args[0])
        connection.close.assert_awaited_once_with(timeout=5)

    async def test_outdated_schema_identifies_missing_column(self):
        connection = AsyncMock()
        connection.fetch.side_effect = [
            [{"relname": "agent_memory_events", "attname": "id"}],
            [{"extname": "vector"}, {"extname": "pg_trgm"}],
        ]
        with patch.object(agent_memory, "connect", AsyncMock(return_value=connection)):
            result = await agent_memory.self_test_schema_async()
        self.assertFalse(result["ok"])
        self.assertIn("agent_memory_events.memory_kind", result["missing_schema"])
        self.assertNotIn("agent_memory_events.id", result["missing_schema"])
        self.assertNotIn("extension:vector", result["missing_schema"])

    async def test_preflight_timeout_closes_connection_without_initializing(self):
        connection = AsyncMock()
        connection.fetch.side_effect = asyncpg.QueryCanceledError("statement timeout")
        with (
            patch.object(agent_memory, "connect", AsyncMock(return_value=connection)),
            patch.object(agent_memory, "init_db_async", AsyncMock()) as initialize,
            patch.object(agent_memory, "add_event_async", AsyncMock()) as insert,
        ):
            with self.assertRaises(asyncpg.QueryCanceledError):
                await agent_memory.self_test_async()
        initialize.assert_not_awaited()
        insert.assert_not_awaited()
        connection.close.assert_awaited_once_with(timeout=5)


if __name__ == "__main__":
    unittest.main()
