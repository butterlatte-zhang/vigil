"""TEST C — two cells, gated spawn, LCA routing, rollup aggregation.

The controller IS the Vigil session (root/LCA). It owns cell A (manager) and,
on an approved SPAWN_REQUEST, cell B (leaf). It routes B's rollup back up to A
along the tree edge, and captures A's 'rollup of rollup'. This is the tree
mechanic beyond single-node intercept — proven on the same cell primitive that
already drove real claude in step2/D/A."""
import sys, os, re, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from ptyctl import Terminal

PY = sys.executable
NODE = os.path.join(os.path.dirname(__file__), "fake_node.py")

def banner(s): print("\n=== " + s + " " + "=" * (60 - len(s)))

banner("session: spawn cell A (manager) [gate: root task approved]")
A = Terminal([PY, NODE, "manager", "orchestrate: get sum 1..10 via a helper"])
idx, seen = A.expect([r"SPAWN_REQUEST.*"], timeout=10)
req = re.search(r"SPAWN_REQUEST.*", seen).group(0)
print("[A emitted struct event] ", req)

banner("inbox: struct(spawn) -> gate decision")
subtask = re.search(r"task=(\S+)", req).group(1)
print("[gate] auto-approve spawn of leaf with subtask=%r" % subtask)

banner("session: spawn cell B (leaf) in its own terminal")
B = Terminal([PY, NODE, "leaf", subtask])
idxB, seenB = B.expect([r"REPORT:.*"], timeout=10)
b_rollup = re.search(r"REPORT:\s*(.*)", seenB).group(1).strip()
print("[B rollup captured] ", b_rollup)
B.close()

banner("LCA routing: forward B's rollup up the edge into A")
A.sendline("CHILD_REPORT: " + b_rollup)
print("[route] B.rollup --(tree edge)--> A.stdin")

idxA, seenA = A.expect([r"REPORT:\s*manager.*"], timeout=10)
final = re.search(r"REPORT:\s*(manager.*)", seenA).group(1).strip()
A.close()

banner("root sees rollup-of-rollup")
print("[A final rollup] ", final)

ok = ("leaf-summary" in final) and ("sum_1_10=55" in final)
print("\n" + "#" * 64)
print("VERDICT C:", "✅ PASS" if ok else "❌ FAIL",
      "— gated spawn + 2 isolated cells + LCA route + rollup aggregation")
print("  proof: A's rollup transitively contains B's computed summary (sum=55)")
print("#" * 64)
sys.exit(0 if ok else 1)
