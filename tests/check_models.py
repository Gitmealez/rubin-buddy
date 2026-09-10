#!/usr/bin/env python3
"""Compile and exercise the app's actual session arbitration implementation."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Buddy.swift').read_text()
model = source[source.index('struct AgentSession:'):source.index('final class CompanionPanel:')]
checks = r'''
let now = 10000.0
func session(_ id: String, _ phase: String, _ updated: Double, _ provider: String = "claude") -> AgentSession {
    AgentSession(id: id, project: "project", phase: phase, detail: phase,
                 updated: updated, event: "Stop", provider: provider)
}
let waiting = session("wait", "waiting", now - 4000)
let ready = session("done", "ready", now - 10, "codex")
let working = session("work", "working", now)
let stale = session("stale", "working", now - 2000)
let ended = session("ended", "ended", now)
let order = AgentSession.ordered([working, ready, waiting, stale, ended], at: now, acknowledged: [:])
precondition(order.map(\.id) == ["wait", "done", "work", "stale"], "A completion hid a request for attention")
precondition(stale.effectivePhase(at: now) == "unknown", "Stale work must not claim completion")
precondition(waiting.effectivePhase(at: now) == "waiting", "A wait must survive inactivity")
precondition(AgentSession.ordered([ready], at: now, acknowledged: ["done":now]).isEmpty)
let newReady = session("done", "ready", now + 1)
precondition(AgentSession.ordered([newReady], at: now+1, acknowledged: ["done":now]).count == 1,
             "Acknowledging one turn must not hide the next completion")
precondition(ready.agentName == "Codex")
let json = """
{"id":"old","project":"project","phase":"ready","detail":"Ready","updated":9000,"event":"Stop"}
"""
precondition(try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8)).agentName == "Claude")
print("Session priority, stale state, provider labels, and review persistence passed.")
'''
# The precondition autoclosure cannot throw.
checks = checks.replace('precondition(try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8)).agentName == "Claude")',
                        'let legacy = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))\nprecondition(legacy.agentName == "Claude")')
with tempfile.TemporaryDirectory() as temp:
    src = Path(temp) / 'main.swift'
    src.write_text('import Foundation\n' + model + checks)
    binary = Path(temp) / 'check'
    subprocess.run(['swiftc', str(src), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
