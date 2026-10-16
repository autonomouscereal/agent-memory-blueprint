"""Recover missed Codex audit hooks from an exact native JSONL transcript."""
from __future__ import annotations

import hashlib
import json
import time
from collections import Counter
from pathlib import Path

from agent_memory_hook import build_parser, make_hook_event_uid, normalize_event, run_hook, sanitize_value_for_archive


def read_events(path: Path, max_bytes=64 * 1024 * 1024):
    if path.stat().st_size > max_bytes:
        raise ValueError('Transcript exceeds the bounded 64 MiB importer limit')
    records = []
    with path.open(encoding='utf-8') as stream:
        for ordinal, line in enumerate(stream):
            try:
                record = json.loads(line)
            except ValueError:
                continue  # Active final JSONL lines may not be committed yet.
            record['_line'] = ordinal
            records.append(record)
    header = next((r.get('payload') for r in records if r.get('type') == 'session_meta'), {})
    thread_id = header.get('id')
    if not thread_id:
        raise ValueError('No native session_meta thread identity found')
    base = {'harness': 'codex', 'session_id': header.get('session_id') or thread_id, 'thread_id': thread_id, 'transcript_path': str(path), 'cwd': header.get('cwd', ''), 'model_provider': header.get('model_provider', ''), 'harness_version': header.get('cli_version', ''), 'parent_thread_id': header.get('parent_thread_id', ''), 'agent_path': header.get('agent_path', ''), 'import_source': 'native_codex_transcript'}
    events = []
    calls = {}
    current_turn = ''
    for record in records:
        raw = record.get('payload') or {}
        kind = raw.get('type')
        payload = dict(base, timestamp=record.get('timestamp'), transcript_line=record['_line'], turn_id=current_turn)
        event = ''
        if record.get('type') == 'session_meta' and record.get('payload') is header:
            event = 'SessionStart'
            payload['content'] = 'Codex session started (recovered native transcript)'
        elif record.get('type') == 'turn_context':
            current_turn = raw.get('turn_id', '')
        elif record.get('type') == 'event_msg' and kind == 'item_completed':
            item = raw.get('item') or {}
            payload['turn_id'] = raw.get('turn_id') or current_turn
            payload['item_id'] = item.get('id')
            if item.get('type') in ('UserMessage', 'AgentMessage'):
                event = 'UserPromptSubmit' if item['type'] == 'UserMessage' else 'AssistantMessage'
                payload['content'] = '\n'.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict))
                payload['phase'] = item.get('phase')
        elif record.get('type') == 'response_item' and kind in ('function_call', 'custom_tool_call'):
            calls[raw.get('call_id')] = raw
        elif record.get('type') == 'response_item' and kind in ('function_call_output', 'custom_tool_call_output'):
            call = calls.get(raw.get('call_id'))
            if call:
                event = 'PostToolUse'
                payload.update({'call_id': raw.get('call_id'), 'tool_name': call.get('name'), 'tool_input': call.get('arguments', call.get('input')), 'tool_response': raw.get('output')})
        if event:
            encoded = json.dumps(sanitize_value_for_archive(payload), ensure_ascii=False)
            uid = make_hook_event_uid(agent='Codex', source='codex_transcript', event_type=normalize_event(event)[0], session_id=base['session_id'], payload_sha256=hashlib.sha256(encoded.encode('utf-8', errors='backslashreplace')).hexdigest())
            events.append((event, payload, uid))
    return thread_id, events


async def import_transcript(conn, *, path, limit=500, apply=False):
    path = Path(path).expanduser().resolve()
    thread_id, events = read_events(path)
    existing = set(await conn.fetchval('SELECT coalesce(array_agg(event_uid), ARRAY[]::text[]) FROM agent_memory_events WHERE event_uid=ANY($1::text[])', [e[2] for e in events]))
    pending = [e for e in events if e[2] not in existing][:max(1, min(limit, 10000))]
    counts = Counter(e[0] for e in pending)
    if apply:
        for event, payload, uid in pending:
            args = build_parser().parse_args(['--event', event, '--agent', 'Codex', '--source', 'codex_transcript'])
            await run_hook(args, json.dumps(payload, ensure_ascii=False), time.monotonic())
    committed = await conn.fetchval('SELECT count(*) FROM agent_memory_events WHERE event_uid=ANY($1::text[])', [e[2] for e in pending]) if apply else 0
    return {'ok': not apply or committed == len(pending), 'thread_id': thread_id, 'path': str(path), 'apply': apply, 'records_available': len(events), 'already_stored': len(existing), 'pending': len(pending), 'committed': committed, 'events': dict(counts)}
