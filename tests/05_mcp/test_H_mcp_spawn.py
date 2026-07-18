"""TEST H — does claude REALLY call a Vigil MCP tool, and can it BLOCK? (§10 step1 ②)

The least-backed load-bearing piece (DOCTRINE §9/§10 · §12.6 ⚠️): Vigil's
struct/ask/send/report ride on real MCP tool calls, but that transport was never
end-to-end tested — C2's spawn was a scraped text marker, not a real MCP call.

This headless probe answers, with disk ground truth:
  ②a transport  — does Vigil's MCP server receive a real structured call?
  ②b behavior   — given a skill, does claude actually CALL spawn (not prose it)?
  ②c blocking   — can the tool response be held VIGIL_MCP_BLOCK seconds, claude waits?
  ②d (partial)  — does the --mcp-config stdio wiring work at all?

PASS = server log shows a `received` record with the right args (claude really
invoked the tool) AND, if blocking, a `returned` after the delay AND claude's
answer carries the returned id `node-7` (it waited and used the result).
"""
import sys, os, re, json, time, tempfile, shutil, subprocess

HERE = os.path.dirname(__file__)
VENV_PY = os.path.join(HERE, "..", ".venv", "bin", "python")
PROBE = os.path.join(HERE, "vigil_mcp_probe.py")
CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
BLOCK = os.environ.get("VIGIL_MCP_BLOCK", "0")

work = tempfile.mkdtemp(prefix="vigil_mcp_")
log = os.path.join(work, "mcp_calls.jsonl")

cfg = {"mcpServers": {"vigil": {
    "command": os.path.abspath(VENV_PY),
    "args": [os.path.abspath(PROBE)],
    "env": {"VIGIL_MCP_LOG": log, "VIGIL_MCP_BLOCK": str(BLOCK)},
}}}
cfg_path = os.path.join(work, "mcp.json")
open(cfg_path, "w").write(json.dumps(cfg))

TASK = (
    "You are a MANAGER. You are FORBIDDEN to compute anything yourself. To get the "
    "subtask done you MUST call the `spawn` tool exactly once with role=\"leaf\" and "
    "task=\"compute sum 1..10\". After it returns, report the child node id it gave you."
)

print("=" * 72)
print("TEST H: does claude really CALL the MCP spawn tool? (block=%ss)" % BLOCK)
print("  bin :", CLAUDE)
print("=" * 72)

t0 = time.time()
proc = subprocess.run(
    [CLAUDE, "-p", TASK,
     "--mcp-config", cfg_path, "--strict-mcp-config",
     "--allowedTools", "mcp__vigil__spawn",
     "--permission-mode", "default"],
    cwd=work, capture_output=True, text=True, timeout=300)
elapsed = time.time() - t0
out = (proc.stdout or "") + "\n" + (proc.stderr or "")

records = []
if os.path.exists(log):
    records = [json.loads(l) for l in open(log) if l.strip()]
received = next((r for r in records if r.get("phase") == "received"), None)
returned = next((r for r in records if r.get("phase") == "returned"), None)

print("\n[claude output tail]")
print("    | " + "\n    | ".join([l for l in out.splitlines() if l.strip()][-12:]))
print("\n[mcp server log]", records)

called = received is not None
args_ok = bool(received) and received.get("role") == "leaf" and "sum" in (received.get("task") or "")
returned_id = bool(returned)
reported_id = "node-7" in out
blocked_ok = (float(BLOCK) <= 1) or (returned is not None and received is not None
                                     and (returned["t"] - received["t"]) >= float(BLOCK) - 1)

print("\n" + "-" * 72)
print("  ②a transport: server got a real structured call :", called)
print("  ②b behavior : claude CALLED spawn (args correct) :", args_ok)
print("  ②c blocking : held %ss, claude waited            : %s" % (BLOCK, blocked_ok and returned_id))
print("  claude reported returned id node-7               :", reported_id)
print("  elapsed: %.1fs" % elapsed)

shutil.rmtree(work, ignore_errors=True)
ok = called and args_ok and reported_id and blocked_ok
print("\n" + "#" * 64)
print("VERDICT H:", "✅ PASS" if ok else "❌ FAIL",
      "— claude really invokes the Vigil MCP tool (structured), id returned")
if not ok:
    print("  -> if claude didn't call it: skill/prompt iteration needed (②b open).")
    print("  -> if it didn't block/wait: MCP sync design at risk (§6.1 async fork).")
print("#" * 64)
sys.exit(0 if ok else 1)
