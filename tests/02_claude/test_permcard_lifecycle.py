"""notify-v2 M4 Tier-2 pin ① — permission-card LIFECYCLE observability
(builds on the M0 probe test_permreq_pairing.py).

Where M0 asked "does PermissionRequest exist and pair", this test pins the
PRODUCT observation chain at the hook-envelope layer (no GUI needed): the real
`vigil-hook` binary (swift build artifact) is mounted exactly the way
ClaudeCodeHarness.writeAgentConfigs mounts it (PermissionRequest --event
perm-request + PostToolUse --event post-tool, fire-and-forget), and a fake UDS
gateway inside this script records every envelope `{node, event, payload}` —
i.e. exactly what HookGateway.handle would receive to drive the card.

Scenario APPROVE (card appears → resolves via PostToolUse pairing):
  box pops → `perm-request` envelope arrives WHILE the box hangs (card-appear
  signal is real-time, M0 no-debounce) → approve "1" → `post-tool` envelope
  arrives and pairs on the M1 tuple (prompt_id + tool_name + canonical
  tool_input verbatim) → file on disk → F11 anchor leaves the screen.

Scenario DENY (F2 blind spot → scrape is the only fallback):
  box pops → `perm-request` envelope arrives → deny "3. No" → confirm NO
  further hook envelope of any kind fires (F2: the whole turn is cancelled,
  quiet-window check) → the F11 anchor "Do you want to proceed?" disappears
  from the rendered screen = the scrape-side (PermWatcher C3) resolution
  signal is judgeable → file NOT written.

Run with tests/.venv/bin/python (needs pyte). Real claude binary must be the
UNWRAPPED one (default `claude`, CLAUDE_BIN overrides) —
the shell-function-wrapped `claude` adds --dangerously-skip-permissions and
the box never appears. vigil-hook comes from `cd app && swift build`
(VIGIL_HOOK_BIN overrides).

exit 0 = behavior pinned; non-zero = drift (a claude upgrade changed the
lifecycle contract) → re-gate by hand before trusting the notification chain.
"""
import sys, os, json, time, signal, shlex, socket, tempfile, shutil, threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
HOOK_BIN = os.environ.get("VIGIL_HOOK_BIN",
                          os.path.join(REPO, "app", ".build", "debug", "vigil-hook"))
ENV = dict(os.environ); ENV["TERM"] = "xterm-256color"

ANCHOR = "do you want to proceed"      # F11 scrape anchor
TRUST = "trust the files"
NODE = "n-w5"


class FakeGateway:
    """Minimal stand-in for the app's HookGateway UDS server: accept, read one
    envelope line per connection, record it, close. Observation events only —
    nothing is ever written back (D13 fire-and-forget contract)."""
    def __init__(self, path):
        self.path = path
        self.events = []              # [{ts, node, event, payload(dict)}]
        self.lock = threading.Lock()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(16)
        self.alive = True
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while self.alive:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
            line = buf.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
            if not line:
                return
            env = json.loads(line)
            payload = env.get("payload")
            if isinstance(payload, str):
                try:
                    payload = json.loads(payload)
                except Exception:
                    payload = {"_unparsed": payload[:400]}
            with self.lock:
                self.events.append({"ts": time.time(),
                                    "node": env.get("node"),
                                    "event": env.get("event"),
                                    "payload": payload or {}})
        except Exception:
            pass
        finally:
            try: conn.close()
            except OSError: pass

    def snapshot(self):
        with self.lock:
            return list(self.events)

    def close(self):
        self.alive = False
        try: self.srv.close()
        except OSError: pass
        try: os.unlink(self.path)
        except OSError: pass


def of(evts, name):
    return [e for e in evts if e.get("event") == name]


def canon(tool_input):
    return json.dumps(tool_input, sort_keys=True) if tool_input is not None else None


def settings_json(sock):
    """Mirror ClaudeCodeHarness.writeAgentConfigs (observation hooks only)."""
    base = "%s --node %s --sock %s" % (shlex.quote(HOOK_BIN), NODE, shlex.quote(sock))
    return json.dumps({"hooks": {
        "PermissionRequest": [{"hooks": [
            {"type": "command", "command": base + " --event perm-request"}]}],
        "PostToolUse": [{"hooks": [
            {"type": "command", "command": base + " --event post-tool"}]}],
    }})


def wait_anchor_gone(cell, timeout=30):
    """Poll the rendered screen until the F11 anchor is absent — the same
    judgement PermWatcher (C3) makes. Returns seconds it took, or None."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if ANCHOR not in cell.pump(0.5).lower():
            return round(time.time() - t0, 1)
    return None


def run_scenario(label, approve, outname):
    work = tempfile.mkdtemp(prefix="vigil_w5_card_")
    gw = FakeGateway(os.path.join(work, "gw.sock"))
    task = ("Run exactly this shell command and nothing else, then stop: "
            "echo VIGIL_W5 > %s" % outname)
    cell = ScreenCell([CLAUDE, task,
                       "--settings", settings_json(gw.path),
                       "--permission-mode", "default"],
                      env=ENV, cwd=work, rows=50, cols=200)
    r = {"label": label, "box_seen": False, "permreq_before_resolve": 0,
         "anchor_gone_s": None, "posttool": 0, "paired": False,
         "quiet_extra": None, "file_written": None}
    try:
        deadline = time.time() + 180
        while time.time() < deadline:
            m, scr = cell.wait_for([ANCHOR, TRUST], timeout=5, tick=0.2)
            low = scr.lower()
            if TRUST in low and ANCHOR not in low:
                cell.send("1"); time.sleep(0.8); continue
            if ANCHOR in low:
                r["box_seen"] = True
                break
            if cell._dead():
                break
        if r["box_seen"]:
            cell.pump(2.5)  # box hangs — the card-appear envelope must already be in
            r["permreq_before_resolve"] = len(of(gw.snapshot(), "perm-request"))
            n_at_resolve = len(gw.snapshot())
            cell.send("1" if approve else "3")

            if approve:
                # resolution side: post-tool envelope + pairing tuple + file
                wd = time.time() + 60
                while time.time() < wd:
                    cell.pump(0.5)
                    if of(gw.snapshot(), "post-tool"):
                        break
                r["anchor_gone_s"] = wait_anchor_gone(cell)
                wd = time.time() + 45
                while time.time() < wd and not os.path.exists(os.path.join(work, outname)):
                    cell.pump(0.5)
                cell.pump(2.0)  # drain stragglers
                evts = gw.snapshot()
                perm, post = of(evts, "perm-request"), of(evts, "post-tool")
                r["posttool"] = len(post)
                if perm and post:
                    p, q = perm[0]["payload"], post[0]["payload"]
                    r["paired"] = (
                        p.get("prompt_id") is not None
                        and p.get("prompt_id") == q.get("prompt_id")
                        and p.get("tool_name") == q.get("tool_name")
                        and canon(p.get("tool_input")) == canon(q.get("tool_input")))
                    r["node_ok"] = all(e["node"] == NODE for e in (perm[0], post[0]))
            else:
                # deny: scrape-side resolution + F2 quiet window
                r["anchor_gone_s"] = wait_anchor_gone(cell)
                cell.pump(6.0)  # F2 quiet window — nothing may fire after a deny
                evts = gw.snapshot()
                r["quiet_extra"] = len(evts) - n_at_resolve
                r["posttool"] = len(of(evts, "post-tool"))
                perm = of(evts, "perm-request")
                r["node_ok"] = bool(perm) and perm[0]["node"] == NODE
        r["file_written"] = os.path.exists(os.path.join(work, outname))
    finally:
        try: os.kill(cell.pid, signal.SIGKILL)
        except OSError: pass
        cell.close()
        gw.close()
        shutil.rmtree(work, ignore_errors=True)
    return r


print("=" * 72)
print("W5 pin ①: permission-card lifecycle via real vigil-hook envelopes")
print("  claude :", CLAUDE)
print("  hook   :", HOOK_BIN)
print("=" * 72)
if not os.path.exists(HOOK_BIN):
    print("FATAL: vigil-hook not built — run `cd app && swift build` first")
    sys.exit(2)

ap = run_scenario("APPROVE", approve=True, outname="out.txt")
dn = run_scenario("DENY", approve=False, outname="deny_out.txt")

for r in (ap, dn):
    print("\n--- scenario %s ---" % r["label"])
    for k in ("box_seen", "permreq_before_resolve", "posttool", "paired",
              "anchor_gone_s", "quiet_extra", "file_written", "node_ok"):
        if k in r:
            print("  %-24s: %s" % (k, r[k]))

approve_ok = (ap["box_seen"] and ap["permreq_before_resolve"] >= 1
              and ap["posttool"] >= 1 and ap["paired"]
              and ap.get("node_ok") and ap["file_written"]
              and ap["anchor_gone_s"] is not None)
deny_ok = (dn["box_seen"] and dn["permreq_before_resolve"] >= 1
           and dn.get("node_ok")
           and dn["anchor_gone_s"] is not None      # scrape judgement works
           and dn["quiet_extra"] == 0               # F2: nothing fires post-deny
           and dn["posttool"] == 0
           and not dn["file_written"])

print("\n" + "#" * 64)
if approve_ok and deny_ok:
    print("VERDICT W5-①: ✅ PINNED — card appears via perm-request envelope in")
    print("  real time; approve resolves via post-tool with the M1 pairing tuple")
    print("  (prompt_id + tool_name + tool_input verbatim); deny fires NOTHING")
    print("  (F2) and the F11 anchor vanishing off-screen is a clean scrape signal.")
else:
    print("VERDICT W5-①: ❌ DRIFT — lifecycle contract changed, re-gate by hand")
    if not approve_ok:
        print("  approve path failed: %s" % ap)
    if not deny_ok:
        print("  deny path failed: %s" % dn)
print("#" * 64)
sys.exit(0 if (approve_ok and deny_ok) else 1)
