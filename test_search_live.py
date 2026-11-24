"""Live check of the per-space search cache and bounded search.

Opt-in: runs only with AGENT_MEMORY_LIVE_TESTS=1, against whatever MEMORY_DB_*
points at. Use a throwaway database: the test runs init and writes rows in its
own "live-test/<run>" spaces (it never deletes). Example:

    docker run --rm -d --name am-live -p 127.0.0.1:55491:5432 \
        -e POSTGRES_USER=agent_memory -e POSTGRES_DB=agent_memory \
        -e POSTGRES_PASSWORD="$(python -c 'import secrets; print(secrets.token_hex(16))')" pgvector/pgvector:pg16
    AGENT_MEMORY_LIVE_TESTS=1 MEMORY_DB_HOST=127.0.0.1 MEMORY_DB_PORT=55491 MEMORY_DB_PASSWORD=... \
        python -m unittest test_search_live
"""
import asyncio
import os
import unittest
import uuid

import agent_memory

LIVE = os.getenv("AGENT_MEMORY_LIVE_TESTS", "").strip() == "1"


async def add(space, content, **kwargs):
    return await agent_memory.add_event_async(
        agent="LiveTest", event_type="note", space=space, memory_kind="note", source="test_search_live",
        content=content, index_entities=False, **kwargs,
    )


async def cache_row(key):
    conn = await agent_memory.connect()
    try:
        return await conn.fetchrow(
            "SELECT revision, mutation_revision, max_event_id, hit_count, result_count FROM agent_memory_search_cache WHERE cache_key = $1",
            key,
        )
    finally:
        await conn.close()


async def space_state(space):
    conn = await agent_memory.connect()
    try:
        return await conn.fetchrow(
            "SELECT inserted_rows, mutation_revision FROM agent_memory_space_search_state WHERE space = $1", space,
        )
    finally:
        await conn.close()


def key_for(query, space="", all_spaces=False, limit=5):
    return agent_memory.search_cache_key(
        query, limit=limit, space=space, all_spaces=all_spaces, agent="", event_type="", memory_kind="", tags=None,
        min_score=agent_memory.DEFAULT_MIN_SEARCH_SCORE, candidate_limit=agent_memory.search_candidate_limit(limit),
        phrase_candidates=False,
    )


@unittest.skipUnless(LIVE, "set AGENT_MEMORY_LIVE_TESTS=1 and point MEMORY_DB_* at a throwaway database")
class LiveSearchCacheTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        asyncio.run(agent_memory.init_db_async())
        # init is idempotent: a second run must not fail or duplicate triggers.
        asyncio.run(agent_memory.init_db_async())

    def setUp(self):
        run = uuid.uuid4().hex[:10]
        self.space_a = f"live-test/{run}/alpha"
        self.space_b = f"live-test/{run}/beta"
        self.marker = f"zebracorn{run}"

    async def test_triggers_count_inserts_and_mutations_per_space(self):
        await add(self.space_a, f"{self.marker} first")
        await add(self.space_a, f"{self.marker} second")
        await add(self.space_b, f"{self.marker} other space")
        self.assertEqual(dict(await space_state(self.space_a)), {"inserted_rows": 2, "mutation_revision": 0})
        self.assertEqual(dict(await space_state(self.space_b)), {"inserted_rows": 1, "mutation_revision": 0})
        uid = f"{self.marker}-fixed"
        await add(self.space_a, f"{self.marker} third", event_uid=uid)
        await add(self.space_a, f"{self.marker} third, edited", event_uid=uid)  # ON CONFLICT DO UPDATE
        self.assertEqual(dict(await space_state(self.space_a)), {"inserted_rows": 3, "mutation_revision": 1})
        conn = await agent_memory.connect()
        try:
            triggers = await conn.fetch(
                """
                SELECT tgname FROM pg_trigger
                WHERE tgrelid = 'agent_memory_events'::regclass AND NOT tgisinternal
                ORDER BY tgname
                """
            )
        finally:
            await conn.close()
        names = [row["tgname"] for row in triggers]
        self.assertEqual(names.count("agent_memory_events_scope_insert_trg"), 1)
        self.assertEqual(names.count("agent_memory_events_scope_mutation_trg"), 1)

    async def test_cache_hit_survives_other_spaces_and_merges_new_rows(self):
        query = f"{self.marker} report"
        await add(self.space_a, f"{self.marker} report one")
        await add(self.space_a, f"{self.marker} report two", event_uid=f"{self.marker}-two")
        key = key_for(query, space=self.space_a)

        cold = await agent_memory.search_events_async(query, space=self.space_a, limit=5)
        self.assertEqual(len(cold), 2)
        entry = await cache_row(key)
        self.assertEqual((entry["revision"], entry["hit_count"]), (2, 0))

        # Another space's write leaves this space's entry valid: a full hit.
        await add(self.space_b, f"{self.marker} report elsewhere")
        hit = await agent_memory.search_events_async(query, space=self.space_a, limit=5)
        self.assertEqual([row["id"] for row in hit], [row["id"] for row in cold])
        self.assertEqual((await cache_row(key))["hit_count"], 1)

        # A new row in this space is scored as a delta and merged in.
        newest = await add(self.space_a, f"{self.marker} report three")
        merged = await agent_memory.search_events_async(query, space=self.space_a, limit=5)
        self.assertIn(newest["id"], [row["id"] for row in merged])
        entry = await cache_row(key)
        self.assertEqual((entry["revision"], entry["hit_count"]), (3, 2))

        # An update forces a fresh search and resets the entry.
        await add(self.space_a, f"{self.marker} report two, edited", event_uid=f"{self.marker}-two")
        fresh = await agent_memory.search_events_async(query, space=self.space_a, limit=5)
        self.assertEqual(len(fresh), 3)
        entry = await cache_row(key)
        self.assertEqual((entry["mutation_revision"], entry["hit_count"]), (1, 0))

    async def test_all_spaces_entry_merges_writes_from_any_space(self):
        query = f"{self.marker} audit"
        await add(self.space_a, f"{self.marker} audit alpha")
        first = await agent_memory.search_events_async(query, all_spaces=True, limit=5)
        self.assertEqual(len(first), 1)
        added = await add(self.space_b, f"{self.marker} audit beta")
        second = await agent_memory.search_events_async(query, all_spaces=True, limit=5)
        self.assertIn(added["id"], [row["id"] for row in second])

    async def test_row_committed_after_a_cached_search_is_found(self):
        # A writer's open transaction holds its space's counter row (and the
        # legacy global revision row) until commit, so a second writer would
        # wait for it; this test keeps one writer open while it searches.
        query = f"{self.marker} late"
        await add(self.space_a, f"{self.marker} late first")
        late_conn = await agent_memory.connect()
        try:
            transaction = late_conn.transaction()
            await transaction.start()
            late = await agent_memory.add_event_async(
                agent="LiveTest", event_type="note", space=self.space_a, memory_kind="note",
                source="test_search_live", content=f"{self.marker} late straggler", index_entities=False,
                conn=late_conn,
            )
            cached = await agent_memory.search_events_async(query, space=self.space_a, limit=5)
            self.assertNotIn(late["id"], [row["id"] for row in cached])
            await transaction.commit()
        finally:
            await late_conn.close()
        after = await agent_memory.search_events_async(query, space=self.space_a, limit=5)
        self.assertIn(late["id"], [row["id"] for row in after])
        entry = await cache_row(key_for(query, space=self.space_a))
        self.assertEqual((entry["revision"], entry["hit_count"]), (2, 1), "the straggler arrived as a delta")

    async def test_concurrent_writers_keep_exact_counts(self):
        await asyncio.gather(*(add(self.space_a, f"{self.marker} parallel {n}") for n in range(20)))
        self.assertEqual((await space_state(self.space_a))["inserted_rows"], 20)

    async def test_grep_modes(self):
        await add(self.space_a, f"{self.marker} Broken pipe while writing")
        await add(self.space_a, f"{self.marker} unrelated")
        rows = await agent_memory.grep_events_async(self.marker, space=self.space_a, limit=5)
        self.assertEqual(len(rows), 2)
        rows = await agent_memory.grep_events_async("Broken pipe", space=self.space_a, limit=5, contains=True)
        self.assertEqual(len(rows), 1)
        self.assertIn("Broken pipe", rows[0]["content"])


async def space_counts(*spaces):
    conn = await agent_memory.connect()
    try:
        rows = await conn.fetch(
            """
            SELECT s.space, s.event_count, (SELECT count(*) FROM agent_memory_events e WHERE e.space = s.space) AS actual
            FROM agent_memory_space_search_state s WHERE s.space = ANY($1::text[])
            """,
            list(spaces),
        )
    finally:
        await conn.close()
    return {row["space"]: (row["event_count"], row["actual"]) for row in rows}


@unittest.skipUnless(LIVE, "set AGENT_MEMORY_LIVE_TESTS=1 and point MEMORY_DB_* at a throwaway database")
class LiveSpaceCountTests(unittest.IsolatedAsyncioTestCase):
    """Per-space event counts kept by row triggers (spaces listing without a table scan)."""

    @classmethod
    def setUpClass(cls):
        asyncio.run(agent_memory.init_db_async())

    def setUp(self):
        run = uuid.uuid4().hex[:10]
        self.space_a = f"live-test/{run}/count-a"
        self.space_b = f"live-test/{run}/count-b"
        self.marker = f"countcorn{run}"

    async def test_inserts_upserts_moves_and_deletes_keep_exact_counts(self):
        for n in range(3):
            await add(self.space_a, f"{self.marker} a{n}")
        await add(self.space_b, f"{self.marker} b0")
        self.assertEqual(await space_counts(self.space_a, self.space_b), {self.space_a: (3, 3), self.space_b: (1, 1)})
        # The same uid again is an update in place: no new row, no count change.
        uid = f"{self.marker}-fixed"
        await add(self.space_a, f"{self.marker} fixed", event_uid=uid)
        await add(self.space_a, f"{self.marker} fixed, edited", event_uid=uid)
        self.assertEqual((await space_counts(self.space_a))[self.space_a], (4, 4))
        # The upsert moves a row when the new space is not global.
        await add(self.space_b, f"{self.marker} fixed, moved", event_uid=uid)
        self.assertEqual(await space_counts(self.space_a, self.space_b), {self.space_a: (3, 3), self.space_b: (2, 2)})
        conn = await agent_memory.connect()
        try:
            await conn.execute("DELETE FROM agent_memory_events WHERE event_uid = $1", uid)
            # Both directions of a move, in one statement each.
            await conn.execute("UPDATE agent_memory_events SET space = $2 WHERE space = $1", self.space_b, self.space_a)
            await conn.execute(
                "UPDATE agent_memory_events SET space = $2 WHERE id = (SELECT min(id) FROM agent_memory_events WHERE space = $1)",
                self.space_a, self.space_b,
            )
        finally:
            await conn.close()
        self.assertEqual(await space_counts(self.space_a, self.space_b), {self.space_a: (3, 3), self.space_b: (1, 1)})

    async def test_concurrent_writers_and_listing(self):
        await asyncio.gather(*(add(self.space_a if n % 2 else self.space_b, f"{self.marker} p{n}") for n in range(30)))
        self.assertEqual(await space_counts(self.space_a, self.space_b), {self.space_a: (15, 15), self.space_b: (15, 15)})
        listed = {row["space"]: row["event_count"] for row in await agent_memory.list_spaces_async()}
        self.assertEqual((listed[self.space_a], listed[self.space_b]), (15, 15))

    async def test_recount_matches_the_table(self):
        await add(self.space_a, f"{self.marker} before recount")
        conn = await agent_memory.connect()
        try:
            # Simulate drift, then recount under the lock.
            await conn.execute("UPDATE agent_memory_space_search_state SET event_count = 999 WHERE space = $1", self.space_a)
            result = await agent_memory.ensure_space_counts_async(conn, recount=True)
            maintained = await agent_memory.space_counts_maintained(conn)
        finally:
            await conn.close()
        self.assertTrue(result["recounted"])
        self.assertTrue(maintained)
        self.assertEqual((await space_counts(self.space_a))[self.space_a], (1, 1))

    async def test_identity_audit_finds_newest_rows(self):
        harness = f"live-harness-{self.marker}"
        for n in range(3):
            await add(self.space_a, f"{self.marker} identity {n}", metadata={"identity": {"harness": harness}})
        rows = await agent_memory.audit_events_async(limit=2, harness=harness, all_spaces=True)
        self.assertEqual([row["content"] for row in rows], [f"{self.marker} identity 2", f"{self.marker} identity 1"])
        rows = await agent_memory.audit_events_async(limit=5, session_id="no-such-session", all_spaces=True)
        self.assertEqual(rows, [])


if __name__ == "__main__":
    unittest.main()
