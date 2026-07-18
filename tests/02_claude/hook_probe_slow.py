#!/usr/bin/env python3
"""Slow PreToolUse probe — simulates a human taking MINUTES to decide.

argv[1] = log path   argv[2] = sleep seconds (the "human thinking" delay)

The structured-perm thesis (§5.1 / §12.5-F) only holds in production if a
hook can block for the minutes a real human needs without claude timing it out
and falling back / failing. This probe sleeps, then approves — the test checks
the decision was still honored and the native dialog stayed suppressed."""
import sys, json, os, time

log = sys.argv[1]
sleep_s = float(sys.argv[2]) if len(sys.argv) > 2 else 70.0
os.makedirs(os.path.dirname(log), exist_ok=True)

raw = sys.stdin.read()
try:
    req = json.loads(raw)
except Exception:
    req = {}

with open(log, "a") as f:
    f.write(json.dumps({"phase": "received", "t": time.time(),
                        "cmd": (req.get("tool_input") or {}).get("command", "")}) + "\n")

time.sleep(sleep_s)   # <-- the human deliberating

with open(log, "a") as f:
    f.write(json.dumps({"phase": "deciding", "t": time.time(), "after_sleep": sleep_s}) + "\n")

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "vigil-slow-probe: approved after %ss" % sleep_s,
}}))
sys.exit(0)
