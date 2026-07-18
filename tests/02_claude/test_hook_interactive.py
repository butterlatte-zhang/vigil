"""TEST F — does a PreToolUse hook decision SUPPRESS claude's native approval
dialog when claude runs as an INTERACTIVE TUI inside a PTY?

This closes the last open item in §5.1 (line: "under an interactive TUI,
does an automatic hook decision suppress the native prompt box = pending final
confirmation for Phase 0"). §12.5-B already proved structured hooks
in HEADLESS mode (`claude -p`). But Vigil wraps the INTERACTIVE claude TUI in a
PTY — so the architectural question is: in that interactive form, does returning
permissionDecision=allow/deny from a hook make the decision WITHOUT the
"Do you want to proceed?" box ever appearing? If yes, perm is a structured-hook
channel (no scrape needed). If the box still appears, perm must fall back to
vt100 scrape+inject.

For each policy we launch interactive claude in a vt100 cell with the hook wired
via --settings, and measure: (a) did the native dialog appear on screen?
(b) did the hook actually fire? (c) does the file outcome match the decision?
"""
import sys, os, re, json, time, tempfile, shutil
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
PY = sys.executable
PROBE = os.path.join(os.path.dirname(__file__), "hook_probe.py")
ENV = dict(os.environ); ENV["TERM"] = "xterm-256color"

DIALOG = "do you want to proceed"


def run_case(label, decision, task, marker):
    work = tempfile.mkdtemp(prefix="vigil_hookint_")
    log = os.path.join(work, "intercepted.jsonl")
    outfile = os.path.join(work, "out.txt")
    settings = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": "%s %s %s %s" % (PY, PROBE, log, decision)}]}]}}

    cell = ScreenCell([CLAUDE, task,
                       "--settings", json.dumps(settings),
                       "--permission-mode", "default"],
                      env=ENV, cwd=work, rows=50, cols=200)

    dialog_seen = False
    hook_fired = False
    deadline = time.time() + 100
    while time.time() < deadline:
        m, scr = cell.wait_for([DIALOG, "trust the files"], timeout=5)
        low = scr.lower()
        if "trust the files" in low:        # folder-trust gate != the perm dialog
            cell.send("1"); time.sleep(0.8); continue
        if DIALOG in low:
            dialog_seen = True              # the native perm box DID show up
        if os.path.exists(log):
            hook_fired = True
            # hook fired: pump a bit more to catch a late dialog or file write
            scr2 = cell.pump(8)
            if DIALOG in scr2.lower():
                dialog_seen = True
            break
        if cell._dead():
            break

    file_exists = os.path.exists(outfile)
    saw_keys = []
    if os.path.exists(log):
        try:
            saw_keys = json.loads(open(log).readline()).get("saw_keys", [])
        except Exception:
            pass
    try:
        cell.send("\x03")
    except Exception:
        pass
    cell.close()
    shutil.rmtree(work, ignore_errors=True)

    # suppression holds iff: hook fired, dialog never appeared, file matches decision
    file_ok = (file_exists == (decision == "allow"))
    suppressed = hook_fired and (not dialog_seen) and file_ok
    print("\n--- case %s (forced %s) ---" % (label, decision))
    print("  hook fired           :", hook_fired)
    print("  native dialog shown  :", dialog_seen, "(want False = suppressed)")
    print("  file %-16s: %s (want %s)" % (
        os.path.basename(outfile) + " exists", file_exists, decision == "allow"))
    print("  structured keys seen :", saw_keys)
    print("  => decision honored WITHOUT scrape:", "✅" if suppressed else "❌")
    return suppressed, dialog_seen, hook_fired


print("=" * 72)
print("TEST F: does a hook decision suppress the native dialog in INTERACTIVE TUI?")
print("  bin :", CLAUDE)
print("=" * 72)

allow_ok, allow_dialog, allow_fired = run_case(
    "ALLOW", "allow",
    "Run exactly this shell command and nothing else: "
    "echo VIGIL_HOOK_INT_OK > out.txt ; then read out.txt and report its contents.",
    "VIGIL_HOOK_INT_OK")

deny_ok, deny_dialog, deny_fired = run_case(
    "DENY", "deny",
    "Run exactly this shell command and nothing else: "
    "echo VIGIL_SHOULD_NOT_WRITE > out.txt . Then tell me whether it was blocked.",
    "VIGIL_SHOULD_NOT_WRITE")

ok = allow_ok and deny_ok
print("\n" + "#" * 64)
print("VERDICT F:", "✅ PASS" if ok else "❌ FAIL",
      "— interactive-TUI hook = structured perm channel")
if ok:
    print("  hook decision (allow & deny) honored, native dialog SUPPRESSED,")
    print("  no screen scrape needed -> §5.1 primary path holds in interactive TUI.")
else:
    print("  hook did NOT fully suppress the dialog / honor decision ->")
    print("  perm must fall back to vt100 scrape+inject (§5.1 fallback). Details above.")
print("#" * 64)
sys.exit(0 if ok else 1)
