# shell/ — Xcode thin shell + XCUITest golden flows (T2)

The industry-standard "**SwiftPM as the real thing + an Xcode thin shell**" pattern: all of
app's code lives in `app/` (a SwiftPM package, library product `VigilApp`); this directory only
provides a `.app` shell (`VigilShell/main.swift`, two lines: `import VigilApp;
VigilRootApp.main()`) + an XCUITest bundle. **No source is duplicated**; the Xcode project
references `../app` via `XCLocalSwiftPackageReference`.

- The project is a **hand-written** `project.pbxproj` (no xcodegen on this machine). Changing
  targets/file layout means editing the pbxproj directly; if xcodegen is introduced later,
  commit the equivalent `project.yml` and document the regeneration command here.
- Signing: ad-hoc (`CODE_SIGN_IDENTITY=-`), no team/certificate needed, runs locally as-is.
- Day-to-day app runs still go through SwiftPM: `swift run Vigil` (product renamed
  VigilApp → vigil-app → Vigil; the last for a correct bare-binary App menu, audit #3). The
  thin-shell bundle is only used as the UI test host — it
  does **not** include the `vigil-hook`/`vigil-mcp` binaries (those are produced by `swift
  build` and addressed relative to argv[0]), so hook/MCP wiring for a **real claude** launched
  from the shell doesn't work; UI tests run entirely against the fake harness and aren't
  affected.

## How to run

```bash
cd shell
xcodebuild -project VigilShell.xcodeproj -scheme VigilShell -destination 'platform=macOS' test
```

The UI tests really open an app window (this is expected, ~30s). The first run may prompt for
"allow automation/accessibility" permission — allow it once. `swift test` (T1) is unaffected by
this directory.

## Golden flow checklist (VigilShellUITests/GoldenFlowTests.swift)

Element handles are always accessibilityIdentifier; the authoritative list is
`app/ACCESSIBILITY_IDS.md`.

| # | Flow | Assertion |
|---|---|---|
| G1 | Cold start (no project) | `center.empty.addProject` empty state appears; launcher does not appear |
| G2 | env injects a seed project (bypassing NSOpenPanel) | `rail.project.seedproj` row appears; the launcher's five pieces (prompt/agentPicker/permissionPicker/branchLabel/submit) are present |
| G3 | fill the launcher prompt and submit (agent=claude default, fake harness) | main pane switches to terminal state (`center.terminal`+`center.breadcrumb`); the rail tree shows `rail.node.root`, and the child node `rail.node.n1` spawned by the fake agent through the **real MCP gate** appears |
| G4 | fake agent fires the Notification hook | `notif.card.root` notification card appears; clicking it → card disappears (D13: resolved on arrival) + still on that node's terminal |

No human-approval step — DecisionStrip/compose was removed along with D13; approvals happen in
the tool's own native TUI, not in Vigil.

## fake harness (doesn't burn real claude)

The injection chain (all triggered by env vars, see the `UITestSupport` in
`app/Sources/VigilApp/AppModel.swift`, **interface is frozen** — Worker B's T1b tests also reuse
it; coordinate before renaming/changing semantics):

- `VIGIL_UITEST=1` — isolates persistence: doesn't read or write `vigil.projects.v1`
  (UserDefaults).
- `VIGIL_SEED_PROJECT=<dir>` — seeds one project (fixed id `seedproj`, name=directory name),
  bypassing NSOpenPanel.
- `VIGIL_FAKE_AGENT_CMD=<script>` — SessionVM uses `ScriptHarness` (VigilRuntime) in place of
  ClaudeCodeHarness: the cell runs `/bin/bash <script>`, and exports that cell's **real channel
  endpoints** (`VIGIL_NODE` / `VIGIL_TASK` / `VIGIL_HOOK_SOCK` / `VIGIL_MCP_SOCK`).

`Support/fake-agent.sh` (bundled into the UI test bundle's resources, path passed to the app by
the test) uses these endpoints to go through the **same path as production**:
- `VIGIL_FAKE_SPAWN_CHILD=1` → hits the MCP UDS via `nc -U` using the same wire protocol as
  vigil-mcp (handshake `{"node":…}` + JSON-RPC `tools/call spawn`) → the real gate grows child
  node n1;
- `VIGIL_FAKE_NOTIFY_AFTER=N` → after N seconds, hits the hook UDS using the same envelope as
  vigil-hook (`{"node":…,"event":"notification","message":…}`) → a notification card.

Only the injection points have made it into product code (the `UITestSupport` + `ScriptHarness`
branch selection); the product logic's semantics are untouched.
