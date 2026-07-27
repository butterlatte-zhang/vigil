import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore

// T1b view-wiring tests. Two families:
//   1) appearance-under-state — given real store/model state, assert a view (by its
//      accessibility id, app/ACCESSIBILITY_IDS.md) is present/absent;
//   2) action wiring — drive the control and assert the right mutation reached the
//      real AppModel / SessionStore (no UI-layer mocks).
//
// Sessions are REAL SessionVM → Orchestrator → RealCell stacks; the only substitution
// is the agent binary: cells run ScriptHarness's fake agent (VIGIL_FAKE_AGENT_CMD, the
// T2 seam) — a sleeping stub — so tests are deterministic, agent-free, network-free and
// fast. `assertFakeSeamActive()` fails LOUDLY before any launch if the seam did not
// take, so a misconfigured run can never silently start a real claude.
//
// Honest skips — interactions ViewInspector cannot drive (not asserted, not faked):
//   • Menu item taps (launcher.agentPicker): tapping a menu entry mutates @State, which
//     does not persist on an un-hosted view. The same submit wiring is covered by
//     injecting the launcher's initial agent (LauncherView's test-seam init) and tapping
//     launcher.submit. (The model/access pickers do not exist in this launcher.)
//   • Keystrokes inside the ghostty terminal (center.terminal hosts an
//     NSViewRepresentable): its internals are invisible to ViewInspector — T2
//     XCUITest / axdriver territory.
//   • launcher.prompt ⌘Enter shortcut: keyboardShortcut needs a real event loop — T2.

@MainActor
final class WiringTests: XCTestCase {

    /// One sleeping stub script per process — what ScriptHarness launches instead of
    /// claude. 30s is an upper bound; every test tears its sessions down in ms.
    static let stubScript: String = {
        let dir = NSTemporaryDirectory() + "vigil-t1b-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/fake-agent.sh"
        try? "exec /bin/sleep 30\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }()

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)                          // never touch real defaults
        setenv("VIGIL_FAKE_AGENT_CMD", Self.stubScript, 1)      // cells run the stub
        AgentNotice.permissionGrace = 2.5                       // reset after seedPermissionCard zeroes it out
    }

    private var apps: [AppModel] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    /// UITestSupport.env is a frozen `static let`: if anything read it before our
    /// setenv, launching would start a REAL claude. Refuse loudly instead.
    private func assertFakeSeamActive() throws {
        guard UITestSupport.fakeAgentCommand == Self.stubScript else {
            XCTFail("fake-agent seam inactive (UITestSupport froze before setUp) — " +
                    "refusing to launch a real agent")
            throw InspectionError.notSupported("fake-agent seam inactive")
        }
    }

    private func makeApp() -> AppModel {
        let app = AppModel()
        apps.append(app)
        return app
    }

    @discardableResult
    private func addProject(_ app: AppModel, name: String = "Demo Project") -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-t1b-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    @discardableResult
    private func launch(_ app: AppModel, _ p: ProjectVM, task: String = "Test Task",
                        access: PermissionMode = .standard) throws -> SessionVM {
        try assertFakeSeamActive()
        return try XCTUnwrap(
            app.launchSession(in: p.id, task: task, agent: "claude", access: access),
            "launchSession refused a claude launch")
    }

    /// Spawn a child node through the store's single ingress (the same Command the MCP
    /// channel emits) and return its id.
    @discardableResult
    private func spawnChild(_ vm: SessionVM, task: String = "Subtask") throws -> NodeID {
        let root = vm.store.tree.rootID
        let before = Set(vm.store.tree.root.children)
        vm.store.send(.requestStruct(.spawn(parent: root, role: .leaf, task: task),
                                     from: root, replyID: UUID()))
        let new = vm.store.tree.root.children.filter { !before.contains($0) }
        return try XCTUnwrap(new.first, "spawn produced no child node")
    }

    // MARK: - root node identity (tree must not claim "claude" for codex/opencode)

    /// The node tree's root label is the session's agent registry key — a codex or
    /// opencode session must not show a hardcoded "claude" root. The title also rides
    /// the root cell_launch event, so history rebuilds show the same label.
    func testRootNodeTitle_reflectsAgentKey() {
        for key in ["claude", "codex", "opencode", "my-relay"] {
            let vm = SessionVM(id: "w-root-\(key)", name: "t", rootCwd: NSTemporaryDirectory(),
                               initialTask: "task", agentKey: key)
            defer { vm.shutdown() }
            XCTAssertEqual(vm.store.tree[vm.store.tree.rootID]?.title, key,
                           "root node label must be the session's agent key")
        }
    }

    // MARK: - assertion helpers

    private func assertPresent(_ view: some View, _ id: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: id),
                         "expected view with id \(id)", file: file, line: line)
    }

    private func assertAbsent(_ view: some View, _ id: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try view.inspect().find(viewWithAccessibilityIdentifier: id),
                             "expected NO view with id \(id)", file: file, line: line)
    }

    private func tapButton(_ view: some View, _ id: String) throws {
        try view.inspect()
            .find(ViewType.Button.self, where: { (try? $0.accessibilityIdentifier()) == id })
            .tap()
    }

    // MARK: - 1) appearance under state

    /// No projects → the add-project empty state, and nothing else, in the center.
    func testNoProject_showsEmptyStateOnly() throws {
        let app = makeApp()
        let body = AppBody(app: app)
        assertPresent(body, "center.empty.addProject")
        assertAbsent(body, "launcher.prompt")
        assertAbsent(body, "center.breadcrumb")
    }

    /// Project selected but no live session → the launcher card, slimmed
    /// to project · agent · prompt · submit — the model + access pickers are gone (defaults
    /// wide-open, model tier = roles.json per-role). No terminal, no empty state.
    func testProjectWithoutSession_showsLauncher() throws {
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        let body = AppBody(app: app)
        for id in ["launcher.prompt", "launcher.projectPicker", "launcher.agentPicker",
                   "launcher.submit"] {
            assertPresent(body, id)
        }
        // The model/access pickers must be GONE (honesty red line + no dead chrome).
        assertAbsent(body, "launcher.modelPicker")
        assertAbsent(body, "launcher.permissionPicker")
        assertPresent(body, "side.addProject")                   // project section header folder+
        assertAbsent(body, "center.terminal")
        assertAbsent(body, "center.empty.addProject")
    }

    /// Live session focused → terminal mode: breadcrumb + terminal host; the launcher
    /// is gone.
    func testActiveSession_showsTerminalPane_notLauncher() throws {
        let app = makeApp()
        let p = addProject(app)
        _ = try launch(app, p)
        let body = AppBody(app: app)
        assertPresent(body, "center.breadcrumb")
        assertPresent(body, "center.terminal")
        assertAbsent(body, "launcher.prompt")
        assertAbsent(body, "center.empty.addProject")
    }

    /// A killed worker stays selectable — the center flips from the live terminal
    /// host to the read-only dead-node pane (transcript pointer + frozen last frame).
    func testKilledNode_centerShowsDeadPane() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let child = try spawnChild(vm)
        vm.store.send(.requestStruct(.kill(child), from: vm.store.tree.rootID,
                                     replyID: UUID()))
        XCTAssertEqual(vm.store.tree[child]?.status, .killed, "killed node must stay in the tree")
        vm.select(child)

        let body = AppBody(app: app)
        assertPresent(body, "center.deadnode")
        // Live root selected → back to the terminal host.
        vm.select(vm.store.tree.rootID)
        assertAbsent(AppBody(app: app), "center.deadnode")
    }

    /// The tree panel's "hide finished" toggle flips the session's filter key.
    func testTreePanel_finishedToggleFlipsSessionKey() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let child = try spawnChild(vm)
        vm.store.send(.nodeExited(child, code: 0))          // one finished node → toggle shows

        let panel = TreePanel(session: vm)
        XCTAssertFalse(vm.hideFinishedNodes)
        try tapButton(panel, "tree.finishedToggle")
        XCTAssertTrue(vm.hideFinishedNodes)
    }

    /// Node-id badge: every tree row shows its node id (root / n1 …) as visible text so
    /// siblings sharing a task-text prefix stay distinguishable — dead and live alike.
    func testTreePanel_rowShowsNodeIdBadge() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let live = try spawnChild(vm, task: "Same Prefix Task")
        let dead = try spawnChild(vm, task: "Same Prefix Task")
        vm.store.send(.nodeExited(dead, code: 0))           // dead node must still show id

        let panel = TreePanel(session: vm)
        // Root's id and both children's ids are rendered as row text (badge).
        XCTAssertNoThrow(try panel.inspect().find(text: "root"),
                         "root row must show its node id")
        XCTAssertNoThrow(try panel.inspect().find(text: live.raw),
                         "live node row must show its id badge (\(live.raw))")
        XCTAssertNoThrow(try panel.inspect().find(text: dead.raw),
                         "dead node row must still show its id badge (\(dead.raw))")
    }

    /// Breadcrumb path honesty: every node — root and workers alike — runs in the
    /// project directory (no forced isolation); cwd() must never fabricate a path.
    func testCwd_everyNodeShowsTheProjectDir() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        XCTAssertEqual(vm.cwd(vm.store.tree.rootID), p.cwd)
        let child = try spawnChild(vm)
        XCTAssertEqual(vm.cwd(child), p.cwd)
    }

    /// When a test needs an "immediately visible" card, seed a permission card and zero
    /// out the grace-window delay (AgentNotice.permissionGrace test seam, reset to its
    /// default in setUp); the card is removed only on real resolution, never before
    /// (.waiting until then).
    private func seedPermissionCard(_ vm: SessionVM, node: NodeID,
                                    input: String = "{\"command\":\"git push\"}",
                                    text: String = "Awaiting authorization · Bash(git push)") {
        AgentNotice.permissionGrace = 0
        vm.store.send(.permRequested(from: node, info: PermNoticeInfo(
            promptID: "p1", toolName: "Bash", toolInput: input,
            inputSummary: "git push", text: text)))
    }

    /// An unresolved AgentNotice shows its card (global stack, id = session+node);
    /// resolution (here: the user re-engaging that terminal, clearNotices) removes it.
    func testAgentNotice_cardAppears_thenClearsWhenResolved() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let n1 = try spawnChild(vm)
        let stack = NotifStack(app: app)

        assertAbsent(stack, "notif.card.\(vm.id).\(n1.raw)")     // notice-zero → clean
        seedPermissionCard(vm, node: n1)
        assertPresent(stack, "notif.card.\(vm.id).\(n1.raw)")
        vm.store.send(.clearNotices(n1))
        assertAbsent(stack, "notif.card.\(vm.id).\(n1.raw)")
    }

    /// Global cards: notices from EVERY session aggregate into one stack, each card
    /// carrying its project·session identity line; tapping a non-active session's card
    /// switches the app to that session AND jumps to the node (the card itself stays —
    /// cards die only on real resolution, never on click).
    func testNotifCards_aggregateAcrossSessions_tapSwitches() throws {
        let app = makeApp()
        let p1 = addProject(app, name: "Project One")
        let p2 = addProject(app, name: "Project Two")
        let vmA = try launch(app, p1, task: "Task A")
        let n1 = try spawnChild(vmA)
        let vmB = try launch(app, p2, task: "Task B")
        let nB = try spawnChild(vmB)
        XCTAssertEqual(app.activeSessionID, vmB.id)              // B is focused, A is not

        seedPermissionCard(vmA, node: n1)
        seedPermissionCard(vmB, node: nB)

        let stack = NotifStack(app: app)
        assertPresent(stack, "notif.card.\(vmA.id).\(n1.raw)")   // non-active session's card
        assertPresent(stack, "notif.card.\(vmB.id).\(nB.raw)")
        XCTAssertNoThrow(try stack.inspect().find(text: "Project One · Task A"))  // identity line

        try stack.inspect()
            .find(viewWithAccessibilityIdentifier: "notif.card.\(vmA.id).\(n1.raw)")
            .find(ViewType.HStack.self)
            .callOnTapGesture()

        XCTAssertEqual(app.activeSessionID, vmA.id)              // switched session
        XCTAssertEqual(app.currentProjectID, p1.id)
        XCTAssertEqual(vmA.selectedID, n1)                       // jumped to the node
        XCTAssertEqual(vmA.store.notices.count, 1)               // card survives the click
        XCTAssertEqual(vmB.store.notices.count, 1)               // other session untouched
    }

    /// The card stack is an APP-level overlay: cards stay visible in the launcher
    /// state too — not only over an active terminal.
    func testGlobalCards_visibleWithoutActiveSession() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let n1 = try spawnChild(vm)
        seedPermissionCard(vm, node: n1)
        let body = AppBody(app: app)
        let id = "notif.card.\(vm.id).\(n1.raw)"

        assertPresent(body, id)                                  // terminal state
        app.openLauncher(in: p.id)                               // launcher state
        assertPresent(body, id)
    }

    /// Card-stack click semantics: a fresh permission card is grace-hidden (~2.5s, so a
    /// sub-second approval never flashes a card) and SURVIVES clicks — only the actual
    /// resolution kills it.
    func testPermissionCard_graceHides_clickDoesNotClear() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let n1 = try spawnChild(vm)
        vm.store.send(.permRequested(from: n1, info: PermNoticeInfo(
            promptID: "pr1", toolName: "Bash", toolInput: "{\"command\":\"git push\"}",
            inputSummary: "git push", text: "Awaiting authorization · Bash(git push)")))

        let stack = NotifStack(app: app)
        assertAbsent(stack, "notif.card.\(vm.id).\(n1.raw)")     // inside the grace window

        app.openNotice(sessionID: vm.id, node: n1)               // click = navigate only
        XCTAssertEqual(app.activeSessionID, vm.id)
        XCTAssertEqual(vm.selectedID, n1)                        // jumped…
        XCTAssertEqual(vm.store.notices.count, 1)                // …but nothing cleared
        XCTAssertEqual(vm.store.tree[n1]?.status, .waiting)      // still waiting on the box
    }

    /// Layout by state: sidebar carries project + session rows (no node tree);
    /// the node tree lives in the top-right TreePanel, gated by `treeCollapsed` and by
    /// having a focused session; collapsing the sidebar removes it entirely (the expand
    /// toggle re-appears in the top bar under the SAME id).
    func testSidebarAndTreePanel_renderByState() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)                              // focused session
        let body = AppBody(app: app)

        assertPresent(body, "rail.project.\(p.id)")
        assertPresent(body, "rail.session.\(vm.id)")
        assertPresent(body, "top.treeToggle")
        assertAbsent(body, "tree.node.root")     // fresh manager starts panel-hidden

        // First worker → auto key expands the panel (async observation hop → pump).
        let n1 = try spawnChild(vm)
        pumpUntil("auto-expand after first worker") { !vm.treeCollapsed }
        assertPresent(body, "tree.node.root")
        assertPresent(body, "tree.node.\(n1.raw)")

        // User key: manual toggle wins from now on — auto must never re-open.
        vm.userToggleTree()                                      // user collapses
        assertAbsent(body, "tree.node.root")
        assertPresent(body, "top.treeToggle")                    // toggle itself remains
        _ = try spawnChild(vm)                                   // more workers arrive…
        pump(0.1)
        XCTAssertTrue(vm.treeCollapsed, "auto expand must yield to the user's key")

        app.openLauncher(in: p.id)                               // defocus the session
        assertPresent(body, "rail.session.\(vm.id)")
        assertAbsent(body, "top.treeToggle")                     // terminal-state only
        assertAbsent(body, "tree.node.root")

        app.railCollapsed = true                                 // sidebar fully hidden
        assertAbsent(body, "rail.project.\(p.id)")
        assertAbsent(body, "rail.session.\(vm.id)")
        assertPresent(body, "rail.collapseToggle")               // expand button, top bar
    }

    /// The complementary case of the two keys: the user manually toggled the switch
    /// before the first worker arrived → auto yields permanently (a worker arriving later
    /// must never flip a panel the user collapsed back open).
    func testTreePanel_userKeyBeforeFirstWorker_autoYields() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        XCTAssertTrue(vm.treeCollapsed)                          // fresh manager: hidden

        vm.userToggleTree()                                      // user opens it early
        XCTAssertFalse(vm.treeCollapsed)
        vm.userToggleTree()                                      // …and closes it again
        XCTAssertTrue(vm.treeCollapsed)

        _ = try spawnChild(vm)                                   // first worker arrives
        pump(0.15)
        XCTAssertTrue(vm.treeCollapsed, "auto expand must stay yielded after user toggles")
    }

    /// In the terminal state, tapping the top-bar tree toggle goes through userToggleTree
    /// (flips session.treeCollapsed and settles the user-sovereignty key — auto yields from
    /// then on); tapping twice flips it back.
    func testTreeToggleButton_tapDrivesSessionTree() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let body = AppBody(app: app)

        XCTAssertTrue(vm.treeCollapsed)                          // fresh manager: hidden
        try tapButton(body, "top.treeToggle")
        XCTAssertFalse(vm.treeCollapsed)                         // tap = open
        try tapButton(body, "top.treeToggle")
        XCTAssertTrue(vm.treeCollapsed)                          // tap again = close

        _ = try spawnChild(vm)                                   // first worker arrives…
        pump(0.15)
        XCTAssertTrue(vm.treeCollapsed, "tap must count as the USER key — auto yields")
    }

    // MARK: - run-loop pumping (async observation hops)

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func pumpUntil(_ what: String, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ cond: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !cond() && Date() < deadline { pump(0.02) }
        XCTAssertTrue(cond(), "pumpUntil timeout: \(what)", file: file, line: line)
    }

    // MARK: - 2) action wiring

    /// launcher.submit → launchSession: the prompt becomes the session (name = 13-char
    /// prefix), the agent selection lands, focus moves. access = defaults wide-open
    /// (no picker), model = nil (no seed; tier = roles.json per-role).
    func testLauncherSubmit_launchesSessionWithSelections() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        let task = "write rail wiring tests covering the three-tier structure"
        let launcher = LauncherView(app: app, project: p, initialTask: task)

        try tapButton(launcher, "launcher.submit")

        XCTAssertEqual(p.sessions.count, 1)
        let vm = try XCTUnwrap(p.sessions.first)
        XCTAssertEqual(vm.name, String(task.prefix(13)) + "…")   // prompt travelled
        XCTAssertEqual(vm.agentKey, "claude")                        // agent selection
        XCTAssertEqual(vm.access, .bypass)                       // defaults wide-open
        XCTAssertNil(vm.model)                                    // no model seed
        XCTAssertEqual(app.activeSessionID, vm.id)               // focus moved
        XCTAssertEqual(app.currentProjectID, p.id)
        XCTAssertEqual(vm.store.tree.root.status, .running)      // orchestrator is up
    }

    /// Model default is honesty-first: nothing selected → nil → NO --model flag.
    func testLauncherSubmit_defaultModelIsNil() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        let launcher = LauncherView(app: app, project: p, initialTask: "Task")

        try tapButton(launcher, "launcher.submit")

        XCTAssertNil(try XCTUnwrap(p.sessions.first).model)
    }

    /// Honesty red line: submit with an agent that isn't a usable registry entry must
    /// launch NOTHING (never silently run one CLI behind another's label). All real kinds
    /// (claude/codex/opencode) are wired, so a bare unknown/custom key stands in.
    func testLauncherSubmit_refusesUnwiredAgent() throws {
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        let launcher = LauncherView(app: app, project: p,
                                    initialTask: "Task", initialAgent: "my-custom-tool")

        try tapButton(launcher, "launcher.submit")

        XCTAssertTrue(p.sessions.isEmpty)
        XCTAssertNil(app.activeSessionID)
    }

    // MARK: - launcher draft cache (unsent input survives a switch-away-and-back)

    /// Typing into the launcher, switching to a different center-pane state (which tears
    /// LauncherView's @State down — AppBody.center is an if/else-if over mutually
    /// exclusive view types), then switching back must restore the unsent text.
    func testLauncherDraft_survivesSwitchAwayAndBack() throws {
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        let launcher = LauncherView(app: app, project: p)
        var field = try launcher.inspect().find(LauncherPromptField.self).actualView()
        field.model.text = "an unsent task brief"

        try launcher.inspect().find(ViewType.VStack.self).callOnDisappear()   // simulates the center pane swapping away
        XCTAssertEqual(app.launcherDraft(for: p.id)?.text, "an unsent task brief",
                       "leaving the launcher must stash the unsubmitted text")

        let reopened = LauncherView(app: app, project: p)
        field = try reopened.inspect().find(LauncherPromptField.self).actualView()
        XCTAssertEqual(field.model.text, "an unsent task brief",
                       "reopening the same project's launcher must restore the draft")
    }

    /// A blank launcher left and revisited must not manufacture a stale draft out of
    /// nothing.
    func testLauncherDraft_emptyTextLeavesNoDraft() throws {
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        let launcher = LauncherView(app: app, project: p)

        try launcher.inspect().find(ViewType.VStack.self).callOnDisappear()

        XCTAssertNil(app.launcherDraft(for: p.id))
    }

    /// A previously-cached draft must not resurrect after it is cleared out from under it
    /// (e.g. by a later empty visit) — the empty visit evicts the stale entry.
    func testLauncherDraft_clearedByASubsequentEmptyVisit() throws {
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        app.saveLauncherDraft(projectID: p.id, text: "old draft", attachments: [])
        XCTAssertNotNil(app.launcherDraft(for: p.id))

        let launcher = LauncherView(app: app, project: p, initialTask: "placeholder-avoids-restoring-old-draft")
        // Overwrite the restored @State back to empty before leaving, as if the user
        // deleted everything they'd typed.
        let field = try launcher.inspect().find(LauncherPromptField.self).actualView()
        field.model.text = ""
        try launcher.inspect().find(ViewType.VStack.self).callOnDisappear()

        XCTAssertNil(app.launcherDraft(for: p.id), "an emptied launcher must evict the stale cached draft")
    }

    /// Dispatching the task must not leave a ghost draft behind for the next visit —
    /// submit clears the cache, and the onDisappear that follows (center pane swapping to
    /// the new session) must not resave the just-cleared (now empty) text as a new draft.
    func testLauncherDraft_clearedBySubmit() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        app.openLauncher(in: p.id)
        app.saveLauncherDraft(projectID: p.id, text: "stale leftover", attachments: [])
        let launcher = LauncherView(app: app, project: p, initialTask: "go build the thing")

        try tapButton(launcher, "launcher.submit")
        try launcher.inspect().find(ViewType.VStack.self).callOnDisappear()   // the session becoming active tears this view down

        XCTAssertNil(app.launcherDraft(for: p.id), "a dispatched task must not linger as a draft")
    }

    /// Row taps: sidebar session row → focus that session; tree-panel node row → select
    /// that node in its session; sidebar project row (non-current) → switch project
    /// (no session ⇒ launcher state).
    func testRowTaps_selectSessionNodeProject() throws {
        let app = makeApp()
        let p1 = addProject(app, name: "Project One")
        let p2 = addProject(app, name: "Project Two")
        let vmA = try launch(app, p1, task: "Task A")
        let vmB = try launch(app, p1, task: "Task B")             // now focused
        XCTAssertEqual(app.activeSessionID, vmB.id)
        let sidebar = SidebarView(app: app)

        try tapButton(sidebar, "rail.session.\(vmA.id)")
        XCTAssertEqual(app.activeSessionID, vmA.id)              // focus Command landed

        let n1 = try spawnChild(vmA)
        XCTAssertEqual(vmA.selectedID, vmA.store.tree.rootID)
        let panel = TreePanel(session: vmA)
        try tapButton(panel, "tree.node.\(n1.raw)")
        XCTAssertEqual(vmA.selectedID, n1)                       // node selection landed

        try tapButton(sidebar, "rail.project.\(p2.id)")
        XCTAssertEqual(app.currentProjectID, p2.id)              // project switch landed
        XCTAssertNil(app.activeSessionID)                        // empty project → launcher
    }

    /// The status indicator only has three visible states — spinner (running/starting) /
    /// yellow dot (waiting on human) / blue dot (done and you haven't seen it yet). A focused
    /// session finishing = already read, shows nothing.
    func testSessionRowIndicator_followsNodeLifecycle() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)                       // launch → focused
        let root = vm.store.tree.rootID
        let sidebar = SidebarView(app: app)

        // fresh session: root .running → spinner
        assertPresent(sidebar, "rail.session.\(vm.id).status.live")

        // turn closed WHILE FOCUSED → idle: spinner stops, and "done" is already read → nothing shows
        vm.store.send(.turnEnded(root, gen: nil))
        pump(0.05)
        XCTAssertEqual(vm.store.tree.root.status, .idle)
        XCTAssertFalse(vm.completedUnseen, "focused completion = already seen, blue dot stays off")
        assertAbsent(sidebar, "rail.session.\(vm.id).status.done")
        assertAbsent(sidebar, "rail.session.\(vm.id).status.live")

        // agent waits for the human (permission box up) → static attention dot
        vm.store.send(.permRequested(from: root, info: PermNoticeInfo(
            promptID: "p1", toolName: "Bash", toolInput: "{}",
            inputSummary: nil, text: "Awaiting authorization · Bash")))
        pump(0.05)
        XCTAssertEqual(vm.store.tree.root.status, .waiting)
        assertPresent(sidebar, "rail.session.\(vm.id).status.attention")
        assertAbsent(sidebar, "rail.session.\(vm.id).status.live")

        // process exit → terminal, still focused → nothing shows (every other state is blank)
        vm.store.send(.nodeExited(root, code: 0))
        pump(0.05)
        XCTAssertEqual(vm.store.tree.root.status, .done)
        assertAbsent(sidebar, "rail.session.\(vm.id).status.done")
        assertAbsent(sidebar, "rail.session.\(vm.id).status.live")
        assertAbsent(sidebar, "rail.session.\(vm.id).status.attention")
    }

    /// The main blue-dot path: an unfocused session finishes → the blue dot lights up; clicking its row → the blue dot disappears.
    func testSessionRowDoneDot_appearsUnfocusedClearsOnClick() throws {
        let app = makeApp()
        let p = addProject(app)
        let vmA = try launch(app, p, task: "Task A")
        let vmB = try launch(app, p, task: "Task B")       // B focused, A in the background
        XCTAssertEqual(app.activeSessionID, vmB.id)
        let sidebar = SidebarView(app: app)

        vmA.store.send(.turnEnded(vmA.store.tree.rootID, gen: nil))
        pump(0.05)
        XCTAssertTrue(vmA.completedUnseen, "background completion → unseen marker")
        assertPresent(sidebar, "rail.session.\(vmA.id).status.done")

        try tapButton(sidebar, "rail.session.\(vmA.id)")  // click it once
        XCTAssertFalse(vmA.completedUnseen)
        assertAbsent(sidebar, "rail.session.\(vmA.id).status.done")

        // spin up again (a new turn starts) → the blue dot yields to the spinner; falling back to rest (still looking elsewhere) → lights up again
        app.select(session: vmB.id)
        vmA.store.send(.turnStarted(vmA.store.tree.rootID))
        pump(0.05)
        assertPresent(sidebar, "rail.session.\(vmA.id).status.live")
        vmA.store.send(.turnEnded(vmA.store.tree.rootID, gen: nil))
        pump(0.05)
        XCTAssertTrue(vmA.completedUnseen)
        assertPresent(sidebar, "rail.session.\(vmA.id).status.done")
    }

    /// closeSession's neighbor-focus is the only path outside select() that
    /// directly assigns focus — whoever the focus lands on, their blue dot must go out
    /// too (focusing after the fact still counts as "seeing" it).
    func testCloseSessionNeighbourFocusClearsItsDoneDot() throws {
        let app = makeApp()
        let p = addProject(app)
        let vmA = try launch(app, p, task: "Task A")
        let vmB = try launch(app, p, task: "Task B")       // B focused, A in the background
        vmA.store.send(.turnEnded(vmA.store.tree.rootID, gen: nil))
        pump(0.05)
        XCTAssertTrue(vmA.completedUnseen, "background completion → blue dot lit")

        app.closeSession(vmB.id)                          // harvester path: focus lands directly on A
        XCTAssertEqual(app.activeSessionID, vmA.id)
        XCTAssertFalse(vmA.completedUnseen, "the row being viewed must not keep a blue dot")
    }

    /// Notification card tap = jump to the node (observe, never take over). The card
    /// itself stays — it dies only when the approval actually resolves, and resolution
    /// settles the node out of .waiting.
    func testNotifCardTap_jumpsToNode_cardStaysUntilResolved() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let n1 = try spawnChild(vm)
        seedPermissionCard(vm, node: n1)
        XCTAssertEqual(vm.store.tree[n1]?.status, .waiting)
        XCTAssertEqual(vm.selectedID, vm.store.tree.rootID)

        let stack = NotifStack(app: app)
        try stack.inspect()
            .find(viewWithAccessibilityIdentifier: "notif.card.\(vm.id).\(n1.raw)")
            .find(ViewType.HStack.self)
            .callOnTapGesture()

        XCTAssertEqual(vm.selectedID, n1)                        // jumped to the node
        XCTAssertEqual(vm.store.notices.count, 1)                // card survives the click
        XCTAssertEqual(vm.store.tree[n1]?.status, .waiting)      // still blocked on the box

        vm.store.send(.resolveNotice(from: n1, match: nil, via: .scrape))
        XCTAssertTrue(vm.store.notices.isEmpty)                  // dies on real resolution
        XCTAssertEqual(vm.store.tree[n1]?.status, .idle)         // wait over, no turn open
    }
}
