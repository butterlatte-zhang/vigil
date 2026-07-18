"""TEST G — can the structured perm hook block for MINUTES (real human latency)?

The load-bearing risk behind §5.1's "perm = structured hook" thesis: F
proved suppression with a hook that returns instantly, but a real human takes
minutes to approve. claude hooks have a default timeout (~60s). If the hook is
killed at timeout, the structured perm channel collapses under real usage. This
test makes the hook sleep PAST the default and checks the decision still lands.

We test the production config: an explicit large per-hook `timeout`. If the file
gets written (allow honored after the long block) with no native dialog, the
channel holds for arbitrary human latency provided Vigil sets a long timeout.
"""
import sys, os, json, time, tempfile, shutil
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
PY = sys.executable
PROBE = os.path.join(os.path.dirname(__file__), "hook_probe_slow.py")
ENV = dict(os.environ); ENV["TERM"] = "xterm-256color"

SLEEP = float(os.environ.get("HOOK_SLEEP", "70"))     # > default ~60s timeout
HOOK_TIMEOUT = int(os.environ.get("HOOK_TIMEOUT", "3600"))   # the production knob (seconds)
DIALOG = "do you want to proceed"

work = tempfile.mkdtemp(prefix="vigil_hookblock_")
log = os.path.join(work, "intercepted.jsonl")
outfile = os.path.join(work, "out.txt")
settings = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
    {"type": "command", "timeout": HOOK_TIMEOUT,
     "command": "%s %s %s %s" % (PY, PROBE, log, SLEEP)}]}]}}

print("=" * 72)
print("TEST G: does the perm hook survive a %.0fs human delay? (timeout=%ds)"
      % (SLEEP, HOOK_TIMEOUT))
print("=" * 72)

task = ("Run exactly this shell command and nothing else: "
        "echo VIGIL_BLOCK_OK > out.txt ; then read out.txt and report its contents.")
cell = ScreenCell([CLAUDE, task, "--settings", json.dumps(settings),
                   "--permission-mode", "default"], env=ENV, cwd=work, rows=50, cols=200)

dialog_seen = False
hook_received = False
hook_decided = False
t0 = time.time()
deadline = time.time() + SLEEP + 120
while time.time() < deadline:
    m, scr = cell.wait_for([DIALOG, "trust the files"], timeout=5)
    low = scr.lower()
    if "trust the files" in low:
        cell.send("1"); time.sleep(0.8); continue
    if DIALOG in low:
        dialog_seen = True
    # observe the probe's two phases on disk
    if os.path.exists(log):
        phases = [json.loads(l).get("phase") for l in open(log) if l.strip()]
        hook_received = "received" in phases
        hook_decided = "deciding" in phases
    if os.path.exists(outfile):
        break
    if cell._dead():
        break

elapsed = time.time() - t0
file_exists = os.path.exists(outfile)
disk = open(outfile).read().strip() if file_exists else None
try:
    cell.send("\x03")
except Exception:
    pass
cell.close()
shutil.rmtree(work, ignore_errors=True)

print("  elapsed              : %.1fs (hook slept %.0fs)" % (elapsed, SLEEP))
print("  hook received call   :", hook_received)
print("  hook decided (post-sleep):", hook_decided)
print("  native dialog shown  :", dialog_seen, "(want False)")
print("  out.txt              :", repr(disk), "(want 'VIGIL_BLOCK_OK')")

ok = file_exists and disk == "VIGIL_BLOCK_OK" and not dialog_seen \
    and hook_decided and elapsed >= SLEEP
print("\n" + "#" * 64)
print("VERDICT G:", "✅ PASS" if ok else "❌ FAIL",
      "— structured perm hook holds across a multi-minute human delay")
if ok:
    print("  decision honored AFTER a %.0fs block, dialog suppressed -> §5.1" % SLEEP)
    print("  perm channel survives real human latency (with a long hook timeout).")
else:
    print("  hook did NOT survive the block -> perm channel needs rethink for")
    print("  real human latency (timeout/keepalive). Details above.")
print("#" * 64)
sys.exit(0 if ok else 1)
