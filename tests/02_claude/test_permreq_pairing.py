"""M0 probe gate — is `PermissionRequest`
supported on claude CLI 2.1.201 INTERACTIVE TUI, and can it be paired with
`PostToolUse` via tool_use_id?

Three questions, each answered from a real interactive claude in a vt100 PTY
cell with observe-only hooks (empty stdout, exit 0 — native dialog untouched):

  Q1  Does a PermissionRequest hook fire when the native permission box
      appears?  Does its payload carry tool_use_id (the pairing key that
      PostToolUse also carries, F1)?
  Q2  Fast-approval: if the box is approved ~immediately, does
      PermissionRequest still fire — or is it debounced away like
      Notification(permission_prompt) (F3)?
  Q3  Is PermissionRequest.tool_use_id == PostToolUse.tool_use_id for the
      same tool call (exact pairing for the C2 lifecycle card)?
  Q4  If the payloads pair via prompt_id instead (2.1.201 reality): is
      prompt_id unique PER TOOL CALL, or shared across all permission
      requests of one user turn (which would demote it to a scoping key)?

Scenario SLOW : let the box hang ~4s before approving (mirrors a real user).
Scenario FAST : approve the instant the box is detected (~0.2s poll tick).
Scenario MULTI: two separate Bash calls in ONE user turn, approve both —
                answers Q4 by comparing the two PermissionRequest prompt_ids.
All wire Notification as a reference channel for the F3 contrast.

Run with tests/.venv/bin/python (needs pyte). Real claude binary must be the
UNWRAPPED one (default `claude`, CLAUDE_BIN overrides) —
the shell-function-wrapped `claude` adds --dangerously-skip-permissions and
the box never appears.

PASS = probe reached a definitive verdict in both scenarios (box seen,
approval landed, PostToolUse observed, out.txt on disk). The verdict block at
the end states SUPPORTED / NOT-SUPPORTED for the C2 gate.
"""
import sys, os, json, time, signal, tempfile, shutil

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
PY = sys.executable
PROBE = os.path.join(os.path.dirname(__file__), "permreq_probe.py")
ENV = dict(os.environ); ENV["TERM"] = "xterm-256color"

DIALOG = "do you want to proceed"
TRUST = "trust the files"
TASK = ("Run exactly this shell command and nothing else, then stop: "
        "echo VIGIL_M0_PROBE > out.txt")


def read_events(log):
    if not os.path.exists(log):
        return []
    out = []
    for line in open(log):
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def events_of(evts, name):
    return [e for e in evts if e.get("event") == name]


def run_scenario(label, hang_before_approve, task=TASK, n_approvals=1,
                 outnames=("out.txt",)):
    work = tempfile.mkdtemp(prefix="vigil_m0_%s_" % label.lower())
    log = os.path.join(work, "hooks.jsonl")
    hook = {"type": "command", "command": "%s %s %s" % (PY, PROBE, log)}
    settings = {"hooks": {
        "PermissionRequest": [{"hooks": [hook]}],
        "PostToolUse":       [{"hooks": [hook]}],
        "Notification":      [{"hooks": [hook]}],
    }}

    cell = ScreenCell([CLAUDE, task,
                       "--settings", json.dumps(settings),
                       "--permission-mode", "default"],
                      env=ENV, cwd=work, rows=50, cols=200)
    result = {"label": label, "dialog_seen": False, "approved": False,
              "dialog_to_approve_s": None}
    approvals = 0
    try:
        deadline = time.time() + 180
        while time.time() < deadline and approvals < n_approvals:
            m, scr = cell.wait_for([DIALOG, TRUST], timeout=5, tick=0.2)
            low = scr.lower()
            if TRUST in low and DIALOG not in low:
                cell.send("1"); time.sleep(0.8); continue
            if DIALOG in low:
                result["dialog_seen"] = True
                t_dialog = time.time()
                if hang_before_approve and approvals == 0:
                    cell.pump(4.0)      # box hangs — a real user thinking
                cell.send("1")          # ❯ 1. Yes  (F11 anchor)
                approvals += 1
                result["approved"] = True
                if result["dialog_to_approve_s"] is None:
                    result["dialog_to_approve_s"] = round(time.time() - t_dialog, 2)
                # wait for THIS approval's PostToolUse before scanning for the
                # next box (the resolved box lingers on screen otherwise)
                wd = time.time() + 45
                while time.time() < wd:
                    cell.pump(0.5)
                    if len(events_of(read_events(log), "PostToolUse")) >= approvals:
                        break
                continue
            if cell._dead():
                break

        # after final approval: wait for all files on disk
        post_deadline = time.time() + 60
        while time.time() < post_deadline:
            cell.pump(1.0)
            if all(os.path.exists(os.path.join(work, n)) for n in outnames):
                break
        cell.pump(2.0)  # drain any straggler hook writes
        result["file_written"] = all(
            os.path.exists(os.path.join(work, n)) for n in outnames)
        result["events"] = read_events(log)
        result["final_screen_tail"] = "\n".join(
            l for l in cell.display().splitlines() if l.strip())[-600:]
    finally:
        try: os.kill(cell.pid, signal.SIGKILL)
        except OSError: pass
        cell.close()
        shutil.rmtree(work, ignore_errors=True)
    return result


def summarize(res):
    evts = res.get("events", [])
    perm = events_of(evts, "PermissionRequest")
    post = events_of(evts, "PostToolUse")
    notif = [e for e in events_of(evts, "Notification")
             if "permission" in json.dumps(e.get("raw", {})).lower()]
    def tin(e):
        return (e.get("raw") or {}).get("tool_input")

    s = {
        "label": res["label"],
        "dialog_seen": res["dialog_seen"],
        "approved": res["approved"],
        "dialog_to_approve_s": res["dialog_to_approve_s"],
        "file_written": res.get("file_written"),
        "permreq_fired": len(perm),
        "permreq_keys": perm[0]["keys"] if perm else None,
        "permreq_tool_use_id": perm[0].get("tool_use_id") if perm else None,
        "permreq_prompt_id": (perm[0].get("raw") or {}).get("prompt_id") if perm else None,
        "posttool_fired": len(post),
        "posttool_keys": post[0]["keys"] if post else None,
        "posttool_tool_use_id": post[0].get("tool_use_id") if post else None,
        "posttool_prompt_id": (post[0].get("raw") or {}).get("prompt_id") if post else None,
        "notif_permission_fired": len(notif),
        # exact pairing: a key shared verbatim by both events
        "pairing_tool_use_id": bool(perm and post
                                    and perm[0].get("tool_use_id")
                                    and perm[0].get("tool_use_id") == post[0].get("tool_use_id")),
        "pairing_prompt_id": bool(perm and post
                                  and (perm[0].get("raw") or {}).get("prompt_id")
                                  and (perm[0].get("raw") or {}).get("prompt_id")
                                  == (post[0].get("raw") or {}).get("prompt_id")),
        # fallback pairing: identical tool_input payloads (same command string)
        "pairing_tool_input": bool(perm and post and tin(perm[0]) is not None
                                   and tin(perm[0]) == tin(post[0])),
    }
    if perm:
        s["permreq_raw"] = perm[0].get("raw")
    if post:
        s["posttool_raw"] = post[0].get("raw")
    return s


print("=" * 72)
print("M0 PROBE: PermissionRequest support + tool_use_id pairing (interactive TUI)")
print("  bin :", CLAUDE)
print("=" * 72)

MULTI_TASK = ("Run exactly these two shell commands as TWO SEPARATE Bash tool "
              "calls, one at a time, in order, then stop. Do not combine them "
              "into one command. First: echo A > a.txt   Second: echo B > b.txt")

slow = summarize(run_scenario("SLOW", hang_before_approve=True))
fast = summarize(run_scenario("FAST", hang_before_approve=False))
multi_res = run_scenario("MULTI", hang_before_approve=False,
                         task=MULTI_TASK, n_approvals=2,
                         outnames=("a.txt", "b.txt"))

for s in (slow, fast):
    print("\n--- scenario %s (approve after %ss) ---"
          % (s["label"], s["dialog_to_approve_s"]))
    for k in ("dialog_seen", "approved", "file_written", "permreq_fired",
              "permreq_tool_use_id", "permreq_prompt_id", "posttool_fired",
              "posttool_tool_use_id", "posttool_prompt_id",
              "pairing_tool_use_id", "pairing_prompt_id", "pairing_tool_input",
              "notif_permission_fired"):
        print("  %-24s: %s" % (k, s[k]))
    if s.get("permreq_keys"):
        print("  %-24s: %s" % ("permreq payload keys", s["permreq_keys"]))
    if s.get("posttool_keys"):
        print("  %-24s: %s" % ("posttool payload keys", s["posttool_keys"]))
    if s.get("permreq_raw"):
        print("  %-24s: %s" % ("permreq raw (sans resp)",
                               json.dumps(s["permreq_raw"])[:600]))
    if s.get("posttool_raw"):
        print("  %-24s: %s" % ("posttool raw (sans resp)",
                               json.dumps(s["posttool_raw"])[:600]))

# --- Q4: prompt_id granularity (per tool call vs per user turn) ---
m_evts = multi_res.get("events", [])
m_perm = events_of(m_evts, "PermissionRequest")
m_post = events_of(m_evts, "PostToolUse")
m_perm_pids = [(e.get("raw") or {}).get("prompt_id") for e in m_perm]
m_post_pids = [(e.get("raw") or {}).get("prompt_id") for e in m_post]
prompt_id_unique_per_call = (len(m_perm_pids) == 2
                             and None not in m_perm_pids
                             and m_perm_pids[0] != m_perm_pids[1])
print("\n--- scenario MULTI (2 approvals in one user turn) ---")
print("  %-24s: %s" % ("dialog_seen/approved", "%s/%s" % (
    multi_res["dialog_seen"], multi_res["approved"])))
print("  %-24s: %s" % ("files written (a+b)", multi_res.get("file_written")))
print("  %-24s: %s" % ("permreq fired", len(m_perm)))
print("  %-24s: %s" % ("posttool fired", len(m_post)))
print("  %-24s: %s" % ("permreq prompt_ids", m_perm_pids))
print("  %-24s: %s" % ("posttool prompt_ids", m_post_pids))
print("  %-24s: %s" % ("permreq commands", [
    ((e.get("raw") or {}).get("tool_input") or {}).get("command") for e in m_perm]))
print("  %-24s: %s (True = usable as per-request exact key)"
      % ("prompt_id per-call unique", prompt_id_unique_per_call))

probe_conclusive = all(s["dialog_seen"] and s["approved"] and s["file_written"]
                       and s["posttool_fired"] for s in (slow, fast))
appearance_ok = slow["permreq_fired"] > 0 and fast["permreq_fired"] > 0
exact_pairing = all(s["pairing_tool_use_id"] or s["pairing_prompt_id"]
                    for s in (slow, fast))
input_pairing = all(s["pairing_tool_input"] for s in (slow, fast))

print("\n" + "#" * 64)
if not probe_conclusive:
    print("VERDICT M0: ❌ INCONCLUSIVE — probe did not complete both scenarios")
elif appearance_ok and exact_pairing:
    key = ("tool_use_id" if slow["pairing_tool_use_id"]
           else "prompt_id (%s per tool call)"
           % ("unique" if prompt_id_unique_per_call else "SHARED within a turn — scope key only, refine with tool_input"))
    print("VERDICT M0: ✅ FULLY SUPPORTED — PermissionRequest fires on box")
    print("  appearance (no debounce, fast-approve included) AND shares an exact")
    print("  pairing key with PostToolUse: %s → C2 primary approach holds" % key)
elif appearance_ok:
    print("VERDICT M0: ✅ APPEARANCE / ⚠️ NO SHARED ID — PermissionRequest fires")
    print("  reliably (no debounce) so the appearance side = PermissionRequest (NOT the")
    print("  Notification fallback), but no tool_use_id/prompt_id is shared with")
    print("  PostToolUse → resolution-side pairing = node + tool_name + tool_input%s + time window"
          % (" (verbatim-equal, verified)" if input_pairing else ""))
else:
    print("VERDICT M0: ⚠️ NOT SUPPORTED → C2 fallback: appearance side Notification(permission_prompt),")
    print("  resolution side pairs weakly by node + tool name + time window")
print("#" * 64)
# regression pin (2026-07-06, claude 2.1.201): appearance via PermissionRequest
# works, pairing is by tool_name+tool_input (no shared id). A future claude
# adding a shared id will flip exact_pairing and should be re-gated by hand.
sys.exit(0 if (probe_conclusive and appearance_ok and
               (exact_pairing or input_pairing)) else 1)
