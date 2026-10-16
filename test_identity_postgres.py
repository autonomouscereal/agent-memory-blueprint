"""Live PostgreSQL hook/identity integration test, tagged as diagnostics."""
import asyncio
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

from agent_memory import audit_events_async, connect, search_events_async, trace_archives_async
from agent_memory_hook import build_parser, run_hook


async def main():
    run_id = 'identity-test-' + str(uuid.uuid4())
    error_log = Path(__file__).parent / 'logs' / 'agent_memory_hook_errors.jsonl'
    error_size = error_log.stat().st_size if error_log.exists() else 0
    args = build_parser().parse_args(['--event', 'PostToolUse', '--agent', 'IdentityTest', '--source', 'hermes_hook', '--space', 'agent-memory/identity-test'])
    payloads = [json.dumps({'session_id': run_id, 'call_id': str(i), 'content': f'Identity metadata integration sentinel {run_id} event {i}', 'model_id': 'identity-test-model', 'model_provider': 'test-provider', 'thread_id': run_id, 'gpu_uuid': 'GPU-test-fixture', 'tool_response': {'password': 'test-secret-must-be-redacted'}}) for i in range(40)]
    # Production hooks are separate processes. A single event loop would serialize
    # synchronous password-command reads and can starve async connection timeouts.
    async def child_hook(raw):
        proc = await asyncio.create_subprocess_exec(sys.executable, str(Path(__file__).with_name('agent_memory_hook.py')), '--event', 'PostToolUse', '--agent', 'IdentityTest', '--source', 'hermes_hook', '--space', 'agent-memory/identity-test', stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await proc.communicate(raw.encode())
        assert proc.returncode == 0 and not stdout and not stderr, (proc.returncode, stdout, stderr)
    await asyncio.gather(*(child_hook(raw) for raw in payloads))
    await run_hook(args, payloads[0], time.monotonic())
    conn = await connect()
    try:
        events = await conn.fetch('SELECT id, metadata FROM agent_memory_events WHERE session_id=$1 ORDER BY id', run_id)
        archives = await conn.fetchval('SELECT count(*) FROM agent_memory_payload_archives WHERE session_id=$1', run_id)
        mentions = await conn.fetchval('SELECT count(*) FROM agent_memory_entity_mentions WHERE event_id = ANY($1::bigint[])', [r['id'] for r in events])
    finally:
        await conn.close()
    assert len(events) == 40, len(events)
    assert archives == 40, archives
    assert mentions == 0, mentions
    assert all(r['metadata']['identity']['model_id'] == 'identity-test-model' and r['metadata']['identity']['gpu_uuid'] == 'GPU-test-fixture' for r in events)
    traces = await trace_archives_async(event_id=events[0]['id'], limit=1)
    assert 'test-secret-must-be-redacted' not in traces[0]['payload']
    assert traces[0]['metadata']['identity']['model_id'] == 'identity-test-model'
    audit = await audit_events_async(limit=50, session_id=run_id, model_id='identity-test-model', harness='hermes', thread_id=run_id, provider='test-provider')
    assert len(audit) == 40
    found = await search_events_async(run_id, space='agent-memory/identity-test', limit=5)
    assert any(r['id'] in [e['id'] for e in events] for r in found)
    child = subprocess.run([sys.executable, str(Path(__file__).with_name('agent_memory_hook.py')), '--event', 'SessionStart', '--agent', 'IdentityTest', '--source', 'hermes_hook', '--space', 'agent-memory/identity-test'], input=json.dumps({'session_id': run_id+'-stdin', 'model_id': 'identity-test-model', 'prompt': 'stdin identity sentinel'}), text=True, capture_output=True, timeout=30)
    assert child.returncode == 0 and child.stdout == '' and child.stderr == '', (child.returncode, child.stdout, child.stderr)
    assert (error_log.stat().st_size if error_log.exists() else 0) == error_size
    print(json.dumps({'ok': True, 'session_id': run_id, 'concurrent_events': len(events), 'archives': archives, 'entity_mentions': mentions, 'duplicate_deduplicated': True, 'stdin_silent': True, 'redaction_verified': True, 'audit_filters_verified': True, 'search_verified': True, 'event_id_first': events[0]['id'], 'event_id_last': events[-1]['id']}, indent=2))


if __name__ == '__main__':
    asyncio.run(main())
