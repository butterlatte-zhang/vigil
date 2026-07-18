#!/usr/bin/env python3
"""PreToolUse hook = Vigil's STRUCTURED perm channel (no scraping).

Claude Code hands us the tool request as JSON on stdin: full tool_name +
tool_input. We log it (proof we got structure, not pixels), apply a policy,
and return a permissionDecision. This is the robust per-harness path from §12.3.
"""
import sys, json, os

LOG = "/tmp/vigil_hook/intercepted.jsonl"
os.makedirs(os.path.dirname(LOG), exist_ok=True)

raw = sys.stdin.read()
try:
    req = json.loads(raw)
except Exception:
    req = {"_unparsed": raw}

tool = req.get("tool_name", "?")
tinput = req.get("tool_input", {})
cmd = tinput.get("command", "") if isinstance(tinput, dict) else ""

# --- policy: structured, deterministic, no regex-on-screen needed ---
if "rm " in cmd or "rm-" in cmd or "sudo" in cmd:
    decision, reason = "deny", "vigil-policy: destructive command blocked"
else:
    decision, reason = "allow", "vigil-policy: auto-approved"

# proof of structured interception
with open(LOG, "a") as f:
    f.write(json.dumps({"tool": tool, "command": cmd,
                        "decision": decision, "saw_keys": sorted(req.keys())}) + "\n")

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": decision,
    "permissionDecisionReason": reason,
}}))
sys.exit(0)
