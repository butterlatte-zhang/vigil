"""STEP 2 — the real test: drive an actual `claude` TUI through the wrapped
terminal, intercept its REAL permission dialog, approve it, capture the report.

This is the load-bearing claim for Vigil's 'terminal takeover' thesis: can an outer task
own a real agent CLI's pty, see its permission gate in the ANSI stream, and
inject the approval keystroke. We use the real binary, default permission mode
(so it actually prompts), in a throwaway cwd.
"""
import sys, os, re, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyctl import Terminal

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
WORKDIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/vigil_claude_test"
os.makedirs(WORKDIR, exist_ok=True)

RAWLOG = open(os.path.join(WORKDIR, "raw_transcript.log"), "wb", buffering=0)

# Task we give claude — must trigger a Bash permission prompt under default mode.
TASK = ("Run exactly this shell command and nothing else: "
        "echo VIGIL_PROOF_$(date +%s) > result.txt ; "
        "then read result.txt back and tell me its contents.")

env = dict(os.environ)
env["TERM"] = "xterm-256color"

print("=" * 70)
print("TASK: wrapping a terminal around REAL claude")
print("  bin :", CLAUDE)
print("  cwd :", WORKDIR)
print("  ask :", TASK[:60], "...")
print("=" * 70)

# Start claude interactive with the task as the initial prompt arg.
# NB: no --dangerously-skip-permissions, so the permission gate fires.
t = Terminal([CLAUDE, TASK], env=env, cwd=WORKDIR, logfile=RAWLOG, winsize=(45, 120))


def show_tail(text, n=18):
    lines = [l for l in text.splitlines() if l.strip()]
    print("    | " + "\n    | ".join(lines[-n:]))


step = 0
approved = False
deadline = time.time() + 150
while time.time() < deadline:
    idx, text = t.expect([
        r"trust the files in this folder",        # 0: first-run folder trust gate
        r"Do you want to proceed|Yes, and don't ask|❯\s*1\.\s*Yes|1\.\s*Yes",  # 1: permission dialog
        r"VIGIL_PROOF_\d+",                        # 2: the proof landed -> result visible
    ], timeout=20, quiet_after=0.6)

    if idx == 0 and not approved:
        print("\n[TASK] intercepted FOLDER-TRUST gate -> auto-approving (send '1')")
        t.send("1")
        time.sleep(1.0)
        continue

    if idx == 1:
        print("\n[TASK] intercepted REAL permission dialog from claude:")
        show_tail(text, 12)
        print("[TASK] policy=auto-allow -> injecting approval keystroke '1'")
        t.send("1")           # select option 1 (Yes)
        approved = True
        time.sleep(1.5)
        continue

    if idx == 2:
        print("\n[TASK] captured claude's RESULT inside the wrapped terminal:")
        m = re.search(r"VIGIL_PROOF_\d+", text)
        show_tail(text, 14)
        print("\n[TASK] >>> proof token reported back to task:", m.group(0))
        break

    # nothing matched this window; loop and keep reading
    step += 1
    if t._dead():
        print("\n[TASK] claude exited.")
        break

print("\n[TASK] sending /exit to close claude cleanly")
try:
    t.sendline("/exit"); time.sleep(0.5); t.send("\x03")
except Exception:
    pass
t.close()

# Ground truth: did the file actually get written on disk?
print("\n" + "=" * 70)
rf = os.path.join(WORKDIR, "result.txt")
if os.path.exists(rf):
    print("GROUND TRUTH on disk -> result.txt =", open(rf).read().strip())
    print("VERIFIED: outer task drove real claude through its permission gate.")
else:
    print("result.txt NOT created — see raw_transcript.log for what happened.")
print("=" * 70)
