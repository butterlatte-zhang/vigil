#!/usr/bin/env bash
# Vigil — DETERMINISTIC test tier (Tier 1). No LLM, no secrets, offline.
#
# Single source of truth for "what's safe to gate on": run by BOTH the local
# pre-commit hook (.githooks/pre-commit) AND GitHub CI (.github/workflows/ci.yml),
# plus humans (`tests/ci.sh`). Machine-aggregates PASS/FAIL → non-zero on any fail.
#
# NOT here (Tier 2, real-agent): tests/run_all.sh drives real claude/codex and
# needs binaries + auth + money + is nondeterministic → LOCAL/MANUAL ONLY, never CI.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PY:-python3}"
PASS=0; FAIL=0; FAILED=()

hr(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok(){ PASS=$((PASS+1)); printf '  \033[32m[PASS]\033[0m %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }

# pass iff command output contains MARKER (for the no-sys.exit python demos)
run_marker(){ local label="$1" marker="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF "$marker"; then ok "$label"
  else no "$label"; printf '%s\n' "$out" | tail -6; fi; }
# pass iff command exits 0
run_rc(){ local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else no "$label (rc=$?)"; fi; }

hr "app — swift test (T1a logic + T1b wiring + T1c snapshots; snapshots XCTSkip when CI env set)"
if command -v swift >/dev/null 2>&1; then
  if ( cd "$ROOT/app" && swift test ); then ok "app swift test"; else no "app swift test"; fi
else
  no "app swift test (swift toolchain not found)"
fi

hr "deterministic python — no LLM (stdlib only)"
run_marker "01 mechanism approve" "LOOP VERIFIED" env POLICY=auto-allow "$PY" "$ROOT/tests/01_mechanism/step1_demo.py"
run_marker "01 mechanism deny"    "LOOP VERIFIED" env POLICY=auto-deny  "$PY" "$ROOT/tests/01_mechanism/step1_demo.py"
run_rc     "04 C fake-node tree"  "$PY" "$ROOT/tests/04_tree/test_C_routing.py"

hr "summary"
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '\033[31mFAILED:\033[0m %s\n' "${FAILED[*]}"; exit 1; fi
printf '\033[32mDETERMINISTIC TIER GREEN\033[0m (%d checks)\n' "$PASS"
