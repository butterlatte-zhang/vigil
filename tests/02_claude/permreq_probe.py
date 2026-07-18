#!/usr/bin/env python3
"""Observe-only hook event logger for the M0 PermissionRequest pairing probe.

argv[1] = jsonl log path. Wired to multiple hook events (PermissionRequest /
PostToolUse / Notification) in test_permreq_pairing.py; the payload's own
hook_event_name tells us which one fired. Appends one line per fire with a
wall-clock timestamp (ordering evidence), the full key set, and the fields
relevant to pairing (tool_use_id / tool_name). Prints NOTHING to stdout so the
hook is a pure observer (empty output + exit 0 = native flow untouched, F7)."""
import sys, json, os, time

log = sys.argv[1]
raw = sys.stdin.read()
try:
    req = json.loads(raw)
except Exception:
    req = {"_unparsed": raw[:400]}

os.makedirs(os.path.dirname(log), exist_ok=True)
with open(log, "a") as f:
    f.write(json.dumps({
        "ts": time.time(),
        "event": req.get("hook_event_name", "?"),
        "keys": sorted(req.keys()),
        "tool_name": req.get("tool_name"),
        "tool_use_id": req.get("tool_use_id"),
        "message": req.get("message"),          # Notification payloads
        "raw": {k: v for k, v in req.items() if k != "tool_response"},
        "tool_response_present": "tool_response" in req,
    }) + "\n")
sys.exit(0)
