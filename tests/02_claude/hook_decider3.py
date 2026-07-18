import sys, json, os
LOG="/tmp/vigil_hook3/intercepted.jsonl"; os.makedirs(os.path.dirname(LOG), exist_ok=True)
req=json.loads(sys.stdin.read() or "{}")
cmd=(req.get("tool_input") or {}).get("command","")
decision,reason=("deny","vigil-policy: token NUKE forbidden") if "NUKE" in cmd else ("allow","ok")
open(LOG,"a").write(json.dumps({"command":cmd,"decision":decision})+"\n")
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":decision,"permissionDecisionReason":reason}}))
