import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Visual snapshot tests. Key UI states are rendered
// into PNG goldens: empty state / launcher / terminal-state chrome / notification cards
// (single + stacked) / rail (expanded + collapsed), each × two themes (dark/light).
// Goldens live under __Snapshots__/SnapshotTests/ and are committed to the repo.
// Conventions and re-recording steps are in this directory's README.md.
//
// ─── CI skip (an honest disclosure, not slacking) ───────────────────────────
// Goldens were recorded on this machine (macOS 26.5 / Apple Silicon / this machine's font
// stack). GitHub CI's macos-latest runner is a different macOS major version with no local
// GUI session — text antialiasing, font metrics, and material rendering can all shift
// systematically. This kind of "whole-image drift" isn't something perceptualPrecision
// ~0.98 can reliably absorb (that's suited for local pixel jitter), and there's no way to
// pre-validate runner rendering locally. Snapshot tests run locally by default (covered by
// pre-commit's swift test), and are XCTSkip'd on CI (when the `CI` env var is present) —
// the skip is explicit and shows up in the test report. If a runner-specific golden set is
// ever recorded, this skip can be removed.
//
// ─── Determinism design ──────────────────────────────────────────────────────
// · Fake agent: SessionVM can't have a fake harness injected directly, but there's a
//   VIGIL_FAKE_AGENT_CMD environment-variable seam (AppModel.UITestSupport → ScriptHarness):
//   the cell runs a silent sleep script instead of real claude — zero terminal output, no
//   tokens burned. The script fixture is shared with WiringTests via the same
//   `WiringTests.stubScript`: UITestSupport.env is a static let that freezes on first
//   access, so within one process two test classes must setenv the exact same path —
//   otherwise whichever runs first will break the seam check for whichever runs second
//   (don't go back to each class writing its own script).
// · A "done" node: n3 goes through the real exit path to reach the done terminal state;
//   see the timing note on markDone().
// · Appearance pinned: NSHostingView.appearance is explicitly set to darkAqua/aqua — not
//   affected by this machine's system dark/light mode (dynamic colors like material /
//   .primary resolve against this).
// · Size pinned: SPEC §1 canvas is 1360×860, titlebar 44, rail expanded 236 / collapsed 58
//   → middle pane 1124×816. Off-screen rendering (no window) → a 1x bitmap, material has
//   no blur but is deterministic.
// · The worktree path to the right of the terminal-state breadcrumb = NSTemporaryDirectory()
//   + pid, which naturally differs on every run — that area is covered with an opaque mask
//   carrying explanatory text (visible in the golden, documented in the README), rather than
//   lowering precision to swallow the real difference.
// · Notification card timestamps are always "just now" (the fallback text for a first frame
//   with firstSeen == nil is the same as the text for 0s).
@MainActor
final class SnapshotTests: XCTestCase {

    // MARK: - conventions (README.md is authoritative)

    /// SPEC §1: design canvas 1440×980; main-area top bar 50; sidebar 248 (collapsed = gone, no collapse rail).
    private static let center        = CGSize(width: 1440 - 248, height: 980 - 50)  // 1192×930
    private static let sidebar       = CGSize(width: 248, height: 980)
    private static let treePanel     = CGSize(width: 322 + 32, height: 320)
    private static let notifSingle   = CGSize(width: 380, height: 132)
    private static let notifStack    = CGSize(width: 380, height: 300)   // cards carry a session row, so taller

    /// Consecutive local runs should be byte-identical; the tolerance only absorbs tiny
    /// local rendering jitter (things like GPU antialiasing) — it is not meant to swallow
    /// dynamic content (dynamic content is always masked/pinned instead).
    private static let precision: Float = 0.995
    private static let perceptualPrecision: Float = 0.98

    // MARK: - fixtures

    /// CI skip + install the fake agent (called at the start of every test; idempotent).
    /// The script path must match WiringTests exactly (see the "Determinism design" note
    /// at the top of this file); the content is owned by WiringTests (a silent sleep stub).
    private func prepare() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "snapshot tests run locally by default; a CI runner's rendering can't be guaranteed to match this machine's golden (see the file header / README.md)"
        )
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
        guard UITestSupport.fakeAgentCommand == WiringTests.stubScript else {
            XCTFail("fake-agent seam inactive (UITestSupport froze to another value before setenv) — " +
                    "refusing to launch a real claude")
            struct SeamInactive: Error {}
            throw SeamInactive()
        }
    }

    private var fixtureDir: String { NSTemporaryDirectory() + "vigil-snapshot-fixture" }

    /// An AppModel with a project. The project directory is a non-git temp dir → the launcher branch is always "main".
    private func makeProjectApp() throws -> (app: AppModel, project: ProjectVM) {
        let cwd = fixtureDir + "/vigil-demo"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let app = AppModel()
        let p = ProjectVM(id: "p1", name: "vigil-demo", cwd: cwd)
        app.projects = [p]
        app.currentProjectID = p.id
        return (app, p)
    }

    /// Construct SessionVM directly (bypassing launchSession, to avoid a toast); the fake agent is guaranteed by prepare().
    private func makeSession(app: AppModel, project: ProjectVM, id: String) -> SessionVM {
        let vm = SessionVM(id: id, name: "Refactor API module", rootCwd: project.cwd,
                           initialTask: "Refactor API module", access: .standard)
        project.sessions = [vm]
        app.activeSessionID = vm.id
        return vm
    }

    /// Pinned for the capture window: PermWatcher's scrape fallback would silently resolve
    /// a permission card with no frame to match against, once armWindow(5s) elapses (the
    /// stub agent's screen never has approval-anchor text) — the snapshot's exposure window
    /// must not be at its mercy.
    private func freezeNotices(_ vm: SessionVM) {
        vm.orch.permWatcher?.stop()
    }

    /// Seed a permission card (the notification surface is permission-events only).
    /// A card only becomes visible after a ~2.5s auto-approval
    /// grace period — a test that needs to capture the card must pump past the grace period
    /// after seeding (see the two notif tests).
    private func seedPermCard(_ vm: SessionVM, node: NodeID,
                              input: String = #"{"command":"git push"}"#,
                              text: String = "Awaiting authorization · Bash(git push)") {
        vm.store.send(.permRequested(from: node, info: PermNoticeInfo(
            promptID: "p1", toolName: "Bash", toolInput: input,
            inputSummary: "git push", text: text)))
    }

    /// State-matrix tree: root (manager · running) ├─ n1 (awaiting authorization) ├─ n2 (manager · running) └─ n2/n3 (done).
    private func growTree(_ vm: SessionVM) {
        let root = vm.store.tree.rootID
        freezeNotices(vm)
        vm.store.send(.requestStruct(.spawn(parent: root, role: .leaf, task: "Review REST routes"),
                                     from: root, replyID: UUID()))
        vm.store.send(.requestStruct(.spawn(parent: root, role: .manager, task: "Rewrite auth middleware"),
                                     from: root, replyID: UUID()))
        vm.store.send(.requestStruct(.spawn(parent: NodeID("n2"), role: .leaf, task: "Add integration tests"),
                                     from: root, replyID: UUID()))
        seedPermCard(vm, node: NodeID("n1"))
        pump(0.2)   // let each cell's start Task run to completion first (the process must have started for terminate to have anything to kill)
        markDone(vm, NodeID("n3"))
    }

    /// Force a node into a deterministic "done" terminal state: nodeExited(0) synchronously
    /// marks it done via SessionStore.selfDeath. The stub process itself is still running at
    /// this point (self-death spares the dying node's own backend — only still-live
    /// descendants get reaped) and only gets torn down later, at the test's `vm.shutdown()`.
    /// That late real exit report lands after the node is already terminal, and selfDeath
    /// ignores a report for a node that's already terminal — so it can't flip done back to
    /// failed, keeping "done" stable during capture regardless of timing.
    private func markDone(_ vm: SessionVM, _ id: NodeID) {
        vm.store.send(.nodeExited(id, code: 0))
        XCTAssertEqual(vm.store.tree[id]?.status, .done, "the \"done\" terminal state didn't settle")
    }

    // MARK: - render helpers

    /// Render the same state in both themes: pin vg tokens (environment injection) +
    /// app.theme (RailView2 and friends read app.tokens directly) + NSAppearance, at a
    /// fixed size, off-screen, pumping the run loop until layout settles before capturing.
    private func assertThemed<V: View>(
        size: CGSize, app: AppModel? = nil,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line,
        @ViewBuilder content: (VGTokens) -> V
    ) {
        for theme in [VGTheme.dark, VGTheme.light] {
            app?.theme = theme
            let tokens = VGTokens.make(theme, .blue)
            let host = NSHostingView(rootView: content(tokens).environment(\.vg, tokens))
            host.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            pump(0.15)
            assertSnapshot(of: host,
                           as: .image(precision: Self.precision,
                                      perceptualPrecision: Self.perceptualPrecision,
                                      size: size),
                           named: theme.rawValue, file: file, testName: testName, line: line)
        }
    }

    /// Pump the main run loop (runs @MainActor Task / onAppear / layout callbacks).
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !cond() && Date() < deadline { pump(0.02) }
        XCTAssertTrue(cond(), "timed out waiting for \(what) (\(timeout)s) — state didn't settle before the snapshot")
    }

    /// Covers the worktree path to the right of the breadcrumb (NSTemporaryDirectory()+pid,
    /// dynamic at runtime). Opaque, with explanatory text, clearly visible in the golden —
    /// a mask, not a lowered precision, absorbs the difference.
    private func breadcrumbPathMask(_ tokens: VGTokens) -> some View {
        ZStack(alignment: .trailing) {
            tokens.term
            Text("‹worktree path · dynamic at runtime, masked›")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tokens.text3)
                .padding(.trailing, 18)
        }
        .frame(width: 640, height: 38)
    }

    /// Covers the entire terminal content area below the header: the login shell ghostty
    /// starts prints "Last login: <timestamp>", which necessarily varies across runs — this
    /// snapshot only pins the chrome (header); terminal-rendering correctness is guarded by
    /// the T2/T3 layers.
    private func terminalBodyMask(_ tokens: VGTokens) -> some View {
        ZStack {
            tokens.term
            Text("‹terminal content · dynamic at runtime, masked›")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tokens.text3)
        }
        .frame(height: Self.center.height - 38)
    }

    /// Notification-card canvas: replicates AppBody's placement (topTrailing over the
    /// middle pane's terminal background, top 14 / right 16). NotifStack is an
    /// app-level global stack (aggregated across sessions), so the canvas is handed the
    /// app directly.
    private func notifCanvas(_ app: AppModel, _ tokens: VGTokens) -> some View {
        ZStack(alignment: .topTrailing) {
            tokens.term
            NotifStack(app: app)
                .padding(.vertical, 14).padding(.trailing, 16)
        }
    }

    // MARK: - ① no-project empty state

    func testEmptyState() throws {
        try prepare()
        let app = AppModel()   // projects is empty → NoProjectView
        assertThemed(size: Self.center, app: app) { _ in
            NoProjectView(app: app)
        }
    }

    // MARK: - ② launcher startup screen (agent / model / approval pickers)

    func testLauncher() throws {
        try prepare()
        let (app, p) = try makeProjectApp()
        assertThemed(size: Self.center, app: app) { _ in
            LauncherView(app: app, project: p)
        }
    }

    // MARK: - ③ terminal-state chrome (breadcrumb + layout; empty terminal = the silent fake agent, see the file header)

    func testTerminalChrome() throws {
        try prepare()
        let (app, p) = try makeProjectApp()
        let vm = makeSession(app: app, project: p, id: "snapTerm")
        defer { vm.shutdown() }
        growTree(vm)
        pump(0.3)   // pump a bit more once the tree has settled: let the cell-start background tasks drain, so capture time sees zero events
        assertThemed(size: Self.center, app: app) { tokens in
            TerminalPane(app: app, session: vm)
                .overlay(alignment: .topTrailing) { breadcrumbPathMask(tokens) }
                .overlay(alignment: .bottom) { terminalBodyMask(tokens) }
        }
    }

    // MARK: - ④ top-right notification card (single / multi stacked)

    func testNotifCardSingle() throws {
        try prepare()
        let (app, p) = try makeProjectApp()
        let vm = makeSession(app: app, project: p, id: "snapNotif1")
        defer { vm.shutdown() }
        freezeNotices(vm)
        let root = vm.store.tree.rootID
        vm.store.send(.requestStruct(.spawn(parent: root, role: .leaf, task: "Review REST routes"),
                                     from: root, replyID: UUID()))
        seedPermCard(vm, node: NodeID("n1"))
        pump(AgentNotice.permissionGrace + 0.2)   // past the auto-approval grace period, so the card becomes visible
        assertThemed(size: Self.notifSingle, app: app) { tokens in
            notifCanvas(app, tokens)
        }
    }

    /// Multiple cards: two sessions each produce a card — grouped
    /// across sessions (reverse chronological, clustered within a session), each card
    /// carrying a project·session identifier row. The active session's root card sits in
    /// the selected state → the same image covers both the "selected tint / unselected"
    /// card styles. Arrival order is pinned via pump (arrivedAt drives the sort).
    func testNotifCardStack() throws {
        try prepare()
        let (app, p) = try makeProjectApp()
        let vm = makeSession(app: app, project: p, id: "snapNotifN")
        defer { vm.shutdown() }
        let vm2 = SessionVM(id: "snapNotifN2", name: "Add integration tests", rootCwd: p.cwd,
                            initialTask: "Add integration tests", access: .standard)
        p.sessions.append(vm2)
        defer { vm2.shutdown() }
        freezeNotices(vm)
        freezeNotices(vm2)
        let root = vm.store.tree.rootID
        vm.store.send(.requestStruct(.spawn(parent: root, role: .leaf, task: "Review REST routes"),
                                     from: root, replyID: UUID()))
        seedPermCard(vm, node: root, input: #"{"command":"npm test"}"#,
                     text: "Awaiting authorization · Bash(npm test)")
        pump(0.02)
        seedPermCard(vm, node: NodeID("n1"))
        pump(0.02)
        seedPermCard(vm2, node: vm2.store.tree.rootID,
                     input: #"{"file_path":"routes.py"}"#, text: "Awaiting authorization · Edit(routes.py)")
        pump(AgentNotice.permissionGrace + 0.2)   // past the auto-approval grace period, all three cards visible together
        // Expected order (top→bottom): vm2.root (newest) · vm.n1 · vm.root (the active session's selected node → the selection ring)
        assertThemed(size: Self.notifStack, app: app) { tokens in
            notifCanvas(app, tokens)
        }
    }

    // MARK: - ⑤ sidebar (Codex-style: new chat/search · project › sessions · bottom account area)

    /// The session row's time column = createdAt's relative time; capture happens
    /// milliseconds after creation → always "just now", stable.
    func testSidebar() throws {
        try prepare()
        let (app, p) = try makeProjectApp()
        let vm = makeSession(app: app, project: p, id: "snapSide")
        defer { vm.shutdown() }
        growTree(vm)
        // A second project (collapsed, no sessions) → the same image covers both expanded/collapsed project row styles.
        let p2 = ProjectVM(id: "p2", name: "docs-site", cwd: p.cwd)
        p2.expanded = false
        app.projects.append(p2)
        assertThemed(size: Self.sidebar, app: app) { _ in
            SidebarView(app: app)
        }
    }

    // MARK: - ⑥ node tree panel (top-right overlay card)

    /// The runtime-duration column = counted from the panel's first observation: render →
    /// capture is <1s → always "0s" (done freezes at 0s, ghost shows "—"), stable. Canvas =
    /// card 322 + the middle pane's terminal-background margin, replicating OverlayColumn's
    /// placement. Note: **no extra pump** after growTree — an extra pump would open a
    /// window for the stub's exit callback to flip n3's done into failed.
    func testTreePanel() throws {
        try prepare()
        let (app, p) = try makeProjectApp()
        let vm = makeSession(app: app, project: p, id: "snapTree")
        defer { vm.shutdown() }
        growTree(vm)
        assertThemed(size: Self.treePanel, app: app) { tokens in
            ZStack(alignment: .topTrailing) {
                tokens.term
                TreePanel(session: vm)
                    .environment(\.vg, tokens)
                    .padding(.top, 14).padding(.trailing, 16)
            }
        }
    }
}
