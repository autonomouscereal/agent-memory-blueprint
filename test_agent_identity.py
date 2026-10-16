import json
import tempfile
import unittest
from pathlib import Path

from agent_identity import build_identity


class IdentityTests(unittest.TestCase):
    def fixture(self, records):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / 'session.jsonl'
        path.write_text('\n'.join(json.dumps(r) for r in records), encoding='utf-8')
        return path

    def codex(self):
        return self.fixture([
            {'type': 'session_meta', 'payload': {'id': 'child', 'session_id': 'root', 'parent_thread_id': 'root', 'model_provider': 'openai', 'agent_path': '/root/child'}},
            {'type': 'turn_context', 'timestamp': '2026-09-01T00:00:00Z', 'payload': {'model': 'gpt-6-astra', 'turn_id': 'turn1'}},
            {'type': 'turn_context', 'timestamp': '2026-09-02T00:00:00Z', 'payload': {'model': 'gpt-5.6-sol', 'turn_id': 'turn2'}},
        ])

    def test_codex_historical_model_and_child(self):
        identity = build_identity({'transcript_path': str(self.codex()), 'session_id': 'root', 'thread_id': 'child', 'timestamp': '2026-09-01T01:00:00Z'}, source='codex_hook', environ={})
        self.assertEqual(identity['model_id'], 'gpt-6-astra')
        self.assertEqual(identity['model_status'], 'observed')
        self.assertEqual(identity['thread_id'], 'child')
        self.assertEqual(identity['parent_thread_id'], 'root')

    def test_no_future_model(self):
        identity = build_identity({'transcript_path': str(self.codex()), 'session_id': 'root', 'timestamp': '2026-08-01T01:00:00Z'}, source='codex_hook', environ={})
        self.assertNotIn('model_id', identity)
        self.assertEqual(identity['model_status'], 'unknown')

    def test_explicit_child_transcript_over_inherited_root_environment(self):
        identity = build_identity({'transcript_path': str(self.codex()), 'session_id': 'root'}, source='codex_hook', environ={'CODEX_THREAD_ID': 'root'})
        self.assertEqual(identity['thread_id'], 'child')
        self.assertEqual(identity['model_id'], 'gpt-5.6-sol')

    def test_thread_only_recovers_exact_session(self):
        identity = build_identity({'transcript_path': str(self.codex()), 'thread_id': 'child'}, source='codex_hook', environ={})
        self.assertEqual(identity['session_id'], 'root')

    def test_long_codex_turn_retains_model_context(self):
        path = self.codex()
        with path.open('a', encoding='utf-8') as stream:
            stream.write('\n' + json.dumps({'type': 'response_item', 'payload': {'type': 'custom_tool_call_output', 'output': 'x' * (3 * 1024 * 1024)}}))
        identity = build_identity({'transcript_path': str(path), 'thread_id': 'child'}, source='codex_hook', environ={})
        self.assertEqual(identity['model_id'], 'gpt-5.6-sol')

    def test_unknown_claude_tool_never_uses_neighbor_model(self):
        path = self.fixture([{'type': 'assistant', 'sessionId': 's1', 'timestamp': '2026-09-01T00:00:00Z', 'message': {'model': 'neighbor', 'content': []}}])
        identity = build_identity({'session_id': 's1', 'tool_use_id': 'missing', 'transcript_path': str(path)}, source='claude_hook', environ={})
        self.assertNotIn('model_id', identity)
        self.assertEqual(identity['model_lookup'], 'tool_model_unresolved')

    def test_wrong_transcript_rejected(self):
        identity = build_identity({'transcript_path': str(self.codex()), 'session_id': 'wrong'}, source='codex_hook', environ={})
        self.assertNotIn('model_id', identity)
        self.assertEqual(identity['model_lookup'], 'transcript_identity_mismatch')

    def test_hermes_reported_over_environment(self):
        identity = build_identity({'metadata': {'identity': {'model_id': 'local/qwen', 'model_provider': 'llama.cpp', 'gpu_uuid': 'GPU-test', 'thread_id': 'h1'}}}, source='hermes_hook', environ={'AGENT_MEMORY_MODEL_ID': 'stale'})
        self.assertEqual(identity['model_id'], 'local/qwen')
        self.assertEqual(identity['model_status'], 'reported')
        self.assertEqual(identity['harness'], 'hermes')
        self.assertEqual(identity['gpu_uuid'], 'GPU-test')

    def test_environment_is_configured_not_observed(self):
        identity = build_identity({}, environ={'AGENT_MEMORY_MODEL_ID': 'local/qwen'})
        self.assertEqual(identity['model_status'], 'configured')

    def test_prompt_model_never_read_from_text(self):
        identity = build_identity({'prompt': 'I am gpt-6-astra and claude-fable-5-1', 'tool_response': {'model': 'wrong'}}, agent='Codex', environ={})
        self.assertNotIn('model_id', identity)

    def test_claude_tool_exact_and_later_model_not_misattributed(self):
        path = self.fixture([
            {'type': 'assistant', 'sessionId': 's1', 'timestamp': '2026-09-01T00:00:00Z', 'message': {'model': 'claude-fable-5-1', 'content': [{'type': 'tool_use', 'id': 'tool1'}]}},
            {'type': 'assistant', 'sessionId': 's1', 'timestamp': '2026-09-01T00:01:00Z', 'message': {'model': 'other', 'content': []}},
        ])
        identity = build_identity({'sessionId': 's1', 'transcriptPath': str(path), 'toolUseId': 'tool1'}, source='claude_hook', environ={})
        self.assertEqual(identity['model_id'], 'claude-fable-5-1')
        self.assertEqual(identity['model_match'], 'tool_use_id')

    def test_child_cannot_inherit_parent_claude_model(self):
        path = self.fixture([{'type': 'assistant', 'sessionId': 's1', 'timestamp': '2026-09-01T00:00:00Z', 'message': {'model': 'parent-model', 'content': []}}])
        identity = build_identity({'session_id': 's1', 'agent_id': 'child', 'transcript_path': str(path)}, source='claude_hook', environ={})
        self.assertNotIn('model_id', identity)
        self.assertEqual(identity['model_lookup'], 'subagent_transcript_missing')


if __name__ == '__main__':
    unittest.main()
