#!/usr/bin/env python3
"""Local Claude hook adapter. Retains only a hashed ID, folder name, state, and
when commands last failed and recovered.

Never read transcripts, save prompts/tool input, send network requests, or emit
hook output. Failures are deliberately non-fatal to Claude Code.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time


def record(directory, event, payload, timestamp=None, provider='claude'):
    timestamp = time.time() if timestamp is None else timestamp
    if not isinstance(payload, dict):
        return
    identity = payload.get('session_id')
    if not isinstance(identity, str) or not identity:
        return
    phases = {'SessionStart': 'idle', 'UserPromptSubmit': 'working',
              'PreToolUse': 'working', 'PostToolUse': 'working',
              'PostToolUseFailure': 'working', 'Notification': 'waiting',
              'Stop': 'ready', 'SessionEnd': 'ended',
              'PermissionRequest': 'waiting', 'Interrupt': 'idle'}
    if event not in phases:
        return
    notification = payload.get('notification_type')
    if event == 'Notification' and notification not in ('permission_prompt', 'idle_prompt'):
        return
    if provider not in ('claude', 'codex'):
        return
    key = hashlib.sha256((provider + ':' + identity).encode()).hexdigest()[:24]
    target = Path(directory) / 'sessions'
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = target / (key + '.json')
    # Per-session lock: one project's completion must never erase another's wait.
    with (target / (key + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            previous = json.loads(path.read_text())
        except (OSError, ValueError):
            previous = {}
        if previous.get('updated', 0) > timestamp:
            return
        folder = payload.get('cwd')
        folder = Path(folder).name if isinstance(folder, str) else 'Claude Code'
        folder = ''.join(c for c in folder if c.isprintable())[:60] or 'Claude Code'
        phase = phases[event]
        detail = 'Permission requested' if notification == 'permission_prompt' or event == 'PermissionRequest' else 'Waiting for your input'
        if phase != 'waiting':
            detail = {'working': 'Working', 'ready': 'Ready for your review',
                      'idle': 'Connected', 'ended': 'Session ended'}[phase]
        data = {'id': key, 'project': folder, 'phase': phase, 'detail': detail,
                'updated': timestamp, 'event': event, 'provider': provider}
        # Failure bookkeeping, for Rick's reactions: when a command last
        # failed, and when one last worked after failing. Times only.
        fails = previous.get('fails', 0) if isinstance(previous.get('fails'), int) else 0
        for field in ('failedAt', 'recoveredAt'):
            if isinstance(previous.get(field), (int, float)):
                data[field] = previous[field]
        if event == 'PostToolUseFailure':
            fails += 1
            data['failedAt'] = timestamp
        elif event == 'PostToolUse' and fails:
            fails = 0
            data['recoveredAt'] = timestamp
        elif event in ('UserPromptSubmit', 'Stop', 'SessionStart', 'SessionEnd'):
            fails = 0
        data['fails'] = fails
        fd, tmp = tempfile.mkstemp(prefix=key, suffix='.tmp', dir=target)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


if __name__ == '__main__':
    try:
        started = time.time()
        # A malformed or excessively large hook must have no effect on Rick.
        payload = json.loads(sys.stdin.read(4 * 1024 * 1024))
        record(sys.argv[1], sys.argv[2], payload, started,
               sys.argv[3] if len(sys.argv) > 3 else 'claude')
    except Exception:
        pass
