#!/usr/bin/env bash
# Vigil core-loop PoC battery, layered. Real-agent layers (02/03/04-C2/F/G) call the LLM.
#
# This script MACHINE-AGGREGATES pass/fail: each test is gated on its exit code
# (C/F/G/C2) or a required success marker (01/step2/D-A/codex, which don't sys.exit),
# and the script exits non-zero if any check failed. So "all green" is verified, not
# eyeballed. NOTE: the native Swift spike is a SEPARATE `swift run` in ../spike — it is
# NOT part of this battery.
set -u
cd "$(dirname "$0")"
DIR="$PWD"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"
PY="${PY:-python3}"
VENV_PY="$DIR/.venv/bin/python"        # has pyte (for vt100 screen)

PASS=0; FAIL=0; SKIP=0; FAILED=()
hr(){ printf '\n\033[1m======== %s ========\033[0m\n' "$1"; }
pass(){ PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
skip(){ SKIP=$((SKIP+1)); printf '  \033[33m[SKIP]\033[0m %s (%s)\n' "$1" "$2"; }
need_venv(){ [ -x "$VENV_PY" ]; }

# check LABEL -- CMD... : pass iff CMD exits 0 (for tests that sys.exit properly)
check(){ local label="$1"; shift; hr "$label"
  local out; out="$("$@" 2>&1)"; local rc=$?
  printf '%s\n' "$out" | tail -8
  if [ $rc -eq 0 ]; then pass "$label"; else fail "$label (rc=$rc)"; fi; }

# check_marker LABEL MARKER -- CMD... : pass iff CMD output contains MARKER
# (for inherited tests that don't sys.exit on failure)
check_marker(){ local label="$1" marker="$2"; shift 2; hr "$label"
  local out; out="$("$@" 2>&1)"
  printf '%s\n' "$out" | tail -8
  if printf '%s' "$out" | grep -qF "$marker"; then pass "$label"
  else fail "$label (missing marker: $marker)"; fi; }

# ---- 01 mechanism (no sys.exit -> gate on marker) ----
check_marker "01 mechanism approve" "LOOP VERIFIED" env POLICY=auto-allow "$PY" 01_mechanism/step1_demo.py
check_marker "01 mechanism deny"    "LOOP VERIFIED" env POLICY=auto-deny  "$PY" 01_mechanism/step1_demo.py

# ---- 02 step2 real claude (no sys.exit -> marker) ----
rm -rf /tmp/vigil_claude_test
check_marker "02 step2 real claude" "VERIFIED: outer task drove real claude" \
  env CLAUDE_BIN="$CLAUDE_BIN" "$PY" 02_claude/step2_real_claude.py /tmp/vigil_claude_test

# ---- 02 D/A gate + vt100 (no sys.exit -> marker on the deny-blocked assertion) ----
if need_venv; then check_marker "02 D/A gate+vt100" "gate blocked it" \
  env CLAUDE_BIN="$CLAUDE_BIN" "$VENV_PY" 02_claude/test_DA_real_claude.py
else skip "02 D/A gate+vt100" "no .venv/pyte"; fi

# ---- 02 B headless structured hook (inline; explicit file-based pass/fail) ----
hr "02 hook B (headless allow+deny)"
SET_A="{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $DIR/02_claude/hook_decider.py\"}]}]}}"
rm -rf /tmp/vigil_hook; mkdir -p /tmp/vigil_hook
( cd /tmp/vigil_hook && "$CLAUDE_BIN" -p "Run exactly: echo VIGIL_HOOK_OK > hookresult.txt ; then read it and report." \
    --settings "$SET_A" --permission-mode default >/dev/null 2>&1 )
SET_D="{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$PY $DIR/02_claude/hook_decider3.py\"}]}]}}"
rm -rf /tmp/vigil_hook3; mkdir -p /tmp/vigil_hook3
( cd /tmp/vigil_hook3 && "$CLAUDE_BIN" -p "Run exactly: echo NUKE_MARKER > out.txt . Then say if it was blocked." \
    --settings "$SET_D" --permission-mode default >/dev/null 2>&1 )
allow_file="$(cat /tmp/vigil_hook/hookresult.txt 2>/dev/null || echo MISSING)"
echo "  allow -> $allow_file | deny -> out.txt exists? $([ -e /tmp/vigil_hook3/out.txt ] && echo YES-BUG || echo NO-blocked)"
if [ "$allow_file" = "VIGIL_HOOK_OK" ] && [ ! -e /tmp/vigil_hook3/out.txt ]; then pass "02 hook B"
else fail "02 hook B (allow=$allow_file, deny-blocked=$([ ! -e /tmp/vigil_hook3/out.txt ] && echo yes || echo NO))"; fi

# ---- 02 F interactive-TUI hook suppression (sys.exit) ----
if need_venv; then check "02 F interactive hook suppress" \
  env CLAUDE_BIN="$CLAUDE_BIN" "$VENV_PY" 02_claude/test_hook_interactive.py
else skip "02 F" "no .venv/pyte"; fi

# ---- 02 G hook survives multi-minute block (sys.exit) ----
if need_venv; then check "02 G hook blocking 70s" \
  env HOOK_SLEEP=70 HOOK_TIMEOUT=3600 CLAUDE_BIN="$CLAUDE_BIN" "$VENV_PY" 02_claude/test_hook_blocking.py
else skip "02 G" "no .venv/pyte"; fi

# ---- 03 codex PTY intercept (no sys.exit -> marker) ----
if need_venv; then check_marker "03 codex PTY intercept" "CDXPROOF" \
  env CODEX_BIN="$CODEX_BIN" "$VENV_PY" 03_codex/codex_pty_intercept.py
else skip "03 codex" "no .venv/pyte"; fi

# ---- 04 C fake-node tree (sys.exit) ----
check "04 C fake-node tree" "$PY" 04_tree/test_C_routing.py

# ---- 04 C2 real-claude tree (sys.exit) ----
if need_venv; then check "04 C2 real-claude tree" \
  env CLAUDE_BIN="$CLAUDE_BIN" "$VENV_PY" 04_tree/test_C2_real_claude_tree.py
else skip "04 C2" "no .venv/pyte"; fi

# ---- 05 H: real MCP tool call + blocking (sys.exit) ----
if need_venv && "$VENV_PY" -c "import mcp" 2>/dev/null; then
  check "05 H MCP spawn tool-call" env VIGIL_MCP_BLOCK=0 CLAUDE_BIN="$CLAUDE_BIN" "$VENV_PY" 05_mcp/test_H_mcp_spawn.py
else skip "05 H MCP spawn" "no .venv/mcp SDK (pip install mcp)"; fi

# ---- 06 product-stack E2E: real claude through RealCell + hook + MCP (sys.exit) ----
# Reproduces F/G/H + the core loop in the NATIVE product stack (DOCTRINE §10 step3-6).
if command -v swift >/dev/null 2>&1; then
  ( cd "$DIR/../app" && swift build ) >/dev/null 2>&1 \
    && check "06 product-stack core loop (vigil-smoke)" \
         env CLAUDE_BIN="$CLAUDE_BIN" "$DIR/../app/.build/debug/vigil-smoke" \
    || skip "06 vigil-smoke" "swift build failed"
else skip "06 vigil-smoke" "no swift toolchain"; fi

# ---- summary (machine verdict) ----
hr "summary"
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then printf '\033[31mFAILED:\033[0m %s\n' "${FAILED[*]}"; exit 1; fi
if [ "$PASS" -eq 0 ]; then echo "nothing ran"; exit 1; fi
printf '\033[32mALL GREEN\033[0m (%d checks)\n' "$PASS"
