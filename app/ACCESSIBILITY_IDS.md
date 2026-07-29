# accessibilityIdentifier catalogue (authoritative document)

The "DOM ids" shared by every test layer (T1b ViewInspector / T1c snapshot / T2 XCUITest /
axdriver). The naming contract: dotted namespaces, dynamic
rows get a stable id suffix. **Update this file before changing any id**; new controls should
follow the same namespace style and be added here too. UI-0704 redesign:
the tree moved from the sidebar to the top-right panel
(`rail.node.*` → `tree.node.*`), the launcher dropped the branch+model row, sidebar went
Codex-style (`side.*` additions).

> Historical note: DecisionStrip/compose was removed with D13; `rail.treeChip.*`/
> `rail.addProject`/`launcher.branchLabel`/`rail.node.*` were removed with UI-0704. The 0705
> correction restored the sidebar's add-project entry point (`side.addProject`) + the launcher's
> project dropdown (`launcher.projectPicker`). **#34 C3 ruling #2**: `launcher.modelPicker`/
> `launcher.permissionPicker` removed (permissions default fully open, model/permission profile
> now live in roles.json).

## Container convention (must-read before attaching an id to a SwiftUI container)

Attaching `.accessibilityIdentifier` directly to a SwiftUI **container** (a `Group` / `HStack` /
`VStack` etc. layout node) is **invisible** to XCUITest — the container itself is not an AX
element, so the id can't be queried (T1b ViewInspector can see it, but T2 can't, which is easy
to misdiagnose as "the id wasn't wired up"). You must first turn it into an AX container
element:

```swift
SomeContainer { … }
    .accessibilityElement(children: .contain)   // become an AX element first
    .accessibilityIdentifier("center.xxx")      // now the id is visible to XCUITest
```

Worker D found and fixed this for `center.terminal` / `center.breadcrumb`
(CenterView2.swift) while landing T2. Controls like `Button`/`TextField`/`Menu` are already AX
elements, so attaching an id directly is fine — this step isn't needed for them.

## launcher (center-pane start screen, `CenterView2.swift` LauncherView)

| id | attached to | notes |
|---|---|---|
| `launcher.prompt` | task input **AX container** (since #26, `LauncherPrompt.swift`) | multi-line task input box, an NSTextView representable (incremental layout for large text). id is attached to the container per the convention above; XCUITest click+typeText works as before, axdriver `type` falls back to CGEvent key input (the container has no AXValue) |
| `launcher.projectPicker` | project selection `Menu` (0705) | switches which project the task goes to; last item = add project |
| `launcher.agentPicker` | agent selection `Menu` | entries come from the agents.json registry (settings-v2); connected kinds (claude/codex/opencode, #34) are selectable, custom shows as disabled |
| `launcher.submit` | submit `Button` (↑ round button) | launches the manager, ⌘Enter |
| `launcher.noAgentBanner` | zero-hit warning `Text` (settings-v2) | appears when probing finds no agent CLI at all; submit stays enabled (agents.json lets you fill in a bin by hand) |

## about (Settings launcher's About & Update panel, `CenterView2.swift` AboutUpdatePanel — Sparkle integration)

Settings is "files, not a page" (see the `side` section's history note below) — this panel is
the one deliberate exception: mounted in `AppBody.center` (`Views.swift`) above the Settings
project's `LauncherView` whenever `project.id == app.settingsProject.id`. Everything here is
plain `@Observable` AppModel state (`updateAvailableVersion`, same tier as `toast`), never
Command/Effect — see `VigilRuntime/UpdateController.swift` for the Sparkle wiring and the
dev-immunity guard (`UpdateAvailability`, gates the WHOLE subsystem off under a bare
`swift run Vigil` and under XCTest).

| id | attached to | notes |
|---|---|---|
| `settings.about.panel` | panel container (AX container) | wraps the whole row; always present while Settings is open (unlike the sidebar pill, this has no empty state) |
| `settings.about.version` | version `Text` | "Version \<CFBundleShortVersionString\>", or "Version dev" under a bare `swift run` build (no version key in the linker-embedded partial Info.plist) |
| `settings.about.checkForUpdates` | `Button`, shown when `updateAvailableVersion == nil` | click = `AppModel.checkForUpdates()` — runs Sparkle's standard check/found/install UI |
| `settings.about.updateNow` | `Button`, shown when `updateAvailableVersion != nil` (replaces the above, never both) | same `AppModel.checkForUpdates()` action — Sparkle already knows the version, so this click goes straight into the install flow |

## side / rail (left sidebar, `SidebarView.swift`)

| id | attached to | notes |
|---|---|---|
| `rail.collapseToggle` | sidebar top collapse button (SidebarGlyph) | **the collapsed state reuses the same id as the expand button in the main-pane top bar** (same action, two mutually exclusive states) |
| `side.newChat` | "New chat" row `Button` | current project's launcher; no current project → the 【Chats】 bucket (D-g) |
| `side.search` | "Search" row `Button` | click to expand the search input box |
| `side.searchField` | search `TextField` | Esc / blur on empty collapses it back |
| `side.section.<key>` | section header `Button` (resume-ui W4, D-g) | key ∈ projects/chats/settings/archived (archived added 0713); click collapses/expands the whole section (rotating chevron, state persisted to UserDefaults); forced expanded while searching. 0713: header action buttons now show on hover only (opacity gate; the AX id stays in the tree, un-hovered state is not clickable) |
| `side.addProject` | folder+ button to the right of the "Projects" section header (0705) | adds a project via NSOpenPanel (= menu ⌘O) |
| `side.chats.new` | pencil button on the "Chats" section header (W4) | launcher for the 【Chats】 bucket (sessions with no project, cwd=`<config>/chats`) |
| `side.settings.configure` | pencil button on the "Settings" section header (W4) | = ⌘, reconfigure: blank settings-workspace launcher; submitted tasks are transparently directed to the shared README |
| `rail.project.<projectId>` | project row `Button` | projectId = ProjectVM.id (a UUID string; the built-in buckets use the fixed ids `builtin-chats`/`builtin-settings` and have no project row — the section header is the grouping itself) |
| `rail.project.<projectId>.newSession` | in-row pencil button | visible on hover/selection only; opens that project's launcher |
| `rail.session.<sessionId>` | session row `Button` | sessionId = SessionVM.id (isomorphic across project groups and the chats/settings sections) |
| `rail.session.<sessionId>.status.<state>` | in-row status indicator (Shape/SpinnerRing) | state ∈ attention (yellow dot: waiting/unread) / live (spinner: running/starting only) / done (blue dot: finished and unseen — only lights up on the live→rest transition while unfocused; clears on row click) — the 0708 product ruling (aligned with Codex), replacing #8's persistent rest dot; **an already-read rest state has no indicator at all (blank)**. ⚠️ Attached directly to the Shape, visible to T1b; if T2 XCUITest needs to query it, add `accessibilityElement` per the container convention |
| `side.updateAvailable` | update pill `Button` (Sparkle integration) | pinned rows, directly below Search and above the Projects section header; renders only while `AppModel.updateAvailableVersion` is non-nil (zero footprint otherwise — no reserved row), text "Update · \<version\>"; click = `AppModel.checkForUpdates()`, the same flow as the two Settings buttons below |
| `side.resizeHandle` | 8pt drag strip on the right edge | drag to resize the sidebar width (180–420, persisted) (0706) |
| `side.history.<archiveId>` | dead-session row `Button` (#17 → #24-lite W4 → fix-round 0708 redefined) | archiveId = the stable directory name; **grouped under its owning project** (matched via meta.projectCwd; orphans are not shown); the status slot is left blank (the grey `…status.dead` dot was removed with 0708②'s three-state scheme); **click = open the read-only history view (self-rendered transcript); Enter is only a resume once inside that view** |
| `side.group.<projectId>.showAll` | "Show all (N)" / "Collapse" `Button` at the end of the group (W4, D-f) | appears when a group's merged rows (live+dead) exceed 5; no cap and never shown while searching; the Archived section uses the fixed projectId `builtin-archived` |
| `rail.session.<sessionId>.archive` | hover archive button at the end of a session row (0713) | on hover it replaces the relative-time label (opacity swap, AX id always present); click = silently close the process + persist meta.archived, the row moves into the Archived section |
| `side.history.<archiveId>.archive` | hover archive button at the end of a dead-session row (0713) | same as above, only flips the meta.archived flag (no process to close) |
| `side.history.<archiveId>.unarchive` | hover un-archive button on rows in the Archived section (0713) | clears meta.archived, the row returns to its owning project group (orphans return to being invisible — known boundary) |

> `side.gear` (the account-area gear at the bottom) was removed along with the account area
> (0706 product ruling). After #23 settings-as-files, **the settings page is retired**: ⌘,
> opens the menu to the settings-workspace reconfigure entry (since W4 = the built-in "Settings"
> section, cwd=`~/.config/vigil`, reusing all `launcher.*` ids). Only first-run onboarding
> prefills a task, and that task explicitly directs any agent family to the shared `README.md`;
> later reconfigure visits open blank. ⌘W "Close Session" was removed along with exit
> retirement (#24-lite D-e).

## top / tree (main-pane top bar `Views.swift` · node tree panel `TreePanel.swift`)

| id | attached to | notes |
|---|---|---|
| `top.treeToggle` | top-bar tree toggle `Button` (30×30) | terminal state: per-session `treeCollapsed`; history state (fix-round 0708): same id flips `app.historyTreeCollapsed` (shown only when the archived tree has >1 node) |
| `top.termToggle` | top-bar bottom-terminal toggle `Button` (30×30, terminal SF Symbol) | terminal state only; toggles the active session's `bottomShellVisible` (Codex-style plain-shell panel); ⌘J is the keyboard twin (VigilKeymap.toggleBottomTerminal) |
| `tree.panel` | node tree card container | top-right floating card (AX container) |
| `tree.node.<nodeId>` | tree panel row `Button` | nodeId = NodeID.raw; click = select the node. The row includes a **node id badge** (an `n5`/`root` pill, mono 10.5 / text3, shared via `NodeRow`, used to disambiguate siblings with the same prefix) — the id is both the AX id and the visible row text |
| `tree.finishedToggle` | header row "Hide finished/Show finished N" `Button` (#22) | shown only when there are finished (done/failed/killed) non-root nodes; flips the per-session `hideFinishedNodes` |

## notif (top-right notification stack, `NotifStack.swift` — app-level global, notify-v2 M2)

| id | attached to | notes |
|---|---|---|
| `notif.card.<sessionId>.<nodeId>` | full NotifCard | globally aggregated: sessionId = SessionVM.id. Cards = permission events only (0708: the idle card was removed along with the Notification hook — a duplicate card for the same permission prompt plus a card that's purely "waiting for input" is just noise). Clicking the whole card = switch session + jump to node; the click does **not** clear it (waits for the actual resolution, per the notify-v2 card master table). Edge case: multiple permission requests on the same node/turn produce multiple cards with the same id (FIFO resolution, rare) |

> History: before M2 this was `notif.card.<nodeId>` (bound to a single session).

## center (main-pane terminal state / empty state, `CenterView2.swift` TerminalPane · `Views.swift`)

| id | attached to | notes |
|---|---|---|
| `center.breadcrumb` | TerminalPane top header row | role icon · title (root=main task) · model · status · worktree |
| `center.terminal` | terminal host `Group` (TerminalHost/SpinnerRing/DeadNodePane) | rebuilt on every session/node switch (`.id`) |
| `center.deadnode` | DeadNodePane as a whole (AX container, #22 → fix-round 0708 self-render rework) | replaces the terminal host when a terminal-state node (killed/done/failed) is selected: self-renders the transcript body (falls back to a frozen frame if the pointer is stale) + a bottom Enter row |
| `deadnode.resumeHint` | DeadNodePane's bottom "Press Enter to resume" row (AX container) | has resume credentials = shows the Enter hint (pressing Return does `--resume` to revive in place, whoever you click revives); no credentials = shows a "read-only" note. The old `deadnode.resume`/`deadnode.transcript` buttons were removed (0708 product ruling) |
| `transcript.read` | self-rendered transcript body (AX container, `TranscriptRender.swift`) | shared by HistoryPane and DeadNodePane: ❯ user / ● assistant / ⚒ collapsed tool rows / truncation markers; anchored at the tail |
| `transcript.stats` | the /status·/usage-equivalent info card at the end of the conversation (AX container, 0708-4) | version/session name/sid/model/wall-clock duration/usage by model (deduped by requestId), all sourced from the transcript itself; $ cost and lines-of-code aren't available in 2.1.x, so they're honestly omitted |
| `center.empty.addProject` | NoProjectView "Add project…" `Button` | shown in the no-project empty state |
| `bottom.terminal` | Codex-style bottom terminal panel as a whole (AX container, `BottomTerminalPanel`, CenterView2.swift) | present only while the active session's `bottomShellVisible` is true; hosts a plain `$SHELL` (SessionVM.bottomShell), agent machinery stripped; hiding keeps the process alive, × ends it |
| `bottom.terminal.close` | panel header × `Button` | `session.closeBottomShell()` — ends the shell process AND closes the panel (next open = fresh shell) |
| `bottom.terminal.resizeHandle` | 6pt drag strip along the panel's top edge | drag to resize the panel height (AppModel.bottomShellHeight, 120–640, persisted) |

## history (main-pane read-only history view, `HistoryPane.swift` — #17 → fix-round 0708 self-render rework)

| id | attached to | notes |
|---|---|---|
| `history.pane` | HistoryPane as a whole (AX container) | read-only view for a dead session: main pane = the selected node's self-rendered transcript (`transcript.read`); the tree skeleton moved to the top-right floating card |
| `history.resumeHint` | HistoryPane's bottom "Press Enter to resume" row (AX container) | root selected = resumes the session; dead worker selected = resumes the session and revives that node; meta with no rootSessionId = read-only note (Enter is a no-op) |
| `history.tree.panel` | HistoryTreePanel card container (top-right floating card, mounted via OverlayColumn) | auto-expands (`app.historyTreeCollapsed`) when opening a history with an archived tree of >1 node; the duration column is frozen (pinned at lastEventAt) |
| `history.node.<nodeId>` | history tree panel node row `Button` | nodeId = NodeID.raw; **click = select that node** (the main pane switches to render its transcript); row = dot + **node id badge** + title + frozen duration (same badge as the live tree, shared via `NodeRow`), isomorphic to a finished node in the live tree (the transcript-pointer status-label column was removed with 0708②; the three-state honesty note is now only said once, in the main pane) |
