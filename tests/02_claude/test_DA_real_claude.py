"""TEST D + A together against real claude, using the vt100-screen cell.

D: drive claude to a permission gate, then DENY -> prove the file is NOT written
   (the gate actually gates), then a second run APPROVE for contrast.
A: detection now reads the *rendered screen* (pyte), so the dialog text is clean
   (no 'Doyouwanttoproceed?' collapse). We print the exact rendered dialog block.
"""
import sys, os, re, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")


def run(decision_label, inject_key, workdir):
    os.makedirs(workdir, exist_ok=True)
    for f in os.listdir(workdir):
        try: os.remove(os.path.join(workdir, f))
        except OSError: pass
    task = ("Run exactly this shell command and nothing else: "
            "echo VIGIL_%s_$(date +%%s) > result.txt ; "
            "then read result.txt and report its contents." % decision_label)
    env = dict(os.environ); env["TERM"] = "xterm-256color"
    c = ScreenCell([CLAUDE, task], env=env, cwd=workdir)

    print("\n" + "=" * 72)
    print("RUN [%s]  inject=%r  cwd=%s" % (decision_label, inject_key, workdir))
    print("=" * 72)

    hit, scr = c.wait_for(["do you want to proceed", "1. yes"], timeout=90)
    if not hit:
        print("  !! never reached permission gate"); c.close(); return None

    # --- Test A payoff: print the clean, rendered dialog lines ---
    print("  [cell] rendered permission dialog (vt100 screen, spaces intact):")
    for line in scr.splitlines():
        if re.search(r"(proceed|1\.\s*Yes|2\.\s*No|Bash|result\.txt)", line, re.I):
            print("        |", line.strip())

    print("  [gate] decision = %s -> inject %r" % (decision_label, inject_key))
    c.send(inject_key)

    # let it finish / settle
    _, scr = c.wait_for(["VIGIL_%s" % decision_label, "No, and tell", "what to do differently"], timeout=60)
    time.sleep(2)
    try: c.send("\x03"); time.sleep(0.3); c.send("\x03")
    except Exception: pass
    c.close()

    rf = os.path.join(workdir, "result.txt")
    on_disk = open(rf).read().strip() if os.path.exists(rf) else None
    print("  [ground truth] result.txt =", repr(on_disk))
    return on_disk


deny = run("DENY", "2", "/tmp/vigil_deny")      # select '2. No'
allow = run("ALLOW", "1", "/tmp/vigil_allow")   # select '1. Yes'

print("\n" + "#" * 72)
print("VERDICT D (gate truly gates):")
print("  DENY  -> file written? ", "YES (BUG!)" if deny else "NO  ✅ gate blocked it")
print("  ALLOW -> file written? ", ("YES ✅ (%s)" % allow) if allow else "NO (unexpected)")
print("VERDICT A (vt100 fixes scrape): dialog lines above show intact spacing,")
print("  e.g. 'Do you want to proceed?' not 'Doyouwanttoproceed?'")
print("#" * 72)
