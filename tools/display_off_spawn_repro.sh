#!/bin/bash
# display_off_spawn_repro.sh — issue #30 display-off spawn repro / self-heal
# acceptance (Tier-2 manual)
#
# Background: libghostty welds the child-process exec into surface init
# (renderer runs first, and its failure takes the whole init down with it).
# Under a deep display-off (+immediate lock), WindowServer refuses Metal
# renderer init -> ghostty_surface_new fails -> the child process is never
# born; within that same black-screen window, SwiftTerm headless spawns as
# usual (confirmed by the 0708 third experiment, 68s black screen, zero
# ghostty spawns). Expected behavior after the fix (#30 leg 1): spawns are
# still rejected while the screen is off (a physical boundary), but the
# instant the screen wakes/unlocks, SurfaceSpawnRetry's hook rebuilds the
# surface automatically and the child process is born.
#
# Usage: run with a human present (do not touch keyboard/mouse/Touch ID while
# the screen is off — HID/biometric input very easily wakes the screen
# instantly and taints the window; the script validates with `pmset -g log`
# at the end and marks a tainted window INVALID for a re-run).
#
#   tools/display_off_spawn_repro.sh
#
# Steps: pre-build the probe -> pmset displaysleepnow -> settle 25s in the
# dark -> launch the probe (vigil-parity's ghostty spawn path) -> ps-sample
# to determine whether the child process was born -> caffeinate -u to wake
# the screen -> keep sampling to observe self-heal -> validate the window is
# clean with `pmset -g log`.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/app"
OUT="$(mktemp -d /tmp/vigil_30_repro.XXXXXX)"
PARITY_LOG="$OUT/parity.log"
DARK_SAMPLES="$OUT/spawns_dark.txt"
WAKE_SAMPLES="$OUT/spawns_awake.txt"

DARK_SETTLE=25        # seconds to settle in deep dark after display-off (a shallow-dark state doesn't repro — experiments 1/2 were both tainted by instant wake)
DARK_SAMPLE_SECS=40   # ps sampling duration while the screen is dark
WAKE_SAMPLE_SECS=40   # ps sampling duration after waking (self-heal backoff is 5s*2^n; 40s covers the first three tiers plus the notification path)

note() { echo "[$(date '+%H:%M:%S')] $*"; }

# ps-based determination: every cell ghostty spawns runs via
# /tmp/vigil_ghostty_<uuid>/launch.sh — that path being visible in `ps`
# means "the child process was born." Sampling collects a dedup count over
# run-dirs.
sample_spawns() { # $1=duration $2=output file
    local end=$((SECONDS + $1))
    : > "$2"
    while [ $SECONDS -lt $end ]; do
        ps -axo command | grep -o 'vigil_ghostty_[A-F0-9-]*' >> "$2" 2>/dev/null
        sleep 1
    done
    sort -u "$2" | grep -c . || true
}

note "== #30 display-off spawn repro =="
note "output dir: $OUT"

# 0) Pre-build: compiling must never happen inside the black-screen window
#    (it would push the "probe launch moment" outside the window).
note "0) pre-build the probe (swift build)…"
(cd "$APP" && swift build --product vigil-parity) >"$OUT/build.log" 2>&1 \
    || { note "build failed, see $OUT/build.log"; exit 1; }

note "!! display-off imminent: do not touch keyboard/mouse/Touch ID until the script wakes the screen itself !!"
sleep 3

# 1) Turn the display off + settle deep.
T0_EPOCH=$(date +%s)
T0_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
note "1) pmset displaysleepnow (T0=$T0_HUMAN)"
pmset displaysleepnow
sleep "$DARK_SETTLE"

# 2) Launch the probe while the screen is dark: vigil-parity exercises both
#    the headless (SwiftTerm) and ghostty spawn paths at once — the headless
#    side passing is the control group for "spawning a process doesn't need
#    a display."
note "2) launching the vigil-parity probe while the screen is dark…"
(cd "$APP" && swift run --skip-build vigil-parity) >"$PARITY_LOG" 2>&1 &
PARITY_PID=$!

# 3) Sample while the screen is dark: expected to be 0 both before and after
#    the fix (a physical boundary — the renderer is still refused while the
#    display is off).
note "3) ps sampling while dark for ${DARK_SAMPLE_SECS}s…"
DARK_COUNT=$(sample_spawns "$DARK_SAMPLE_SECS" "$DARK_SAMPLES")
note "   ghostty child processes born within the dark window: $DARK_COUNT"

# 4) Wake the screen (this is the moment the self-heal hook screensDidWake
#    should fire).
T_WAKE_EPOCH=$(date +%s)
note "4) caffeinate -u to wake the display (T_wake=$(date '+%H:%M:%S'))"
caffeinate -u -t 5

# 5) Keep sampling after the screen wakes: expected >0 after the #30 fix
#    (the hook/backoff retry rebuilds the surface -> the child is born).
note "5) ps sampling after wake for ${WAKE_SAMPLE_SECS}s (waiting for self-heal)…"
WAKE_COUNT=$(sample_spawns "$WAKE_SAMPLE_SECS" "$WAKE_SAMPLES")
note "   ghostty child processes born after wake: $WAKE_COUNT"

wait "$PARITY_PID" 2>/dev/null
note "   parity output tail:"
tail -5 "$PARITY_LOG" | sed 's/^/     /'

# 6) Window validation (mandatory): there must be no "display on" event
#    between T0..T_wake — HID/Touch ID waking the screen instantly turns the
#    "black-screen window" into a lit control group, which is how both
#    earlier experiments got invalidated.
note "6) pmset -g log validating the window is clean…"
WINDOW_EVENTS=$(pmset -g log | grep -E "Display is turned (on|off)" | \
    awk -v t0="$T0_HUMAN" -v tw="$(date -r "$T_WAKE_EPOCH" '+%Y-%m-%d %H:%M:%S')" \
        '$1" "$2 >= t0 && $1" "$2 <= tw' )
echo "$WINDOW_EVENTS" | sed 's/^/     /'
POLLUTED=$(echo "$WINDOW_EVENTS" | grep -c "Display is turned on" || true)

echo
note "== verdict =="
if [ "$POLLUTED" -gt 1 ]; then
    # 1 "on" event is allowed: the script's own caffeinate -u wake (it lands
    # right at the window's trailing edge).
    note "INVALID: the dark window was tainted by a mid-run wake (HID/Touch ID?); re-run and keep hands off."
    exit 2
fi
note "born while dark $DARK_COUNT (expected 0 = repro holds), born after wake $WAKE_COUNT"
if [ "$DARK_COUNT" -eq 0 ] && [ "$WAKE_COUNT" -gt 0 ]; then
    note "PASS: display-off blocks the repro + wake self-heals the missing spawn (#30 fix works)."
    exit 0
elif [ "$DARK_COUNT" -eq 0 ]; then
    note "FAIL: no self-heal spawn after wake — the #30 fix is not in effect (this is the pre-fix baseline shape)."
    exit 1
else
    note "NOTE: spawns were born while dark — the window isn't deep enough or the machine's behavior changed; inspect $OUT manually."
    exit 3
fi
