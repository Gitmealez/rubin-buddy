#!/usr/bin/env python3
"""Real subprocess checks: cross-session isolation, hook merging, and privacy."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('session_event', ROOT / 'session-event.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def event(self, identity, event, provider='claude', **extra):
        payload = dict(session_id=identity, cwd='/private/work/project', prompt='PRIVATE PROMPT',
                       transcript_path='/private/transcript.jsonl', **extra)
        result = subprocess.run(['sh', str(ROOT / 'state.sh'), 'event', event, provider],
            input=json.dumps(payload), text=True, capture_output=True,
            env=dict(os.environ, RUBIN_STATE_DIR=str(self.base)))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def files(self):
        return [json.loads(p.read_text()) for p in (self.base / 'sessions').glob('*.json')]

    def test_wait_survives_other_session_completion_and_provider_collision(self):
        self.event('same', 'Notification', notification_type='permission_prompt')
        self.event('other', 'Stop')
        self.event('same', 'UserPromptSubmit', provider='codex')
        states = self.files()
        self.assertEqual(len(states), 3)
        self.assertEqual(sorted(s['phase'] for s in states), ['ready', 'waiting', 'working'])
        self.event('same', 'PostToolUse')
        self.assertEqual(sorted(s['phase'] for s in self.files()), ['ready', 'working', 'working'])

    def test_ignores_unrelated_notifications_and_never_saves_content(self):
        self.event('private-id', 'Notification', notification_type='auth_success')
        self.assertFalse((self.base / 'sessions').exists())
        self.event('private-id', 'PreToolUse')
        data = self.files()[0]
        self.assertEqual(set(data), {'id','project','phase','detail','updated','event','provider'})
        self.assertNotIn('private', json.dumps(data))
        self.assertEqual(data['project'], 'project')

    def test_late_writer_cannot_overwrite_newer_state(self):
        payload = {'session_id': 'abc', 'cwd': '/project'}
        adapter.record(self.base, 'Stop', payload, timestamp=200)
        adapter.record(self.base, 'PreToolUse', payload, timestamp=100)
        self.assertEqual(self.files()[0]['phase'], 'ready')

    def test_concurrent_sessions_and_session_end(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: self.event(str(i), 'PreToolUse'), range(16)))
        self.assertEqual(len(self.files()), 16)
        self.event('0', 'SessionEnd')
        self.assertEqual(sum(s['phase'] == 'ended' for s in self.files()), 1)
        self.assertFalse(list((self.base / 'sessions').glob('*.tmp')))

    def test_bad_input_never_breaks_agent(self):
        for data in ['not json', '[]', '{}', '{"session_id":5}']:
            result = subprocess.run(['sh', str(ROOT / 'state.sh'), 'event', 'Stop'],
                input=data, text=True, capture_output=True,
                env=dict(os.environ, RUBIN_STATE_DIR=str(self.base)))
            self.assertEqual((result.returncode,result.stdout,result.stderr), (0,'',''))

    def test_hook_merge_is_idempotent_and_preserves_other_hooks(self):
        other = {'type':'command','command':'echo custom-rubin-buddy'}
        original = {'theme':'dark', 'hooks': {'Stop':[{'hooks':[other]}]}}
        for provider in ['claude', 'codex']:
            path = self.base / (provider + '.json')
            path.write_text(json.dumps(original))
            command = ['sh', str(ROOT / 'hooks.sh')] + (['--codex'] if provider == 'codex' else [])
            env = dict(os.environ, RUBIN_HOOKS_SETTINGS=str(path), RUBIN_HOOKS_MARKER_DIR=str(self.base))
            for _ in range(2):
                subprocess.run(command, env=env, capture_output=True, check=True)
            data = json.loads(path.read_text())
            ours = [h for g in data['hooks']['Stop'] for h in g['hooks'] if '# rubin-buddy' in h['command']]
            self.assertEqual(len(ours), 1)
            self.assertIn('event Stop ' + provider, ours[0]['command'])
            subprocess.run(command + ['--remove'], env=env, capture_output=True, check=True)
            self.assertEqual(json.loads(path.read_text()), original)
            self.assertEqual(json.loads(Path(str(path)+'.rubin-bak').read_text()), original)

if __name__ == '__main__': unittest.main()
