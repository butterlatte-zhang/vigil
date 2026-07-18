"""Stand-in 'agent' running inside the wrapped terminal.

It does NOT know it's being supervised — it just talks to its tty: prints work,
asks for approval on a dangerous step, waits for a human-style keystroke, then
reports a final result. This is what a real CLI agent's I/O looks like to the
controller, minus the ANSI-heavy TUI.
"""
import sys, time

def say(s):
    print(s, flush=True)

say("AGENT> task received: clean stale build artifacts")
time.sleep(0.2)
say("AGENT> scanned workspace, found 3 candidate files")
time.sleep(0.2)

# --- approval gate: the agent blocks on its tty for a decision ---
say("AGENT> This step needs permission.")
say("APPROVAL_REQUIRED tool=Bash cmd=`rm -rf ./build/cache`")
sys.stdout.write("Approve? [y/n] ")
sys.stdout.flush()

decision = sys.stdin.readline().strip().lower()
time.sleep(0.1)

if decision == "y":
    say("AGENT> approved — executing rm -rf ./build/cache")
    time.sleep(0.2)
    say("AGENT> done")
    say("RESULT> SUCCESS: removed 3 files, freed 12.4MB")
else:
    say("AGENT> denied — skipping deletion")
    say("RESULT> ABORTED: no changes made")
