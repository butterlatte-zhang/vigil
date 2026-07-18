"""A node living in a cell. Manager asks to spawn a helper and waits for its
rollup; leaf does work and reports a summary. Line protocol over its tty —
this is the tree plumbing (spawn/route/rollup) stripped of TUI noise."""
import sys, time
role = sys.argv[1]
task = sys.argv[2] if len(sys.argv) > 2 else ""
def say(s): print(s, flush=True)

say("NODE[%s]> online, task=%r" % (role, task))
time.sleep(0.1)

if role == "manager":
    # manager decides it needs a child -> emits a struct event, then blocks
    say("NODE[manager]> subtask needs a helper")
    say("SPAWN_REQUEST role=leaf task=sum-1..10")        # struct event -> gate
    say("NODE[manager]> waiting for child rollup")
    line = sys.stdin.readline().strip()                  # routed child rollup arrives here
    child = line.split("CHILD_REPORT:", 1)[1].strip() if "CHILD_REPORT:" in line else "(none)"
    time.sleep(0.1)
    say("REPORT: manager-rollup{ child=%s ; status=ok }" % child)   # rollup up to parent/root
else:  # leaf
    say("NODE[leaf]> computing sum 1..10")
    total = sum(range(1, 11))
    time.sleep(0.1)
    say("REPORT: leaf-summary{ sum_1_10=%d }" % total)   # rollup
