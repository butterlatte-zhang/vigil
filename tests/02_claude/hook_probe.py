#!/usr/bin/env python3
"""Parametrized PreToolUse probe for the INTERACTIVE-TUI hook test.

argv[1] = log path (jsonl)   argv[2] = forced decision (allow|deny)

Logs the FULL set of keys claude handed us on stdin (proof we got structured
input, not pixels — and that the interactive TUI delivers the same contract as
headless), then returns the forced permissionDecision. Used by
test_hook_interactive.py to check whether a hook decision suppresses claude's
native approval dialog when claude runs as an interactive TUI inside a PTY."""
import sys, json, os

log = sys.argv[1]
decision = sys.argv[2] if len(sys.argv) > 2 else "allow"
os.makedirs(os.path.dirname(log), exist_ok=True)

raw = sys.stdin.read()
try:
    req = json.loads(raw)
except Exception:
    req = {"_unparsed": raw[:200]}

tinput = req.get("tool_input") or {}
cmd = tinput.get("command", "") if isinstance(tinput, dict) else ""

with open(log, "a") as f:
    f.write(json.dumps({
        "tool": req.get("tool_name", "?"),
        "command": cmd,
        "decision": decision,
        "permission_mode": req.get("permission_mode"),
        "saw_keys": sorted(req.keys()),
    }) + "\n")

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": decision,
    "permissionDecisionReason": "vigil-interactive-probe: forced %s" % decision,
}}))
sys.exit(0)
