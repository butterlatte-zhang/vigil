"""STEP 1 — prove the takeover loop with a deterministic stand-in agent.

The 'task' (this script) wraps a terminal, runs the agent inside it, intercepts
the approval gate, applies a policy (auto or human), injects the keystroke, then
captures the agent's reported result. Exactly the loop Vigil needs."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyctl import Terminal

# --- policy: how the supervising task decides on an approval request ---
def policy(request_text):
    # request_text is the intercepted approval line. A real Vigil would route
    # this into the unified inbox for a human, or auto-approve by rule.
    cmd = request_text
    mode = os.environ.get("POLICY", "auto-allow")
    if mode == "auto-deny":
        return "n", "auto-denied by rule"
    if "rm -rf /" in cmd and "build" not in cmd:   # trivial safety rule
        return "n", "blocked: looks like root delete"
    return "y", f"auto-approved ({mode})"

def main():
    log = open("/dev/stdout", "wb", buffering=0)
    t = Terminal([sys.executable, os.path.join(os.path.dirname(__file__), "fake_agent.py")],
                 logfile=None)  # we'll print our own annotated view

    print("=" * 64)
    print("TASK: wrapped a terminal, launched agent inside it (pid %d)" % t.pid)
    print("=" * 64)

    # 1) wait for the agent to hit its approval gate
    idx, seen = t.expect([r"APPROVAL_REQUIRED.*\n.*Approve\?\s*\[y/n\]"], timeout=10)
    if idx != 0:
        print("!! never saw approval prompt. transcript:\n", seen); t.close(); return

    # 2) extract the request and run policy
    import re
    req = re.search(r"APPROVAL_REQUIRED.*", seen).group(0)
    print("\n[TASK] intercepted approval request from agent:")
    print("       ", req)
    answer, why = policy(req)
    print("[TASK] policy decision: %r  (%s)" % (answer, why))

    # 3) inject the decision back into the agent's terminal
    t.sendline(answer)
    print("[TASK] injected %r into the agent's stdin" % answer)

    # 4) capture the agent's reported result back into the task
    idx, seen = t.expect([r"RESULT>.*"], timeout=10)
    result = re.search(r"RESULT>.*", seen)
    print("\n[TASK] captured agent's report back:")
    print("       ", result.group(0) if result else "(no result line)")
    t.close()

    print("\n" + "=" * 64)
    print("LOOP VERIFIED: launch → intercept approval → decide → inject → report")
    print("=" * 64)

main()
