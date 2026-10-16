"""Bounded, non-destructive identity enrichment of existing PostgreSQL events."""
from collections import Counter
from datetime import UTC, datetime

from agent_identity import build_identity


async def enrich_identities(conn, *, limit=1000, before_id=0, since=None, apply=False):
    rows = await conn.fetch("""
        SELECT id, created_at, session_id, agent, source, metadata - 'raw_payload' AS metadata
        FROM agent_memory_events
        WHERE ($1::bigint = 0 OR id < $1) AND ($2::timestamptz IS NULL OR created_at >= $2)
          AND metadata ? 'hook_event' AND coalesce(metadata->'identity'->>'model_id', '') = ''
        ORDER BY id DESC LIMIT $3
    """, before_id, since, max(1, min(limit, 10000)))
    counts = Counter()
    samples = []
    updated = 0
    for row in rows:
        payload = dict(row['metadata'] or {})
        payload['session_id'] = row['session_id']
        payload['timestamp'] = row['created_at'].isoformat()
        identity = build_identity(payload, agent=row['agent'], source=row['source'], session_id=row['session_id'] or '', environ={}, full_transcript=True)
        identity['enriched_at'] = datetime.now(UTC).isoformat()
        identity['enrichment_source'] = 'bounded_historical_transcript'
        counts[identity.get('model_id', 'unknown')] += 1
        if len(samples) < 8:
            samples.append({'id': row['id'], 'identity': identity})
        if apply:
            async with conn.transaction():
                status = await conn.execute("""
                    UPDATE agent_memory_events SET metadata = metadata || jsonb_build_object('identity', $2::jsonb)
                    WHERE id = $1 AND coalesce(metadata->'identity'->>'model_id', '') = ''
                """, row['id'], identity)
                if status == 'UPDATE 1':
                    await conn.execute("""
                        UPDATE agent_memory_payload_archives
                        SET metadata = metadata || jsonb_build_object('identity', $2::jsonb)
                        WHERE event_id = $1 AND coalesce(metadata->'identity'->>'model_id', '') = ''
                    """, row['id'], identity)
                    updated += 1
    return {'ok': True, 'apply': apply, 'scanned': len(rows), 'updated': updated, 'models': dict(counts), 'next_before_id': rows[-1]['id'] if rows else None, 'samples': samples}
