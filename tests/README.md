# Vigil — core-loop PoC tests (layered)

Verifies the original mechanism-validation load-bearing wall (§12): **can a cell take over a real agent's I/O at the
PTY/hook layer, intercept approvals, inject decisions, and collect results**, across harnesses
(Claude Code + Codex), plus the tree orchestration plumbing (gated spawn / LCA routing /
rollup).

Terminology (§0): **node** (a tree vertex) · **cell** (the container wrapping
a single node's terminal) · **gate** (the approval gate) · **rollup** (summary propagated
upward).

## Layer structure

| Layer | Contents | Real LLM | Key finding |
|---|---|---|---|
| `lib/` | cell primitives: `ptyctl.py` (stdlib PTY), `ptyscreen.py` (vt100 screen buffer, needs pyte) | — | shared library |
| `01_mechanism/` | `step1_demo.py` + `fake_agent.py`: deterministic mechanism proof | no | launch→intercept approval→decide→inject→collect result (approve/deny) |
| `02_claude/` | `step2_real_claude.py` (PTY scrape), `test_DA_real_claude.py` (real gate blocking + vt100 hardening), `hook_decider*.py` (headless structured PreToolUse hook, allow/deny) | **yes** | real claude: proof token matches disk byte-for-byte; hook structured interception |
| `02_claude/` | `test_hook_interactive.py` + `hook_probe.py`: **interactive TUI with the hook suppressing the native approval prompt** (F) | **yes** | interactive claude + PreToolUse hook: allow/deny decisions are executed, the native "Do you want to proceed?" prompt is fully suppressed, structured fields are complete, no scrape needed (stable 2/2) → perm is a structured channel |
| `02_claude/` | `test_hook_blocking.py` + `hook_probe_slow.py`: **perm hook withstands real human latency** (G) | **yes** | with a long timeout set, the hook blocks for 70s and the decision is still executed, the prompt is still suppressed; with a short timeout (10s), claude falls back gracefully to the native prompt → structured path as primary + scrape as a graceful-degradation safety net |
| `02_claude/` | `test_permcard_lifecycle.py`: **permission-card lifecycle pinned down** (notify-v2 M4-①, uses the real `vigil-hook` through the envelope layer, run `cd app && swift build` first) | **yes** | prompt appears → `perm-request` envelope arrives in real time; approve → matched to `post-tool` by the (prompt_id+tool_name+tool_input verbatim) tuple; deny → zero hook fires (F2) + F11's anchor goes off-screen = scrape-decidable. `tests/.venv/bin/python tests/02_claude/test_permcard_lifecycle.py`, exit 0 = behavior pinned |
| `03_codex/` | `codex_pty_intercept.py`: real codex's PTY+vt100 approval interception | **yes** | real codex: approval modal intercepted, injected approval, file write |
| `04_tree/` | `test_C_routing.py` + `fake_node.py`: dual-cell routing + rollup (fake node) | no | gated spawn + 2 isolated cells + LCA routing + rollup |
| `04_tree/` | `test_C2_real_claude_tree.py`: **real claude in the tree** (both manager+leaf are real claude) | **yes** | C's plumbing × step2's real agent: a real manager emits a struct spawn → gate → a real leaf clears the permission gate and writes to disk → rollup is captured → LCA-routed back to the manager → rollup-of-rollup passes through the leaf's result (disk reconciliation: sum.txt=55, stable 3/3) |

## Environment
- Python 3 (`01`/`04`'s `test_C_routing` is pure stdlib, zero dependencies; `04`'s `test_C2`
  runs real claude and needs `.venv`/pyte).
- `02`/`03`/`04-C2` run real agents:
  - claude defaults to plain `claude` on PATH (`CLAUDE_BIN` overrides). **Don't use a `claude`
    that's been wrapped by a shell function** — that kind of wrapper often silently adds
    `--dangerously-skip-permissions`, which means the approval prompt never appears.
  - codex defaults to plain `codex` on PATH (`CODEX_BIN` overrides).
  - the vt100 screen buffer needs `pyte`: `python3 -m venv .venv && .venv/bin/pip install
    pyte`, run `02`/`03`/`04-C2` with `.venv/bin/python`.

## Test layering (local vs GitHub CI)

Test-first (TDD): write a failing test → write the code → make it green → commit (pre-commit
gates it, red tests can't land).

The product app's test framework v1 (2026-07-03) has five layers plus one
AI-driven tool:

| Layer | Tool | Tests what | How to run | Runs where |
|---|---|---|---|---|
| **T1a logic unit tests** | XCTest | pure Core/Runtime logic | `cd app && swift test` | pre-commit + CI (via `tests/ci.sh`) |
| **T1b view wiring** | ViewInspector (`app/Tests/VigilAppTests/WiringTests.swift`) | view-appearance conditions, tap → store.send wiring | same as above (same `swift test`) | pre-commit + CI |
| **T1c visual snapshots** | swift-snapshot-testing (`SnapshotTests.swift` + golden PNGs committed to the repo) | bitmap comparison across 7 key states × dark/light theme | same as above; see `app/Tests/VigilAppTests/README.md` for re-recording | runs locally by default (pre-commit); **XCTSkip in CI** — goldens were recorded on this machine (macOS 26.5/retina), the runner's major version/fonts/scale would systematically drift the whole image, beyond what perceptualPrecision can absorb (see that README for details) |
| **T2 UI E2E** | XCUITest (Xcode thin shell `shell/`, fake harness doesn't burn real claude) | 4 golden flows (cold start/seed/submit→tree/notification card) | `cd shell && xcodebuild -project VigilShell.xcodeproj -scheme VigilShell -destination 'platform=macOS' test` (opens a real window) | **manual/nightly**, not in pre-commit/CI |
| **T3 real-agent smoke test** | vigil-smoke (existing) | real claude mechanism closed loop (HeadlessBackend=SwiftTerm, unchanged after D14) | manual | manual Tier 2 |
| **T3′ backend parity** | vigil-parity (added in D14) | SwiftTerm-headless vs ghostty dual-backend renderScreen parity + send("1\r") round trip + terminate/exit-code semantics | `cd app && swift run vigil-parity` (needs a window server + Metal, and **the display must be awake and unlocked** — see below) | **manual Tier 2** (must run after switching terminal engines or upgrading libghostty) |
| **Tier-2 manual: #30 display-off spawn self-heal** | `tools/display_off_spawn_repro.sh` | with the display deeply off, ghostty spawns are rejected (the child process is never born, per issue #30's empirical finding) → once the display wakes, SurfaceSpawnRetry's hook/backoff auto-completes the spawn; `pmset -g log` validates a clean window (HID/Touch ID wake the display almost instantly, so a dirty window is judged INVALID) | `tools/display_off_spawn_repro.sh` (needs a human present: don't touch keyboard/mouse/Touch ID during the ~25s display-off + sampling period) | **manual Tier 2** (run after touching the spawn/self-heal path; machine-dependent behavior, not in CI) |

> ⚠️ **vigil-parity requires the display to be awake and unlocked** (confirmed empirically during
> the 0706 issue-sweep): a sleeping/locked screen → the ghostty spawn window never gets its first
> frame → renderScreen comes back entirely empty → the 20s timeout **always FAILs**
> (`key lines never appeared`), unrelated to the code. `caffeinate -u` does not keep the display
> awake; for unattended dogfood runs use `caffeinate -d`. If you hit this FAIL, check the display
> state first — don't treat it as a regression.
| AI-driven layer | `tools/axdriver` (an AX CLI, zero dependencies) | lets an agent drive the real app by accessibilityIdentifier during development, and take screenshots | `swiftc -O -o axdriver axdriver.swift`, usage in its README | used ad hoc within a dev session |

The element-handle contract (shared by every layer) is `app/ACCESSIBILITY_IDS.md`.

The mechanism-layer PoC (this directory's Python) still follows the original tier split:

| Tier | What runs | Command | Where it runs |
|---|---|---|---|
| **Tier 1 deterministic** | `swift test` (app: T1a+T1b+T1c) + `01` mechanism + `04-C` fake tree (no LLM) | `tests/ci.sh` | **GitHub CI + local pre-commit** |
| build guard | `swift build` (spike, guards against SwiftTerm API drift, doesn't run claude) | `cd spike && swift build` | **CI only** (needs network to pull SwiftTerm) |
| **Tier 2 real agent** | the full step2/D/A/B/F/G/codex/C2/H suite (real claude/codex, disk reconciliation) | `tests/run_all.sh` | **local only / manual** (CI has no claude/codex binaries, no credentials, and it's slow and costs money) |

- **`tests/ci.sh`** is Tier 1's single source of truth: both CI (`.github/workflows/ci.yml`) and
  local pre-commit (`.githooks/pre-commit`) call it, and the machine aggregates a PASS/FAIL.
- **Enabling the local hook (one-time)**: `git config core.hooksPath .githooks` (skip once with
  `git commit --no-verify`).
- **Why real-agent tests don't run in CI**: the GitHub runner has no claude/codex binaries and
  no API credentials, and real LLMs are also slow, costly, and non-deterministic — so Tier 2
  always stays local/manual; run `run_all.sh` by hand before milestones.

## One-shot full run (Tier 2, local)
```sh
./run_all.sh        # full real-agent suite (needs claude+codex+credentials)
tests/ci.sh          # Tier 1 deterministic only (same as CI, seconds)
```

> This is the **Python PoC (proves the mechanism)**. The equivalent verification for the product
> stack (native macOS Swift) lives in the repo's `spike/` (SwiftTerm, re-establishing step2's
> evidence on the product stack; see §13). Full regression as of 2026-06-27: this suite's
> nine items (step1/step2/D/A/B/C/C2/F/G) + real codex all green. `run_all.sh` does
> **machine-aggregated PASS/FAIL** (each test is judged by exit code or a success marker, with a
> final verdict printed and a non-zero exit on any failure) — "all green" is machine-judged, not
> eyeballed. The native spike is a standalone `swift run` (see §13) and is **not** part of
> run_all.

## Key cross-harness findings (recorded in §5.1 / §12.7)
- **PTY+vt100 approval interception is empirically verified on both claude and codex** (the
  universal fallback holds).
- **Codex also has structured hooks** — `PreToolUse`/`PermissionRequest`/`PostToolUse`/
  `SessionStart`/`UserPromptSubmit`/`SubagentStart|Stop`, with input fields
  (`tool_input`/`cwd`/`session_id`/`hook_event_name`/`permission_mode`…) and outputs
  (`permissionDecision`: allow/deny/ask) **appearing under the same field/event names in the
  binary's strings (contract-level evidence, behavior not verified end-to-end)**; handler
  `type=command|prompt`; loaded from `project`/`plugin` sources (the codex trust dialog's exact
  wording: "Trusting the directory allows project-local config, **hooks**, and exec policies to
  load"). There's also an app-server JSON-RPC surface (`item/permissions/requestApproval`,
  `execCommandApproval`, `command/exec` with a PTY, `process/spawn`).
- → **Correction to a prior assumption**: it's not that "Codex has no equivalent hook and falls
  back to scrape." The two harnesses share an almost identical structured-hook contract; the
  structured channel is **more portable** than previously assumed. codex hooks' E2E registration
  is gated by the plugin-trust chain (a config detail); this round establishes the contract via
  binary strings + empirically verifies PTY interception E2E.
