import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// History persistence and playback after restart — the app-layer wiring:
//   1) a launched session lives in a STABLE archive dir (meta.json + orchestration.jsonl),
//      which survives closeSession — that file pair IS the history record;
//   2) AppModel lists archived sessions (dead ones only) and opens a read-only view.
// Same T1b conventions as WiringTests: real SessionVM → Orchestrator → RealCell stacks,
// fake agent via the VIGIL_FAKE_AGENT_CMD seam, VIGIL_UITEST=1 isolates persistence
// (archive root goes to a pid-scoped temp dir — never the user's real history).

@MainActor
final class HistoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
    }

    private var apps: [AppModel] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        try? FileManager.default.removeItem(atPath: VigilArchive.root)
        super.tearDown()
    }

    // MARK: fixtures

    private func assertFakeSeamActive() throws {
        guard UITestSupport.fakeAgentCommand == WiringTests.stubScript else {
            XCTFail("fake-agent seam inactive — refusing to launch a real agent")
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
        let dir = NSTemporaryDirectory() + "vigil-hist-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    /// A dead-session fixture directly on disk — what a previous app run left behind.
    /// The sidebar groups rows by projectCwd: a fixture that must show up in the sidebar
    /// needs its owning project's cwd; the default orphan cwd matches no project and is
    /// not displayed — a known boundary.
    @discardableResult
    private func plantArchivedSession(id: String, name: String,
                                      transcript: String? = nil,
                                      createdAt: Date = Date(),
                                      projectCwd: String = "/tmp/p") throws -> String {
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines = [
            #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"root task"}"#,
            #"{"ts":"2026-07-07T10:01:00Z","event":"cell_launch","node":"n1","role":"leaf","root":false,"task":"worker A","parent":"root"}"#,
            #"{"ts":"2026-07-07T10:05:00Z","event":"exit","node":"n1","code":0}"#,
        ]
        if let transcript {
            lines.insert(
                #"{"ts":"2026-07-07T10:01:10Z","event":"agent_prompt","node":"n1","transcript":"\#(transcript)"}"#,
                at: 2)
        }
        try lines.joined(separator: "\n")
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: name, projectName: "Old Project", projectCwd: projectCwd,
                               agent: "claude", model: nil, createdAt: createdAt),
            dir: dir)
        return dir
    }

    // MARK: stable dir + meta

    func testLaunchSessionCreatesStableArchiveDirWithMeta() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "fix a bug",
                                                 agent: "claude", access: .standard))
        defer { vm.shutdown() }

        XCTAssertTrue(vm.archiveDir.hasPrefix(VigilArchive.root + "/"),
                      "session dir must live under the stable archive root, not tmp")
        let meta = try XCTUnwrap(SessionArchive.readMeta(dir: vm.archiveDir))
        XCTAssertEqual(meta.name, vm.name)
        XCTAssertEqual(meta.projectName, p.name)
        XCTAssertEqual(meta.projectCwd, p.cwd)
        XCTAssertEqual(meta.agent, "claude")
        // The orchestration trail starts at launch (root cell_launch) — same dir.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vm.archiveDir + "/orchestration.jsonl"))
    }

    func testCloseSessionLeavesArchiveOnDisk() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "task",
                                                 agent: "claude", access: .standard))
        let dir = vm.archiveDir
        app.closeSession(vm.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/orchestration.jsonl"),
                      "#17: orchestration.jsonl must survive session close (the history record)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/meta.json"))
    }

    func testRenameRewritesMeta() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "task",
                                                 agent: "claude", access: .standard))
        defer { vm.shutdown() }

        vm.setName("auto-named title")     // the AutoNamer path
        XCTAssertEqual(SessionArchive.readMeta(dir: vm.archiveDir)?.name, "auto-named title")
    }

    // MARK: history list (listable after restart)

    func testRefreshHistoryListsDeadSessionsOnly() throws {
        try assertFakeSeamActive()
        try plantArchivedSession(id: "20260706-090000-aaaaaaaa", name: "yesterday's task")
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "today's task",
                                                 agent: "claude", access: .standard))
        defer { vm.shutdown() }
        app.refreshHistory()

        XCTAssertEqual(app.history.map(\.id), ["20260706-090000-aaaaaaaa"],
                       "a live session's dir stays out of the history list; dead ones go in")
        XCTAssertEqual(app.history.first?.name, "yesterday's task")
    }

    func testClosedSessionAppearsInHistory() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "task",
                                                 agent: "claude", access: .standard))
        let dir = vm.archiveDir
        app.closeSession(vm.id)      // close refreshes history itself

        XCTAssertTrue(app.history.contains { $0.dir == dir })
    }

    func testOpenHistorySelectsItAndClearsLiveFocus() throws {
        try assertFakeSeamActive()
        try plantArchivedSession(id: "20260706-090000-bbbbbbbb", name: "old task")
        let app = makeApp()
        addProject(app)
        app.refreshHistory()

        app.openHistory("20260706-090000-bbbbbbbb")
        XCTAssertEqual(app.selectedHistoryID, "20260706-090000-bbbbbbbb")
        XCTAssertNil(app.activeSessionID)
        XCTAssertNotNil(app.selectedHistory)

        // Going back to a live surface drops the history selection.
        app.openLauncher(in: app.projects[0].id)
        XCTAssertNil(app.selectedHistoryID)
    }

    // MARK: end-to-end self-proof: real launch → close → "restart" → rebuild from real on-disk artifacts

    func testRestartRebuildsTreeAndTranscriptPointerFromRealArtifacts() throws {
        // Not a planted fixture: the orchestration.jsonl/meta.json here are what the
        // REAL SessionVM→Orchestrator stack wrote. A fresh AppModel (= app restart,
        // the PTY long dead) must list it and rebuild the skeleton + pointer join.
        try assertFakeSeamActive()
        let transcript = NSTemporaryDirectory() + "vigil-e2e-transcript-\(UUID().uuidString).jsonl"
        try #"{"type":"user","message":"hi"}"#.write(toFile: transcript, atomically: true,
                                                     encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: transcript) }

        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "end-to-end task",
                                                 agent: "claude", access: .standard))
        // The UserPromptSubmit hook path (what records the node→transcript join key).
        vm.orch.recordAgentPrompt(NodeID("root"), payload: ["transcript_path": transcript])
        let dir = vm.archiveDir
        app.closeSession(vm.id)

        let reborn = makeApp()                    // = app restart
        reborn.refreshHistory()
        let summary = try XCTUnwrap(reborn.history.first { $0.dir == dir },
                                    "after restart, history must list the previous session")
        XCTAssertEqual(summary.name, vm.name)

        let archived = try XCTUnwrap(SessionArchive.load(dir: summary.dir))
        let tree = try XCTUnwrap(archived.tree, "the tree skeleton must rebuild from the real orchestration.jsonl")
        XCTAssertEqual(tree.rootID, NodeID("root"))
        XCTAssertEqual(tree.root.role, .manager)
        XCTAssertEqual(archived.transcripts[NodeID("root")], transcript,
                       "pointer join: node → CLI transcript path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript))
    }

    // MARK: sidebar history section + middle-pane read-only playback (UI wiring)

    func testSidebarShowsHistoryRowsInsideOwningProject() throws {
        // Dead rows live inside their project group (joined by projectCwd); orphans
        // (cwd matches no project) are not displayed — a known boundary.
        let app = makeApp()
        let p = addProject(app)
        try plantArchivedSession(id: "20260706-090000-cccccccc", name: "history session",
                                 projectCwd: p.cwd)
        try plantArchivedSession(id: "20260706-090000-orphan00", name: "orphan")
        app.refreshHistory()

        let sidebar = SidebarView(app: app)
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.20260706-090000-cccccccc"))
        XCTAssertThrowsError(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.20260706-090000-orphan00"))
    }

    func testSidebarHistoryRowClickOpensHistoryView() throws {
        // A row click = view (self-rendered read-only view); it does not spawn a process
        // directly. Enter inside the view is resume.
        let app = makeApp()
        let p = addProject(app)
        try plantArchivedSession(id: "20260706-090000-dddddddd", name: "history session",
                                 projectCwd: p.cwd)
        app.refreshHistory()

        let sidebar = SidebarView(app: app)
        let row = try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.20260706-090000-dddddddd")
        try row.button().tap()
        XCTAssertEqual(app.selectedHistoryID, "20260706-090000-dddddddd")
        XCTAssertNil(app.activeSessionID, "a click only opens the read-only view; it never silently spawns a process")
        XCTAssertTrue(p.sessions.isEmpty)
    }

    // MARK: openHistory's view state (archive loaded / root selected / tree auto-expanded)

    func testOpenHistoryLoadsArchiveSelectsRootAndAutoExpandsTree() throws {
        // The fixture has two nodes (root+n1) → the tree card auto-expands.
        try plantArchivedSession(id: "20260706-090000-treeopen", name: "history with a tree")
        let app = makeApp()
        app.refreshHistory()

        app.openHistory("20260706-090000-treeopen")
        XCTAssertNotNil(app.historyArchive)
        XCTAssertEqual(app.historyNodeID, NodeID("root"))
        XCTAssertFalse(app.historyTreeCollapsed, "with a tree (>1 node), opening auto-expands")
    }

    func testOpenHistorySingleNodeKeepsTreeCollapsed() throws {
        let dir = VigilArchive.root + "/20260706-090000-solonode"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"single node"}"#
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        let app = makeApp()
        app.refreshHistory()

        app.openHistory("20260706-090000-solonode")
        XCTAssertTrue(app.historyTreeCollapsed, "no tree means no tree card pops up")
    }

    /// In history state, the top-bar tree toggle flips app.historyTreeCollapsed (same AX
    /// id as the terminal-state toggle, but a different binding source).
    func testTopBarHistoryTreeToggle_tapFlipsHistoryTreeCard() throws {
        try plantArchivedSession(id: "20260706-090000-toggle00", name: "history with a tree")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-toggle00")
        XCTAssertFalse(app.historyTreeCollapsed, "with a tree (>1 node), opening auto-expands")

        let bar = TopBar(app: app)
        func tapToggle() throws {
            try bar.inspect().find(ViewType.Button.self,
                where: { (try? $0.accessibilityIdentifier()) == "top.treeToggle" }).tap()
        }
        try tapToggle()
        XCTAssertTrue(app.historyTreeCollapsed, "one tap = collapse the tree card")
        try tapToggle()
        XCTAssertFalse(app.historyTreeCollapsed, "tap again = expand")
    }

    // MARK: history tree overlay card (the tree skeleton lives in a top-right card; click a node to view it)

    func testHistoryTreePanelRendersSkeletonRows() throws {
        try plantArchivedSession(id: "20260706-090000-eeeeeeee", name: "history session")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-eeeeeeee")

        let panel = HistoryTreePanel(app: app,
                                     archive: try XCTUnwrap(app.historyArchive))
        let inspected = try panel.inspect()
        XCTAssertNoThrow(try inspected
            .find(viewWithAccessibilityIdentifier: "history.node.root"))
        XCTAssertNoThrow(try inspected
            .find(viewWithAccessibilityIdentifier: "history.node.n1"))
    }

    /// Node-id badge: the frozen history rows must show each node's id as visible text
    /// (root / n1) — same disambiguation the live tree card gets, via the shared NodeRow.
    func testHistoryTreePanelRowShowsNodeIdBadge() throws {
        try plantArchivedSession(id: "20260706-090000-idbadge0", name: "history session")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-idbadge0")

        let panel = HistoryTreePanel(app: app,
                                     archive: try XCTUnwrap(app.historyArchive))
        let inspected = try panel.inspect()
        XCTAssertNoThrow(try inspected.find(text: "root"),
                         "root row must show its node id as text")
        XCTAssertNoThrow(try inspected.find(text: "n1"),
                         "worker row must show its node id (n1) as text")
    }

    func testHistoryTreePanelRowClickSelectsNode() throws {
        try plantArchivedSession(id: "20260706-090000-select00", name: "history session")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-select00")

        let panel = HistoryTreePanel(app: app,
                                     archive: try XCTUnwrap(app.historyArchive))
        try panel.inspect()
            .find(viewWithAccessibilityIdentifier: "history.node.n1")
            .button().tap()
        XCTAssertEqual(app.historyNodeID, NodeID("n1"), "clicking a node = the middle pane renders that node's transcript")
    }

    func testHistoryTreePanelRowsCarryNoTranscriptTag() throws {
        // Rows do not carry a transcript pointer tag; a row is structurally identical to a
        // finished node on the live tree panel. The honest three-state pointer explanation is
        // owned by the middle pane (HistoryPane.content) instead — the row must not show
        // "transcript" when available, and must say nothing about it when cleaned either.
        let t = NSTemporaryDirectory() + "vigil-hist-transcript-\(UUID().uuidString).jsonl"
        try "{}\n".write(toFile: t, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: t) }
        try plantArchivedSession(id: "20260706-090000-gggggggg", name: "history session",
                                 transcript: t)
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-gggggggg")

        let panel = HistoryTreePanel(app: app,
                                     archive: try XCTUnwrap(app.historyArchive))
        let row = try panel.inspect()
            .find(viewWithAccessibilityIdentifier: "history.node.n1")
        XCTAssertNil(try? row.find(text: "transcript"), "the pointer tag was removed; it must not appear on the row anymore")
    }

    func testHistoryTreePanelMissingTranscriptRowStaysPlain() throws {
        // A stale pointer (cleaned up by the CLI) also isn't mentioned on the row — the
        // honest explanation is stated exactly once, in the middle pane (cleaned note).
        try plantArchivedSession(id: "20260706-090000-ffffffff", name: "history session",
                                 transcript: "/tmp/vigil-no-such-transcript.jsonl")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-ffffffff")

        let panel = HistoryTreePanel(app: app,
                                     archive: try XCTUnwrap(app.historyArchive))
        let row = try panel.inspect()
            .find(viewWithAccessibilityIdentifier: "history.node.n1")
        XCTAssertNil(try? row.find(text: "cleaned up by claude"), "row is structurally the same as a normally-finished node")
    }

    // MARK: middle-pane self-rendering + bottom Enter row

    func testHistoryPaneRendersTranscriptAndResumeHint() throws {
        let dir = try plantArchivedSession(id: "20260706-090000-hhhhhhhh", name: "resumable history",
                                           projectCwd: "/tmp/p")
        // Add a resume credential to meta → the bottom shows an Enter hint instead of a read-only note.
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: "20260706-090000-hhhhhhhh", name: "resumable history",
                               projectName: "Old Project", projectCwd: "/tmp/p",
                               agent: "claude", model: nil, createdAt: Date(),
                               rootSessionId: "sid-1"),
            dir: dir)
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-hhhhhhhh")
        let summary = try XCTUnwrap(app.selectedHistory)

        let pane = HistoryPane(app: app, summary: summary,
                               preloadedItems: [
                                   TranscriptItem(id: 0, kind: .user, text: "old task's question"),
                                   TranscriptItem(id: 1, kind: .assistant, text: "old task's answer"),
                               ])
        let v = try pane.inspect()
        XCTAssertNoThrow(try v.find(viewWithAccessibilityIdentifier: "transcript.read"))
        XCTAssertNotNil(try? v.find(text: "old task's question"))
        XCTAssertNotNil(try? v.find(text: "old task's answer"))
        XCTAssertNoThrow(try v.find(viewWithAccessibilityIdentifier: "history.resumeHint"))
        XCTAssertNoThrow(try v.find(ViewType.Text.self,
                                    where: { try $0.string().contains("Press Enter to resume this conversation") }))
    }

    /// The history pane's resume hint dispatches by the node's own family (cell_launch
    /// `kind`) — a dead opencode session shows `opencode --session`, never a hardcoded
    /// `--resume`.
    func testHistoryPaneResumeHintUsesNodeOwnFamily() throws {
        let id = "20260706-090000-openhist"
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"root task","kind":"opencode"}"#,
            #"{"ts":"2026-07-07T10:01:10Z","event":"agent_prompt","node":"root","session_id":"ses_x"}"#,
        ]
        try lines.joined(separator: "\n")
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: "opencode history", projectName: "Old Project",
                               projectCwd: "/tmp/p", agent: "opencode", model: nil,
                               createdAt: Date(), rootSessionId: "ses_x"),
            dir: dir)
        let app = makeApp()
        app.refreshHistory()
        app.openHistory(id)
        let summary = try XCTUnwrap(app.selectedHistory)
        let pane = HistoryPane(app: app, summary: summary,
                               preloadedItems: [TranscriptItem(id: 0, kind: .user, text: "hi")])
        let v = try pane.inspect()
        XCTAssertNoThrow(try v.find(ViewType.Text.self,
            where: { try $0.string().contains("opencode --session") }))
        XCTAssertThrowsError(try v.find(ViewType.Text.self,
            where: { try $0.string().contains("--resume") }),
            "opencode history must never show claude's --resume")
    }

    func testHistoryPaneShowsStatsCardAfterTranscript() throws {
        // The /status·/usage info card, sharing the same source, is appended at the end of
        // the conversation (version/sid/model/usage all come from the transcript itself; the
        // $ cost field is null in 2.1.x, so it's honestly left unshown).
        try plantArchivedSession(id: "20260706-090000-jjjjjjjj", name: "history with stats")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-jjjjjjjj")
        let summary = try XCTUnwrap(app.selectedHistory)

        var stats = TranscriptStats(version: "2.1.204", sessionId: "sid-x",
                                    wallSeconds: 1164)
        stats.sessionName = "history with stats"
        stats.models = [.init(model: "claude-fable-5", input: 4_800, output: 38_100,
                              cacheRead: 4_500_000, cacheWrite: 133_600)]
        let pane = HistoryPane(app: app, summary: summary,
                               preloadedItems: [TranscriptItem(id: 0, kind: .user, text: "hi")],
                               preloadedStats: stats)
        let v = try pane.inspect()
        XCTAssertNoThrow(try v.find(viewWithAccessibilityIdentifier: "transcript.stats"))
        XCTAssertNotNil(try? v.find(text: "2.1.204"))
        XCTAssertNotNil(try? v.find(text: "19m 24s"))
        XCTAssertNotNil(try? v.find(ViewType.Text.self,
                                    where: { try $0.string().contains("4.5m cache read") }))
    }

    func testHistoryPaneWithoutResumeKeyShowsReadOnlyLine() throws {
        // An old archive with no rootSessionId → honestly read-only, Enter promises nothing.
        try plantArchivedSession(id: "20260706-090000-iiiiiiii", name: "old archive")
        let app = makeApp()
        app.refreshHistory()
        app.openHistory("20260706-090000-iiiiiiii")
        let summary = try XCTUnwrap(app.selectedHistory)

        let pane = HistoryPane(app: app, summary: summary,
                               preloadedItems: [TranscriptItem(id: 0, kind: .user, text: "hi")])
        XCTAssertNotNil(try? pane.inspect().find(ViewType.Text.self,
            where: { try $0.string().contains("Read-only — this archive has no resume credentials") }))
    }
}
