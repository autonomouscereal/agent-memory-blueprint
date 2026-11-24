import unittest
from unittest.mock import AsyncMock, patch

import asyncpg

import agent_memory


class StatusTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_uses_statistics_and_only_bounded_event_lookups(self):
        connection = AsyncMock()
        connection.fetch.return_value = [
            {"relname": "agent_memory_events", "n_live_tup": 1000000},
            {"relname": "agent_memory_spaces", "n_live_tup": 12},
            {"relname": "agent_memory_entities", "n_live_tup": 300000},
            {"relname": "agent_memory_entity_edges", "n_live_tup": 3},
            {"relname": "agent_memory_event_links", "n_live_tup": 8},
            {"relname": "agent_memory_payload_archives", "n_live_tup": 999999},
        ]
        for row in connection.fetch.return_value:
            row.update(reltuples=-1, last_analyze="2026-10-18", last_autoanalyze=None,
                       last_vacuum=None, last_autovacuum=None)
        connection.fetchval.return_value = True
        connection.fetchrow.side_effect = [
            {"newest": "2026-10-18", "oldest": "2026-05-12"},
            {"revision": 7, "mutation_revision": 2, "entries": 3, "hits": 9, "last_accessed_at": None},
            {"tracked_spaces": 4, "inserted_rows": 120, "space_mutations": 1},
        ]
        with patch.object(agent_memory, "connect", AsyncMock(return_value=connection)):
            result = await agent_memory.status_async()

        self.assertTrue(result["ok"])
        self.assertEqual(result["total"], 1000000)
        self.assertEqual(result["graph"]["payload_archives"], 999999)
        self.assertEqual(result["count_accuracy"], "estimated")
        self.assertEqual(result["count_source"], "pg_stat_user_tables.n_live_tup or pg_class.reltuples")
        self.assertEqual(result["search_cache"]["revision"], 7)
        # Per-space cache counters come from their own small table.
        self.assertEqual(result["search_cache"]["scope"], "space")
        self.assertEqual(result["search_cache"]["tracked_spaces"], 4)
        self.assertEqual(result["search_cache"]["inserted_rows"], 120)
        self.assertIsNone(result["graph"]["payload_archive_raw_chars"])
        self.assertIsNone(result["graph"]["payload_archive_compressed_bytes"])
        self.assertEqual(set(result["omitted_fields"]), {
            "top_spaces", "graph.payload_archive_raw_chars", "graph.payload_archive_compressed_bytes",
        })
        self.assertNotIn("spaces", result)
        self.assertNotIn("breakdown", result)
        # A million archived events must not turn an availability check into an
        # accounting scan. Only two indexed endpoint reads may touch events.
        corpus_queries = []
        for call in connection.mock_calls:
            if not call.args or not isinstance(call.args[0], str):
                continue
            query = " ".join(call.args[0].lower().split())
            self.assertNotIn("from agent_memory_payload_archives", query)
            if "from agent_memory_events" in query:
                corpus_queries.append(query)
                self.assertNotIn("count(", query)
                self.assertNotIn("sum(", query)
                self.assertNotIn("group by", query)
                self.assertEqual(query.count("limit 1"), 2)
                self.assertIn("order by created_at desc limit 1", query)
                self.assertIn("order by created_at asc limit 1", query)
        self.assertEqual(len(corpus_queries), 1)
        self.assertEqual(connection.mock_calls[0].args, (
            "SELECT set_config('statement_timeout', $1, false)", "5000",
        ))
        connection.close.assert_awaited_once()

    async def test_details_preserves_exact_aggregates_and_breakdowns(self):
        connection = AsyncMock()
        connection.fetchval.side_effect = [42, 2, True, False]
        connection.fetch.side_effect = [
            [{"space": "workspace/example", "events": 42}],
            [{"space": "workspace/example", "agent": "Codex", "event_type": "note", "count": 42}],
            [{"space": "workspace/example", "description": "", "parent_space": "", "events": 42}],
        ]
        graph = {
            "entities": 5, "entity_edges": 2, "event_links": 3, "payload_archives": 41,
            "payload_archive_raw_chars": 9000, "payload_archive_compressed_bytes": 2000,
        }
        connection.fetchrow.side_effect = [
            graph,
            {"newest": "2026-10-18", "oldest": "2026-05-12"},
            {"revision": 44, "mutation_revision": 2, "entries": 1, "hits": 3, "last_accessed_at": None},
        ]
        with patch.object(agent_memory, "connect", AsyncMock(return_value=connection)):
            result = await agent_memory.status_async(details=True)

        self.assertEqual(result["count_accuracy"], "exact")
        self.assertEqual(result["omitted_fields"], [])
        self.assertEqual(result["total"], 42)
        self.assertEqual(result["space_count"], 2)
        self.assertEqual(result["graph"], graph)
        self.assertEqual(result["top_spaces"][0]["events"], 42)
        self.assertEqual(result["spaces"][0]["events"], 42)
        self.assertEqual(result["breakdown"][0]["count"], 42)
        # A database that has not run the new init yet reports the old global scope.
        self.assertEqual(result["search_cache"]["scope"], "global")
        sql = " ".join(call.args[0] for call in connection.mock_calls if call.args)
        self.assertIn("SELECT count(*) AS total FROM agent_memory_events", sql)
        self.assertIn("sum(raw_chars)", sql)
        self.assertIn("sum(compressed_bytes)", sql)
        self.assertNotIn("pg_stat_user_tables", sql)
        self.assertEqual(connection.mock_calls[0].args[-1], "120000")
        connection.close.assert_awaited_once()

    async def test_timeout_is_reported_and_connection_is_closed(self):
        connection = AsyncMock()
        connection.fetch.side_effect = asyncpg.QueryCanceledError("statement timeout")
        with patch.object(agent_memory, "connect", AsyncMock(return_value=connection)):
            with self.assertRaises(asyncpg.QueryCanceledError):
                await agent_memory.status_async()
        self.assertEqual(connection.mock_calls[0].args[-1], "5000")
        connection.close.assert_awaited_once()

    async def test_missing_statistics_are_unknown_and_missing_cache_is_supported(self):
        connection = AsyncMock()
        connection.fetch.return_value = []
        connection.fetchval.return_value = False
        connection.fetchrow.return_value = {"newest": None, "oldest": None}
        with patch.object(agent_memory, "connect", AsyncMock(return_value=connection)):
            result = await agent_memory.status_async()
        self.assertIsNone(result["total"])
        self.assertIsNone(result["space_count"])
        self.assertIsNone(result["graph"]["payload_archives"])
        self.assertEqual(result["search_cache"], {"available": False})
        connection.close.assert_awaited_once()

    async def test_reset_statistics_use_catalog_or_unknown_instead_of_false_zero(self):
        connection = AsyncMock()
        connection.fetch.return_value = [
            {"relname": "agent_memory_events", "n_live_tup": 0, "reltuples": 1000000},
            {"relname": "agent_memory_spaces", "n_live_tup": 0, "reltuples": -1},
        ]
        for row in connection.fetch.return_value:
            row.update(last_analyze=None, last_autoanalyze=None, last_vacuum=None, last_autovacuum=None)
        connection.fetchval.return_value = False
        connection.fetchrow.return_value = {"newest": None, "oldest": None}
        with patch.object(agent_memory, "connect", AsyncMock(return_value=connection)):
            result = await agent_memory.status_async()
        self.assertEqual(result["total"], 1000000)
        self.assertIsNone(result["space_count"])
        self.assertEqual(result["count_accuracy"], "estimated")


if __name__ == "__main__":
    unittest.main()
