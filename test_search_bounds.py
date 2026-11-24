"""Bounded search legs and the per-space search cache.

These run against a scripted connection, so they pin the SQL shapes that keep
search and grep inside their timeouts on a 1.5M-row table: newest-first
full-text pools instead of ranking every match, per-leg timeouts that degrade
instead of failing, and cache entries validated by per-space counters. The
live check is test_search_live.py.
"""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import asyncpg

import agent_memory


class FakeTransaction:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        self.conn.depth += 1
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self.conn.depth -= 1
        return False


class FakeConnection:
    """Answers fetch/fetchrow/fetchval by the first rule whose marker is in the SQL."""

    def __init__(self, rules):
        self.rules = rules
        self.calls = []
        self.depth = 0
        self.closed = False

    def transaction(self, **_kwargs):
        return FakeTransaction(self)

    def _answer(self, kind, sql, args):
        flat = " ".join(sql.split())
        self.calls.append((kind, flat, args))
        for marker, answer in self.rules:
            if marker in flat:
                if isinstance(answer, BaseException):
                    raise answer
                return answer(args) if callable(answer) else answer
        raise AssertionError(f"unexpected {kind}: {' '.join(sql.split())[:160]}")

    async def execute(self, sql, *args, **_kwargs):
        self.calls.append(("execute", " ".join(sql.split()), args))
        return "OK"

    async def fetch(self, sql, *args, **_kwargs):
        return self._answer("fetch", sql, args)

    async def fetchrow(self, sql, *args, **_kwargs):
        return self._answer("fetchrow", sql, args)

    async def fetchval(self, sql, *args, **_kwargs):
        return self._answer("fetchval", sql, args)

    async def close(self, **_kwargs):
        self.closed = True

    def sql(self, kind=None):
        return [sql for call_kind, sql, _args in self.calls if kind is None or call_kind == kind]


def scored(row_id, score, **extra):
    row = {
        "id": row_id, "created_at": "2026-11-24T00:00:00+00:00", "space": "workspace/a", "session_id": None,
        "agent": "Codex", "event_type": "note", "memory_kind": "note", "role": None, "source": None,
        "summary": "", "tags": [], "metadata": {}, "content": f"row {row_id}", "semantic_score": score,
        "text_score": 0.1, "trigram_score": 0.0, "lexical_match": True, "score": score,
    }
    row.update(extra)
    return row


def base_rules(max_id=1000, cache_row=None, state=None, text_recent=(), text_older=(), vector=(), partial=None,
               score_rows=None, in_range=None):
    state = state or {"inserted_rows": 50, "mutation_revision": 0}
    partial = partial if partial is not None else []
    score_rows = score_rows if score_rows is not None else []
    rules = [
        ("COALESCE(max(id), 0)", max_id),
        ("to_regclass('public.agent_memory_space_search_state') IS NOT NULL", True),
        ("FROM agent_memory_space_search_state", state),
        ("FROM agent_memory_search_cache cache", cache_row),
        ("SELECT count(*)", in_range),
        # The older pass in a space (bitmap scans only); it ends like the recent pass.
        ("AND (id + 0) > $2 AND (id + 0) <= $3 ORDER BY id DESC LIMIT $4", lambda args: [{"id": i} for i in text_older]),
        ("ORDER BY id DESC LIMIT $4", lambda args: [{"id": i} for i in text_recent]),
        ("OFFSET 0", lambda args: [{"id": i} for i in text_older]),
        ("ORDER BY ts_rank_cd(search_vector", lambda args: [{"id": i} for i in list(args[1])[:args[2]]]),
        ("partial_score", partial),
        ("AS score", score_rows),
        ("<=> $1::VECTOR", lambda args: [{"id": i} for i in vector]),
    ]
    return rules


class ScriptBytecodeCacheTests(unittest.TestCase):
    """Run as a script under PYTHONDONTWRITEBYTECODE=1, the CLI caches bytecode in .pycache beside itself."""

    def run_help(self, folder, **env_extra):
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "AGENT_MEMORY_ENV_FILE": str(Path(folder) / "no.env"),
               **env_extra}
        return subprocess.run([sys.executable, str(Path(folder) / "agent_memory.py"), "--help"], capture_output=True,
                              text=True, env=env, timeout=120, check=True)

    def test_script_run_writes_and_reuses_its_own_cache(self):
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(agent_memory.__file__, Path(folder) / "agent_memory.py")
            self.assertIn("grep", self.run_help(folder).stdout)
            cached = [p.name for p in (Path(folder) / ".pycache").rglob("*.pyc")]
            self.assertTrue(any(name.startswith("asyncio") or name.startswith("base_events") for name in cached), cached[:10])
            self.assertTrue(any(name.startswith("asyncpg") or name.startswith("connection.") for name in cached), cached[:10])
            before = {p: p.stat().st_mtime_ns for p in (Path(folder) / ".pycache").rglob("*.pyc")}
            self.run_help(folder)
            after = {p: p.stat().st_mtime_ns for p in (Path(folder) / ".pycache").rglob("*.pyc")}
            self.assertEqual(before, after, "the second run must read the cache, not rewrite it")

    def test_opt_out_and_module_import_leave_bytecode_alone(self):
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            shutil.copyfile(agent_memory.__file__, Path(folder) / "agent_memory.py")
            self.run_help(folder, AGENT_MEMORY_PYCACHE="0")
            self.assertFalse((Path(folder) / ".pycache").exists())
        # This test process imported agent_memory as a module: no prefix was set.
        self.assertIsNone(sys.pycache_prefix)


class StemTokenTests(unittest.TestCase):
    def test_variants_keep_a_stable_order(self):
        self.assertEqual(agent_memory.stem_token("Hermes"), ["hermes", "herme"])
        self.assertEqual(agent_memory.stem_token("libraries"), ["libraries", "library", "librarie"])

    def test_query_vector_is_the_same_under_any_hash_seed(self):
        # Set order follows PYTHONHASHSEED; the embedding must not.
        backend = str(Path(agent_memory.__file__).resolve().parent)
        code = (
            "import sys; sys.path.insert(0, sys.argv[1]); import agent_memory as m; "
            "print(m.vector_literal(m.cpu_embedding('how do I restart the hermes gateway safely')))"
        )
        vectors = set()
        for seed in ("1", "2", "3", "4"):
            env = {**os.environ, "PYTHONHASHSEED": seed}
            done = subprocess.run([sys.executable, "-c", code, backend], capture_output=True, text=True, env=env,
                                  timeout=60, check=True)
            vectors.add(done.stdout.strip())
        self.assertEqual(len(vectors), 1)


class ScopeFilterTests(unittest.TestCase):
    def test_numbering_and_all_spaces(self):
        conditions, values = agent_memory.scope_filters(
            5, space="Workspace/A", agent="Codex", tags=["x"], since=None,
        )
        self.assertEqual(conditions, ["space = $5", "agent = $6", "tags && $7::TEXT[]"])
        self.assertEqual(values, ["workspace/a", "Codex", ["x"]])
        conditions, values = agent_memory.scope_filters(2, space="workspace/a", all_spaces=True)
        self.assertEqual((conditions, values), ([], []))


class NewestTextMatchTests(unittest.IsolatedAsyncioTestCase):
    async def test_common_word_stops_in_the_recent_window(self):
        conn = FakeConnection(base_rules(text_recent=range(1000, 990, -1)))
        budget = agent_memory.SearchBudget(15000, 5000)
        ids = await agent_memory.newest_text_match_ids(
            conn, budget, tsquery_function="plainto_tsquery", query="memory",
            scope={"space": "workspace/a"}, need=10, upper_id=1000, window=200,
        )
        self.assertEqual(ids, list(range(1000, 990, -1)))
        fetches = conn.sql("fetch")
        self.assertEqual(len(fetches), 1, "a filled pool must not scan older rows")
        recent = fetches[0]
        # Bounded by the id window, newest first, scope test before the tsvector test.
        self.assertIn("space = $5 AND id > $2 AND id <= $3 AND search_vector @@ plainto_tsquery('english', $1)", recent)
        self.assertIn("ORDER BY id DESC LIMIT $4", recent)
        self.assertNotIn("ts_rank_cd", recent)
        args = [args for kind, _sql, args in conn.calls if kind == "fetch"][0]
        self.assertEqual(args[:4], ("memory", 800, 1000, 10))

    async def test_rare_word_reads_older_rows_through_the_gin_index_only(self):
        conn = FakeConnection(base_rules(text_recent=[999], text_older=[40, 7]))
        budget = agent_memory.SearchBudget(15000, 5000)
        ids = await agent_memory.newest_text_match_ids(
            conn, budget, tsquery_function="websearch_to_tsquery", query="zygote",
            scope={"agent": "Codex"}, need=10, upper_id=1000, window=200,
        )
        self.assertEqual(ids, [999, 40, 7])
        older = conn.sql("fetch")[1]
        self.assertIn("OFFSET 0", older)
        self.assertIn("(id + 0) > $2 AND (id + 0) <= $3", older)
        self.assertIn("WHERE agent = $5 ORDER BY m.id DESC LIMIT $4", older)
        executes = conn.sql("execute")
        self.assertIn("SELECT set_config('enable_seqscan', 'off', true)", executes)
        self.assertNotIn("SELECT set_config('enable_indexscan', 'off', true)", executes)
        self.assertEqual(executes[-1], "SELECT set_config('enable_seqscan', 'on', true)")
        args = [args for kind, _sql, args in conn.calls if kind == "fetch"][1]
        self.assertEqual(args[:4], ("zygote", 0, 800, 9))

    async def test_older_pass_in_a_space_lets_the_planner_and_the_space_index(self):
        conn = FakeConnection(base_rules(text_recent=[999], text_older=[40, 7]))
        budget = agent_memory.SearchBudget(15000, 5000)
        ids = await agent_memory.newest_text_match_ids(
            conn, budget, tsquery_function="plainto_tsquery", query="memory",
            scope={"space": "workspace/a"}, need=10, upper_id=1000, window=200,
        )
        self.assertEqual(ids, [999, 40, 7])
        older = conn.sql("fetch")[1]
        # No OFFSET 0 fence: the space test and the tsvector test sit in one scan,
        # so the planner can AND the space index bitmap with the GIN bitmap.
        self.assertNotIn("OFFSET 0", older)
        self.assertIn("WHERE space = $5 AND search_vector @@ plainto_tsquery('english', $1) "
                      "AND (id + 0) > $2 AND (id + 0) <= $3 ORDER BY id DESC LIMIT $4", older)
        executes = conn.sql("execute")
        # Bitmap scans only: no seq scan and no row-by-row index walk.
        self.assertIn("SELECT set_config('enable_seqscan', 'off', true)", executes)
        self.assertIn("SELECT set_config('enable_indexscan', 'off', true)", executes)
        self.assertEqual(executes[-2:], ["SELECT set_config('enable_seqscan', 'on', true)",
                                         "SELECT set_config('enable_indexscan', 'on', true)"])
        args = [args for kind, _sql, args in conn.calls if kind == "fetch"][1]
        self.assertEqual(args[:5], ("memory", 0, 800, 9, "workspace/a"))

    async def test_enough_recent_matches_skip_the_older_pass(self):
        conn = FakeConnection(base_rules(text_recent=[999, 998, 997], text_older=[5]))
        budget = agent_memory.SearchBudget(15000, 5000)
        ids = await agent_memory.newest_text_match_ids(
            conn, budget, tsquery_function="plainto_tsquery", query="memory",
            scope={}, need=10, enough=3, upper_id=1000, window=200,
        )
        self.assertEqual(ids, [999, 998, 997])
        self.assertFalse([sql for sql in conn.sql("fetch") if "OFFSET 0" in sql])

    async def test_unknown_tsquery_function_is_refused(self):
        with self.assertRaises(ValueError):
            await agent_memory.newest_text_match_ids(
                FakeConnection([]), agent_memory.SearchBudget(1000, 1000), tsquery_function="to_tsquery); --",
                query="x", scope={}, need=1, upper_id=10, window=5,
            )


class SearchBudgetTests(unittest.IsolatedAsyncioTestCase):
    async def test_a_timed_out_leg_is_skipped_not_raised(self):
        conn = FakeConnection([("SELECT 1", asyncpg.QueryCanceledError("statement timeout"))])
        budget = agent_memory.SearchBudget(15000, 2000)
        self.assertIsNone(await budget.fetch(conn, "vector", "SELECT 1"))
        self.assertFalse(budget.complete)
        self.assertEqual(budget.legs[0]["status"], "timeout")
        self.assertIn("SELECT set_config('statement_timeout', $1, true)", conn.sql("execute"))

    async def test_no_time_left_skips_the_query(self):
        conn = FakeConnection([])
        budget = agent_memory.SearchBudget(15000, 2000)
        budget.deadline = 0
        self.assertIsNone(await budget.fetch(conn, "vector", "SELECT 1"))
        self.assertEqual(conn.sql("fetch"), [])


class SearchCacheTests(unittest.IsolatedAsyncioTestCase):
    async def run_search(self, conn, **kwargs):
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            return await agent_memory.search_events_async("memory hooks", limit=2, **kwargs)

    async def test_cold_search_ranks_a_bounded_pool_and_stores_per_space_counters(self):
        conn = FakeConnection(base_rules(
            text_recent=[900, 800], vector=[700], partial=[{"id": 900, "partial_score": 0.9},
                                                            {"id": 800, "partial_score": 0.5},
                                                            {"id": 700, "partial_score": 0.1}],
            score_rows=[scored(900, 0.95), scored(800, 0.55)],
        ))
        results = await self.run_search(conn, space="workspace/a")
        self.assertEqual([row["id"] for row in results], [900, 800])
        # 700 is more than 0.10 below the 2nd best partial score, so it is not fully scored.
        score_args = [args for kind, sql, args in conn.calls if kind == "fetch" and "AS score" in sql][0]
        self.assertEqual(score_args[2], [900, 800])
        joined = " ".join(conn.sql())
        self.assertNotIn("ILIKE", joined)
        self.assertIn("SET hnsw.iterative_scan = relaxed_order", joined)
        self.assertIn("set_config('max_parallel_workers_per_gather', '0', true)", joined)
        inserts = [args for kind, sql, args in conn.calls if kind == "execute" and "INSERT INTO agent_memory_search_cache" in sql]
        self.assertEqual(len(inserts), 1)
        self.assertEqual(inserts[0][1:4], (50, 0, 1000))
        state_sql = [sql for sql in conn.sql("fetchrow") if "agent_memory_space_search_state" in sql][0]
        self.assertIn("WHERE space = $1", state_sql)
        self.assertTrue(conn.closed)

    async def test_full_hit_when_the_space_counters_are_unchanged(self):
        cached = {"revision": 50, "mutation_revision": 0, "max_event_id": 400,
                  "results": [scored(300, 0.8)]}
        conn = FakeConnection(base_rules(cache_row=cached))
        results = await self.run_search(conn, space="workspace/a")
        self.assertEqual([row["id"] for row in results], [300])
        # Writes elsewhere moved max(id) from 400 to 1000; the entry is still valid.
        self.assertFalse([sql for sql in conn.sql("fetch") if "agent_memory_events" in sql])
        self.assertTrue([sql for sql in conn.sql("execute") if "hit_count = hit_count + 1" in sql])

    async def test_delta_scores_only_the_new_id_range_and_merges(self):
        cached = {"revision": 48, "mutation_revision": 0, "max_event_id": 900,
                  "results": [scored(300, 0.8)]}
        conn = FakeConnection(base_rules(
            cache_row=cached, in_range=2, text_recent=[950], vector=[960],
            partial=[{"id": 950, "partial_score": 0.9}, {"id": 960, "partial_score": 0.85}],
            score_rows=[scored(950, 0.9), scored(960, 0.85)],
        ))
        results = await self.run_search(conn, space="workspace/a")
        self.assertEqual([row["id"] for row in results], [950, 960])
        count_call = [(sql, args) for kind, sql, args in conn.calls if kind == "fetchval" and "count(*)" in sql][0]
        self.assertIn("space = $3 AND id > $1 AND id <= $2", count_call[0])
        self.assertEqual(count_call[1], (900, 1000, "workspace/a"))
        vector_call = [(sql, args) for kind, sql, args in conn.calls if kind == "fetch" and "<=> $1::VECTOR" in sql][0]
        self.assertIn("(embedding <=> $1::VECTOR) + 0", vector_call[0])
        self.assertEqual(vector_call[1][-2:], (900, 1000))
        self.assertFalse([sql for sql in conn.sql("fetch") if "OFFSET 0" in sql])
        stored = [args for kind, sql, args in conn.calls if kind == "execute" and "INSERT INTO agent_memory_search_cache" in sql]
        self.assertEqual(stored[0][1:4], (50, 0, 1000))
        self.assertTrue(stored[0][6], "a delta refresh counts as a hit")

    async def test_out_of_order_commit_forces_a_full_search(self):
        cached = {"revision": 48, "mutation_revision": 0, "max_event_id": 900, "results": [scored(300, 0.8)]}
        conn = FakeConnection(base_rules(
            cache_row=cached, in_range=1, text_recent=[950], partial=[{"id": 950, "partial_score": 0.9}],
            score_rows=[scored(950, 0.9)],
        ))
        results = await self.run_search(conn, space="workspace/a")
        self.assertEqual([row["id"] for row in results], [950])
        vector_sql = [sql for sql in conn.sql("fetch") if "<=> $1::VECTOR" in sql and "partial" not in sql][0]
        self.assertNotIn("+ 0", vector_sql, "the full path uses the HNSW order")

    async def test_mutation_forces_a_full_search(self):
        cached = {"revision": 50, "mutation_revision": 3, "max_event_id": 900, "results": [scored(300, 0.8)]}
        conn = FakeConnection(base_rules(
            cache_row=cached, state={"inserted_rows": 50, "mutation_revision": 4}, text_recent=[950],
            partial=[{"id": 950, "partial_score": 0.9}], score_rows=[scored(950, 0.9)],
        ))
        results = await self.run_search(conn, space="workspace/a")
        self.assertEqual([row["id"] for row in results], [950])

    async def test_all_spaces_sums_the_counters(self):
        conn = FakeConnection(base_rules(text_recent=[950], partial=[{"id": 950, "partial_score": 0.9}],
                                         score_rows=[scored(950, 0.9)]))
        await self.run_search(conn, all_spaces=True)
        state_sql = [sql for sql in conn.sql("fetchrow") if "agent_memory_space_search_state" in sql][0]
        self.assertIn("sum(inserted_rows)", state_sql)
        recent = [sql for sql in conn.sql("fetch") if "ORDER BY id DESC LIMIT $4" in sql][0]
        self.assertNotIn("space =", recent)

    async def test_timed_out_vector_leg_still_answers_and_skips_the_cache(self):
        rules = base_rules(text_recent=[950], partial=[{"id": 950, "partial_score": 0.9}],
                           score_rows=[scored(950, 0.9)])
        rules.insert(0, ("ORDER BY embedding <=> $1::VECTOR", asyncpg.QueryCanceledError("statement timeout")))
        conn = FakeConnection(rules)
        results = await self.run_search(conn, all_spaces=True)
        self.assertEqual([row["id"] for row in results], [950])
        self.assertFalse([sql for sql in conn.sql("execute") if "INSERT INTO agent_memory_search_cache" in sql])

    async def test_cache_write_conflict_does_not_fail_the_search(self):
        conn = FakeConnection(base_rules(text_recent=[950], partial=[{"id": 950, "partial_score": 0.9}],
                                         score_rows=[scored(950, 0.9)]))
        original = conn.execute

        async def execute(sql, *args, **kwargs):
            if "INSERT INTO agent_memory_search_cache" in sql:
                raise asyncpg.SerializationError("could not serialize access due to concurrent update")
            return await original(sql, *args, **kwargs)

        conn.execute = execute
        results = await self.run_search(conn, all_spaces=True)
        self.assertEqual([row["id"] for row in results], [950])

    async def test_old_schema_searches_without_a_cache(self):
        rules = base_rules(text_recent=[950], partial=[{"id": 950, "partial_score": 0.9}],
                           score_rows=[scored(950, 0.9)])
        rules.insert(0, ("to_regclass('public.agent_memory_space_search_state') IS NOT NULL", False))
        conn = FakeConnection(rules)
        results = await self.run_search(conn, all_spaces=True)
        self.assertEqual([row["id"] for row in results], [950])
        self.assertFalse([sql for sql in conn.sql() if "agent_memory_search_cache" in sql and "to_regclass" not in sql])


class GrepTests(unittest.IsolatedAsyncioTestCase):
    async def test_full_text_grep_ranks_only_the_newest_pool(self):
        conn = FakeConnection(base_rules(text_recent=[990, 980], score_rows=[scored(990, 0.4), scored(980, 0.2)]))
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            rows = await agent_memory.grep_events_async("memory", limit=2, all_spaces=True)
        self.assertEqual([row["id"] for row in rows], [990, 980])
        rank_call = [(sql, args) for kind, sql, args in conn.calls if kind == "fetch" and "AS score" in sql][0]
        self.assertIn("WHERE e.id = ANY($2::BIGINT[])", rank_call[0])
        self.assertIn("websearch_to_tsquery('english', $1)", rank_call[0])
        self.assertEqual(rank_call[1][1], [990, 980])

    async def test_contains_walks_newest_slices_and_stops_when_full(self):
        slices = []

        def substring(args):
            slices.append(args[1:4])
            return [{"id": i} for i in range(args[2], args[2] - 3, -1)][:args[3]]

        rules = [
            ("COALESCE(max(id), 0)", 100000),
            ("content ILIKE", substring),
            ("AS score", lambda args: [scored(i, 0.3) for i in args[1]]),
        ]
        conn = FakeConnection(rules)
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            await agent_memory.grep_events_async("Broken pipe", limit=5, all_spaces=True, contains=True)
        # need = 2 x limit = 10; fixed 20k-id slices from the newest, 3 matches each, stop at 10.
        self.assertEqual(slices[0], (80000, 100000, 10))
        self.assertEqual(slices[1], (60000, 80000, 7))
        self.assertEqual(slices[-1], (20000, 40000, 1))
        self.assertEqual(len(slices), 4)
        sql = [sql for sql in conn.sql("fetch") if "ILIKE" in sql][0]
        self.assertIn("id > $2 AND id <= $3 AND content ILIKE '%' || $1 || '%'", sql)
        self.assertIn("ORDER BY id DESC LIMIT $4", sql)


def audit_row(row_id):
    return {"id": row_id, "created_at": "2026-11-24T00:00:00+00:00", "space": "workspace/a", "session_id": "s",
            "agent": "ClaudeCode", "event_type": "tool_call", "memory_kind": "hook", "role": None, "source": None,
            "summary": "", "tags": [], "metadata": {}, "content": ""}


class AuditTests(unittest.IsolatedAsyncioTestCase):
    async def test_identity_filters_are_one_equality_per_field(self):
        conn = FakeConnection([("ORDER BY created_at DESC", [audit_row(9)])])
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            rows = await agent_memory.audit_events_async(
                limit=5, harness="codex", model_id="gpt-6-astra", provider="openai", thread_id="t1", all_spaces=True,
            )
        self.assertEqual([row["id"] for row in rows], [9])
        sql = conn.sql("fetch")[0]
        self.assertIn(
            "WHERE (metadata->'identity'->>'model_id') = $1 AND (metadata->'identity'->>'harness') = $2 "
            "AND (metadata->'identity'->>'thread_id') = $3 AND (metadata->'identity'->>'model_provider') = $4", sql)
        self.assertNotIn("@>", sql)
        args = [args for kind, _sql, args in conn.calls if kind == "fetch"][0]
        self.assertEqual(args, ("gpt-6-astra", "codex", "t1", "openai", 5))

    def test_every_audit_identity_field_has_an_index(self):
        self.assertEqual(agent_memory.IDENTITY_AUDIT_KEYS, ("harness", "model_provider", "model_id", "thread_id"))

    async def test_session_audit_runs_one_plain_query(self):
        conn = FakeConnection([("ORDER BY created_at DESC", [audit_row(3)])])
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            rows = await agent_memory.audit_events_async(limit=20, session_id="s", all_spaces=True)
        self.assertEqual([row["id"] for row in rows], [3])
        self.assertEqual(conn.sql("execute"), [])
        self.assertIn("WHERE session_id = $1", conn.sql("fetch")[0])


class SpaceCountTests(unittest.IsolatedAsyncioTestCase):
    async def test_listing_reads_the_maintained_counts(self):
        conn = FakeConnection([
            ("attname = 'event_count'", True),
            ("LEFT JOIN agent_memory_space_search_state c", [{"space": "workspace/a", "event_count": 7}]),
        ])
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            rows = await agent_memory.list_spaces_async()
        self.assertEqual(rows, [{"space": "workspace/a", "event_count": 7}])
        self.assertFalse([sql for sql in conn.sql("fetch") if "count(e.id)" in sql])

    async def test_listing_counts_rows_until_init_installs_the_triggers(self):
        conn = FakeConnection([
            ("attname = 'event_count'", False),
            ("count(e.id) AS event_count", [{"space": "workspace/a", "event_count": 7}]),
        ])
        with patch.object(agent_memory, "connect", AsyncMock(return_value=conn)):
            rows = await agent_memory.list_spaces_async()
        self.assertEqual(rows[0]["event_count"], 7)

    async def test_first_count_locks_inserts_before_counting(self):
        conn = FakeConnection([("attname = 'event_count'", False)])
        result = await agent_memory.ensure_space_counts_async(conn)
        self.assertTrue(result["recounted"])
        executes = conn.sql("execute")
        self.assertEqual(executes[0], "LOCK TABLE agent_memory_events IN SHARE MODE")
        self.assertIn("ADD COLUMN IF NOT EXISTS event_count BIGINT", executes[1])
        self.assertTrue(any("CREATE TRIGGER agent_memory_events_count_insert_trg" in sql for sql in executes))
        self.assertTrue(any("AFTER DELETE OR UPDATE OF space ON agent_memory_events" in sql for sql in executes))
        # Zero first, so a space whose rows were all deleted reads 0, then the exact counts.
        self.assertEqual(executes[-2], "UPDATE agent_memory_space_search_state SET event_count = 0")
        self.assertIn("SELECT space, count(*), NOW() FROM agent_memory_events GROUP BY space", executes[-1])

    async def test_trigram_index_is_switched_to_direct_writes_once(self):
        conn = FakeConnection([("SELECT reloptions FROM pg_class", None), ("gin_clean_pending_list", 12)])
        self.assertTrue(await agent_memory._ensure_trigram_fastupdate_off(conn))
        self.assertEqual(conn.sql("execute"), ["ALTER INDEX agent_memory_events_content_trgm_idx SET (fastupdate = off)"])
        # The list it already holds is flushed once, after the switch.
        self.assertIn("gin_clean_pending_list('agent_memory_events_content_trgm_idx'::regclass)", conn.sql("fetchval")[-1])
        for chosen in (["fastupdate=off"], ["fastupdate=on"]):
            conn = FakeConnection([("SELECT reloptions FROM pg_class", chosen)])
            self.assertFalse(await agent_memory._ensure_trigram_fastupdate_off(conn))
            self.assertEqual(conn.sql("execute"), [])

    async def test_maintained_counts_take_no_lock(self):
        conn = FakeConnection([("attname = 'event_count'", True)])
        result = await agent_memory.ensure_space_counts_async(conn)
        self.assertFalse(result["recounted"])
        self.assertEqual(conn.sql("execute"), [])


if __name__ == "__main__":
    unittest.main()
