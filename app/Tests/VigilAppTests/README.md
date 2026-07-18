# VigilAppTests

SPM `VigilAppTests` target (the T1b + T1c test layers):

| File | Layer | Owner |
|---|---|---|
| `SmokeTests.swift` | target smoke test (dependency wiring) | Worker A |
| `WiringTests.swift` | T1b view wiring (ViewInspector) | Worker B |
| `SnapshotTests.swift` + `__Snapshots__/` | T1c visual snapshots (swift-snapshot-testing golden PNGs) | Worker C |

This README only covers the T1c snapshot conventions and workflow.

## Snapshot matrix (7 states × dark/light = 14 goldens)

| State | Test | Render size (pt) | Notes |
|---|---|---|---|
| ① no-project empty state | `testEmptyState` | 1124×816 | `NoProjectView` |
| ② launcher start screen | `testLauncher` | 1124×816 | agent/trust/branch pickers; branch is fixed to "main" (the project dir is not a git repo) |
| ③ terminal-state chrome | `testTerminalChrome` | 1124×816 | breadcrumb + empty terminal (silent stub agent); the top-right path is masked (see below) |
| ④ notif card · single | `testNotifCardSingle` | 380×132 | unselected-state card |
| ④ notif card · stack | `testNotifCardStack` | 380×240 | 3 cards; root card is in the selected/tint state |
| ⑤ rail expanded | `testRailExpanded` | 236×816 | project›session›inline tree: running/waiting(+badge/corner mark)/done + a collapsed second project row |
| ⑤ rail collapsed | `testRailCollapsed` | 58×816 | 58pt dot strip + badges |

Goldens live at `__Snapshots__/SnapshotTests/<test>.<dark|light>.png` and are **committed to the
repo**. On this machine (retina) they render as 2x bitmaps: 1124×816 pt → 2248×1632 px.

Size provenance: the UI design canvas is 1360×860, titlebar
44, rail expanded 236 / collapsed 58 → center pane = 1124×816. The notification canvas
replicates the AppBody placement (top 14 / right 16).

## Re-recording the goldens

```bash
cd app
SNAPSHOT_TESTING_RECORD=all swift test --filter VigilAppTests.SnapshotTests   # re-record all
swift test                                                                    # run again to confirm green
```

- A recording run **always reports 14 failures** ("Record mode is on…") — that's how
  swift-snapshot-testing is designed: after recording you must run again for the real assertions.
- To record only the missing ones: just delete the corresponding png and run `swift test`
  (missing goldens auto-record by default).
- You can also use the code-level switch (`withSnapshotTesting(record: .all)`, or the older
  `isRecording` API), but the env var is the most convenient — don't commit a version with the
  code switch left on.
- After re-recording, **eyeball the new PNGs** before committing — a golden change is a UI
  change declaration.

## precision / stability conventions

- `precision: 0.995, perceptualPrecision: 0.98` — the tolerance exists only to absorb tiny
  local rendering jitter (GPU anti-aliasing and the like); it is **not** allowed to lower
  precision to swallow dynamic content — dynamic content must always be pinned or masked.
- On-machine byte-stability has been verified: two independent full recordings produced 14 PNGs
  that are byte-identical (`cmp`).
- Determinism techniques (see the SnapshotTests.swift file header for details):
  - Fake agent = the same `WiringTests.stubScript` shared with WiringTests (a silent sleep stub,
    the `VIGIL_FAKE_AGENT_CMD` seam). **Both test classes must setenv the same path**:
    `UITestSupport.env` is a `static let` that freezes on first access, so whichever runs first
    wins.
  - `NSAppearance` is explicitly pinned per theme (darkAqua/aqua), unaffected by the machine's
    system appearance.
  - Off-screen (no window) rendering: materials have no real blur, no focus ring, but they are
    deterministic.
  - "Finished" nodes: `nodeExited(0)` marks the node done via `SessionStore.selfDeath`
    synchronously; the stub process itself is still running and only gets torn down later
    (at test teardown), but `selfDeath` ignores an exit report for a node that's already
    terminal, so that late report can never flip done back to failed.

## CI: skipped (honest disclosure)

Whenever the `CI` env var is present (GitHub Actions), all tests `XCTSkip`, visibly reported in
the test report. Reason: the goldens were recorded on this machine (macOS 26.5 / retina /
local font stack); the runner is a different macOS major version + has no GUI session — text
anti-aliasing, font metrics, and bitmap scale can all **systematically drift the whole image**,
which is not the kind of thing perceptualPrecision ≈0.98 can reliably absorb (it targets local
jitter), and there's no way to pre-validate against the runner's rendering locally. Per the
PLAN's fallback plan: run locally by default (covered by pre-commit's `swift test`), skip in CI.
To enable in CI: record a golden set on the runner itself (or calibrate precision to the
runner), then remove the `XCTSkipIf` in `prepare()`.

## States not covered, and why

- **Terminal content**: the terminal's real PTY output can't be injected and is non-deterministic
  in timing (the PLAN explicitly allows a placeholder/empty terminal) — what's captured is an
  empty terminal + chrome; terminal behavior belongs to T2 XCUITest / axdriver.
- **breadcrumb's top-right worktree path**: `NSTemporaryDirectory()+pid`, naturally different on
  every run — covered with an opaque mask with explanatory text (the golden shows "‹worktree
  path · dynamic at runtime, masked›"), the correctness of the path text is not asserted at the
  snapshot layer.
- **hover / pressed / mid-animation states** (card hover lift, spinner, tree collapse animation):
  off-screen snapshots have no event loop for interaction; the subagent's spinning dot is a
  purely animated state and isn't in the matrix.
- **ghost (pending-approval) nodes**: after D13, spawn takes effect immediately and
  markOnline fires right away, so tests can't produce a stable `.starting` display state from
  the store entry point (it flips to running instantly).
- **whole-window RootView / titlebar / settings page / toast / TreeChip / SCRATCH bucket**:
  Phase 1's matrix, per the PLAN, covers only five key categories; add more the same way when
  needed.
