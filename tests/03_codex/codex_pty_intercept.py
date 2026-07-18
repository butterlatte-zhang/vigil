"""Codex via PTY+vt100 — the universal-fallback test, apples-to-apples with the
claude step2/D proof. Force an approval (untrusted policy + read-only sandbox in
a fresh dir), intercept the modal on the rendered screen, inject approval,
check ground truth. Observational: dumps the rendered screen so we learn codex's
approval UI + which key approves."""
import sys, os, re, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

CODEX = os.environ.get("CODEX_BIN", "codex")
WORK = "/tmp/vigil_codex_test"
os.makedirs(WORK, exist_ok=True)
for f in os.listdir(WORK):
    try: os.remove(os.path.join(WORK, f))
    except OSError: pass

TASK = "Run this shell command now: echo CDXPROOF > cxresult.txt"
RESULT_FILE = os.path.join(WORK, "cxresult.txt")

env = dict(os.environ); env["TERM"] = "xterm-256color"
# force approval prompts; clear the user's global MCP servers to speed startup
argv = [CODEX, "-a", "untrusted", "-s", "read-only", "-c", "mcp_servers={}", TASK]
print("argv:", " ".join(argv)); print("cwd :", WORK)
c = ScreenCell(argv, env=env, cwd=WORK, rows=45, cols=120)

def dump(scr, tag):
    print("\n----- screen [%s] -----" % tag)
    for ln in scr.splitlines():
        if ln.strip():
            print("  " + ln)
    print("-----------------------")

def disk_done():
    return os.path.exists(RESULT_FILE)

injected = []
submitted = False
deadline = time.time() + 120
last = ""
while time.time() < deadline:
    scr = c.pump(1.0)
    if scr != last:
        dump(scr, "t=%.0f" % (120 - (deadline - time.time())))
        last = scr
    low = scr.lower()

    if ("do you trust" in low or "trust the contents" in low) and "trust" not in injected:
        print(">> TRUST prompt -> Enter (select '1. Yes')"); c.send("\r"); injected.append("trust"); time.sleep(1.5); continue

    # codex pre-fills the prompt; submit it once startup settles
    if (not submitted) and "trust" in injected and "create a file" not in low \
       and ("context" in low or "to run" in low or "esc to interrupt" in low or "/skills" in low):
        print(">> composer ready -> submit prompt (Enter)"); c.send("\r"); submitted = True; time.sleep(2); continue

    # approval modal — dump it, then select highlighted (Enter); also try 'y'
    if any(k in low for k in ["allow codex", "wants to run", "approve", "yes, proceed", "run this command", "would you like"]) \
       and not disk_done():
        print(">> APPROVAL modal detected:")
        for ln in scr.splitlines():
            if ln.strip(): print("     | " + ln)
        c.send("\r"); time.sleep(0.8)
        if not disk_done(): c.send("y"); time.sleep(0.6)
        if not disk_done(): c.send("1"); time.sleep(0.6)
        injected.append("approve"); time.sleep(1.5); continue

    if disk_done():
        print(">> FILE WRITTEN on disk"); break
    if c._dead():
        print(">> codex exited"); break

time.sleep(1)
try: c.send("\x03"); time.sleep(0.3); c.send("\x03")
except Exception: pass
c.close()

rf = os.path.join(WORK, "cxresult.txt")
print("\n=== GROUND TRUTH:", repr(open(rf).read().strip()) if os.path.exists(rf) else "cxresult.txt NOT created")
print("=== injected sequence:", injected)
