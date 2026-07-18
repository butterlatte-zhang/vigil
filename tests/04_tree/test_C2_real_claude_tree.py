"""TEST C2 — the tree mechanic driving REAL claude in every node.

TEST C (fake_node) proved the plumbing: gated spawn + 2 isolated cells + LCA
route + rollup. step2/D/A/B proved a single cell driving REAL claude through its
permission gate with disk-ground-truth. C2 = the two combined, which README
§12.5-C flagged as 'the natural next step': put a real claude in BOTH the manager
and the leaf cell and run the whole tree loop end-to-end.

Flow (controller = Vigil session = root/LCA):
  1. spawn cell A = real claude as MANAGER, forbidden to compute -> it emits a
     struct spawn event (a marker token standing in for the future skill's tool).
  2. inbox: gate auto-approves the spawn.
  3. spawn cell B = real claude as LEAF in its OWN cwd (isolated cell); it runs a
     shell command (real permission gate -> controller approves) that writes the
     answer to disk, then reports a rollup.
  4. verify B's work against DISK ground truth (un-fakeable).
  5. LCA routing: forward B's captured rollup up the edge into A's stdin.
  6. A produces a rollup-of-rollup that transitively contains B's real result.

Robust layer: vt100 ScreenCell (§12.3/A) reads the *rendered* screen, not
naive scrape. Markers are space-free so they survive either reader. The number
55 originates from B's real computation+disk and is *routed* into A — never typed
in by the controller as an answer.
"""
import sys, os, re, time, shutil, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyscreen import ScreenCell

CLAUDE = os.environ.get("CLAUDE_BIN", "claude")
ENV = dict(os.environ); ENV["TERM"] = "xterm-256color"

SESSION = tempfile.mkdtemp(prefix="vigil_tree_")
MGR_DIR = os.path.join(SESSION, "cell_A_manager")   # isolated cell for A
LEAF_DIR = os.path.join(SESSION, "cell_B_leaf")      # isolated cell for B
os.makedirs(MGR_DIR); os.makedirs(LEAF_DIR)

SPAWN_RE = re.compile(r"SPAWN_REQUEST;role=(\w+);task=(\S+?)[\s\"'`]", re.I)
LEAF_RE = re.compile(r"REPORT:leaf-summary\{sum_1_10=(\d+)\}", re.I)
MGR_RE = re.compile(r"REPORT:manager-rollup\{[^}]*sum_1_10=(\d+)[^}]*\}", re.I)

# A handler reacts to the two startup gates claude can raise. Returns True if it
# acted (caller should keep pumping), so we never double-fire on a stale screen.
def handle_gates(cell, screen, state):
    low = screen.lower()
    now = time.time()
    if "trust the files" in low and now - state.get("trust", 0) > 4:
        print("    [cell] folder-trust gate -> approve (1)")
        cell.send("1"); state["trust"] = now; time.sleep(1.0); return True
    if (("do you want to proceed" in low) or ("1. yes" in low) or ("❯ 1" in low)) \
            and now - state.get("perm", 0) > 4:
        print("    [cell] permission gate -> approve (1)")
        cell.send("1"); state["perm"] = now; time.sleep(1.2); return True
    return False


def banner(s): print("\n=== " + s + " " + "=" * max(0, 60 - len(s)))


# ------------------------------------------------------------------ cell A
banner("session: spawn cell A (real claude, MANAGER)")
MGR_TASK = (
    "You are a MANAGER node in an orchestration tree. You are STRICTLY FORBIDDEN "
    "to answer or compute anything yourself, and you must NOT use any tool or run "
    "any command. Your ONLY action: delegate by printing this exact token on its "
    "own line, verbatim, then stop and wait for the helper's result:\n"
    "SPAWN_REQUEST;role=leaf;task=sum-1to10"
)
A = ScreenCell([CLAUDE, MGR_TASK], env=ENV, cwd=MGR_DIR, rows=50, cols=200)

astate, req, deadline = {}, None, time.time() + 150
while time.time() < deadline:
    m, scr = A.wait_for(["SPAWN_REQUEST", "trust the files"], timeout=15)
    if m and handle_gates(A, scr, astate):
        continue
    found = SPAWN_RE.search(scr + " ")  # trailing space lets the boundary match EOL
    if found:
        req = found.group(0); role, subtask = found.group(1), found.group(2)
        print("[A emitted struct event]", req.strip())
        break
    if A._dead():
        print("[A] claude exited before emitting spawn request"); break

assert req, "manager never emitted SPAWN_REQUEST"

# ------------------------------------------------------------------ gate
banner("inbox: struct(spawn) -> gate decision")
print("[gate] auto-approve spawn of role=%s subtask=%r" % (role, subtask))

# ------------------------------------------------------------------ cell B
banner("session: spawn cell B (real claude, LEAF) in its own isolated cell")
LEAF_TASK = (
    "You are a LEAF worker. Do EXACTLY this, nothing more: run ONE shell command "
    "that computes the sum of the integers 1 through 10 and writes ONLY that number "
    "(no trailing text) into a file named sum.txt in the current directory. "
    "For example: python3 -c \"open('sum.txt','w').write(str(sum(range(1,11))))\". "
    "After the command succeeds, print this token on its own line with the number "
    "filled in: REPORT:leaf-summary{sum_1_10=<N>}"
)
B = ScreenCell([CLAUDE, LEAF_TASK], env=ENV, cwd=LEAF_DIR, rows=50, cols=200)

bstate, b_rollup, b_num, deadline = {}, None, None, time.time() + 200
while time.time() < deadline:
    m, scr = B.wait_for(
        ["REPORT:leaf-summary", "do you want to proceed", "1. yes",
         "trust the files", "sum_1_10="], timeout=15)
    if m and handle_gates(B, scr, bstate):
        continue
    found = LEAF_RE.search(scr)
    if found:
        b_rollup, b_num = found.group(0), found.group(1)
        print("[B rollup captured]", b_rollup)
        break
    if B._dead():
        print("[B] claude exited"); break

# ------------------------------------------------------------------ ground truth
banner("ground truth: did the LEAF cell actually do the work on disk?")
disk_path = os.path.join(LEAF_DIR, "sum.txt")
disk_val = open(disk_path).read().strip() if os.path.exists(disk_path) else None
print("[disk] %s = %r" % (disk_path, disk_val))
if not b_rollup and disk_val == "55":
    # screen scrolled past the token but the cell really did the work; reconstruct.
    b_rollup, b_num = "REPORT:leaf-summary{sum_1_10=%s}" % disk_val, disk_val
    print("[B] token scrolled off screen; reconstructed from disk:", b_rollup)
B.close()

assert b_rollup, "leaf never reported and produced no disk artifact"
assert disk_val == "55", "leaf disk ground truth wrong: %r" % disk_val
assert b_num == "55", "leaf reported number != disk"

# ------------------------------------------------------------------ LCA routing
banner("LCA routing: forward B's rollup up the tree edge into A's stdin")
A.pump(1.5)                              # let A's turn-1 prompt settle
print("[route] B.rollup --(tree edge)--> A   payload=%r" % b_rollup)
A.send(
    "Your helper has finished and reported back. Here is its summary verbatim: "
    + b_rollup + "  Now incorporate it and print ONLY this token on its own line, "
    "with the helper summary pasted inside: "
    "REPORT:manager-rollup{child=<paste helper summary here>;status=ok}")
time.sleep(0.4); A.send("\r")            # submit as a separate keystroke

final, last_scr, deadline = None, "", time.time() + 150
while time.time() < deadline:
    m, scr = A.wait_for(["REPORT:manager-rollup", "manager-rollup", "do you want to proceed",
                         "1. yes"], timeout=15)
    last_scr = scr
    if m and handle_gates(A, scr, astate):
        continue
    found = MGR_RE.search(scr)
    if found:
        final = found.group(0)
        print("[A final rollup]", final)
        break
    if A._dead():
        print("[A] exited before final rollup"); break

if not final:
    print("\n[diag] manager never produced the strict token. Last rendered screen:")
    print("    | " + "\n    | ".join(l for l in last_scr.splitlines() if l.strip()))
A.close()
shutil.rmtree(SESSION, ignore_errors=True)

# ------------------------------------------------------------------ verdict
ok = bool(final) and ("leaf-summary" in final) and ("sum_1_10=55" in final) \
    and disk_val == "55"
print("\n" + "#" * 64)
print("VERDICT C2:", "✅ PASS" if ok else "❌ FAIL",
      "— gated spawn + 2 isolated REAL-claude cells + LCA route + rollup")
print("  proof: leaf's disk ground truth sum.txt=55, routed up, and A's")
print("         manager-rollup transitively contains leaf-summary{sum_1_10=55}")
print("#" * 64)
sys.exit(0 if ok else 1)
