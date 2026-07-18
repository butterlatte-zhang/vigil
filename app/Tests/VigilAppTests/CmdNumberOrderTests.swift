import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// ⌘1–9 selects the Nth session row the SIDEBAR shows, top to bottom — no liveness filtering,
// behaving exactly like a mouse click on that row (live row = switch to it, dead row = open
// its read-only history). The ⌘N source of truth must be the same ordering the sidebar
// actually renders (rows(for:): reverse-chron, merged live+dead, honoring collapse / expand /
// the >5 fold / search), not a second independent ordering. These tests pin two things:
//   1) reconciliation: the sidebar's rendered row order == visibleSessionRows() (the ⌘N
//      source), across mixed live/dead, the >5 fold, and search;
//   2) ⌘N semantics: the Nth row is picked as-clicked (live → select, dead → openHistory),
//      even when creation order and render order diverge.
@MainActor
final class CmdNumberOrderTests: XCTestCase {

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

    private func makeApp() -> AppModel { let a = AppModel(); apps.append(a); return a }

    @discardableResult
    private func addProject(_ app: AppModel, name: String = "Demo Project") -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-cmdn-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    @discardableResult
    private func plant(id: String, name: String, projectCwd: String?, createdAt: Date) throws -> String {
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"ts":"2026-07-13T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"t"}"#
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: name, projectName: nil, projectCwd: projectCwd,
                               agent: "claude", model: nil, createdAt: createdAt),
            dir: dir)
        return dir
    }

    @discardableResult
    private func launch(_ app: AppModel, _ p: ProjectVM, task: String) throws -> SessionVM {
        try XCTUnwrap(app.launchSession(in: p.id, task: task, agent: "claude", access: .standard))
    }

    private func axid(_ r: RailRow) -> String {
        switch r {
        case .live(let s): "rail.session.\(s.id)"
        case .dead(let d): "side.history.\(d.id)"
        }
    }

    /// Whatever SidebarView renders, top to bottom, must be exactly visibleSessionRows() —
    /// same rows, same order. Reads the rendered session-row AX ids in traversal order and
    /// compares to the ⌘N source. Hover-action/status sub-ids are filtered out; project header
    /// rows (rail.project.*) never match (they carry no ⌘N slot).
    private func assertRenderMatchesModel(_ app: AppModel,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let sidebar = SidebarView(app: app)
        let rendered = try sidebar.inspect().findAll(ViewType.Button.self)
            .compactMap { try? $0.accessibilityIdentifier() }
            .filter { id in
                (id.hasPrefix("rail.session.") || id.hasPrefix("side.history."))
                && !id.hasSuffix(".archive") && !id.hasSuffix(".unarchive")
                && !id.contains(".status.")
            }
        XCTAssertEqual(rendered, app.visibleSessionRows().map(axid),
                       "sidebar render order must match visibleSessionRows (⌘N source) row-for-row", file: file, line: line)
    }

    // MARK: 1) reconciliation — render order == ⌘N source

    func testRenderOrderMatchesModel_mixedLiveAndDead() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "d-old", name: "old-dead", projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: -7200))
        try plant(id: "d-new", name: "new-dead", projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: 3600))
        app.refreshHistory()
        _ = try launch(app, p, task: "active")   // createdAt = now → sorts between the two

        // rows(for:) newest-first: new-dead(+1h), active(now), old-dead(-2h).
        XCTAssertEqual(app.visibleSessionRows().map(\.name), ["new-dead", "active", "old-dead"])
        try assertRenderMatchesModel(app)
    }

    func testRenderOrderMatchesModel_underFold() throws {
        RuntimeTuning.current.sidebarCollapseThreshold = 5
        addTeardownBlock { RuntimeTuning.current = .defaults }
        let app = makeApp()
        let p = addProject(app)
        for i in 0..<7 {
            try plant(id: "f-\(i)", name: "session\(i)", projectCwd: p.cwd,
                      createdAt: Date(timeIntervalSinceNow: TimeInterval(-i * 60)))
        }
        app.refreshHistory()

        // Folded: only the first 5 rows get a slot; session 5 / session 6 are hidden.
        XCTAssertEqual(app.visibleSessionRows().map(\.name),
                       ["session0", "session1", "session2", "session3", "session4"])
        try assertRenderMatchesModel(app)

        app.toggleShowAllRows(p)   // expand → all 7 counted
        XCTAssertEqual(app.visibleSessionRows().count, 7)
        try assertRenderMatchesModel(app)
    }

    func testRenderOrderMatchesModel_underSearch() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "s-apple",   name: "apple",   projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: -10))
        try plant(id: "s-banana",  name: "banana",  projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: -20))
        try plant(id: "s-apricot", name: "apricot", projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: -30))
        app.refreshHistory()

        app.searchQuery = "ap"   // matches apple + apricot, drops banana
        XCTAssertEqual(app.visibleSessionRows().map(\.name), ["apple", "apricot"])
        try assertRenderMatchesModel(app)
    }

    func testCollapsedSectionRemovesRowsFromCount() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "c-1", name: "row one", projectCwd: p.cwd, createdAt: Date())
        app.refreshHistory()
        XCTAssertEqual(app.visibleSessionRows().count, 1)

        app.toggleSection("projects")   // collapse the Projects section
        XCTAssertTrue(app.visibleSessionRows().isEmpty, "rows in a collapsed section don't count toward ⌘N")
        app.selectIndex(1)
        XCTAssertNil(app.activeSessionID)
        XCTAssertNil(app.selectedHistoryID)
    }

    // MARK: 2) ⌘N semantics — as-clicked, no liveness filter

    /// A project whose LIVE row sits at the BOTTOM (two dead rows dated above it): ⌘1 must
    /// hit the TOP row (a dead one → read-only history), not the live session.
    func testReportedRepro_cmd1HitsTopRowNotBottomLive() throws {
        let app = makeApp()
        let p = addProject(app)
        let live = try launch(app, p, task: "bottom live")   // createdAt = now
        try plant(id: "dead-top", name: "top", projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: 7200))
        try plant(id: "dead-mid", name: "mid", projectCwd: p.cwd, createdAt: Date(timeIntervalSinceNow: 3600))
        app.refreshHistory()

        // Render order top→bottom: top(dead), mid(dead), active(live) — live is the BOTTOM row.
        XCTAssertEqual(app.visibleSessionRows().map(\.name), ["top", "mid", "bottom live"])
        // allSessions is live-only and does not match the render order used by ⌘N.
        XCTAssertEqual(app.allSessions.map(\.name), ["bottom live"])

        // ⌘1 = TOP row (dead) → read-only history, NOT the live session.
        app.selectIndex(1)
        XCTAssertNil(app.activeSessionID)
        XCTAssertEqual(app.selectedHistoryID, "dead-top")

        // ⌘3 = the bottom live row → switch to it (history cleared).
        app.selectIndex(3)
        XCTAssertEqual(app.activeSessionID, live.id)
        XCTAssertNil(app.selectedHistoryID)
    }

    func testCmdN_deadRowOpensReadOnlyHistory() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "dead-only", name: "dead session", projectCwd: p.cwd, createdAt: Date())
        app.refreshHistory()

        app.selectIndex(1)
        XCTAssertEqual(app.selectedHistoryID, "dead-only", "dead row ⌘N = openHistory, same as a click")
        XCTAssertNil(app.activeSessionID)
    }

    func testCmdN_liveRowSwitchesToIt() throws {
        let app = makeApp()
        let p = addProject(app)
        let a = try launch(app, p, task: "alpha")
        let b = try launch(app, p, task: "bravo")   // newest → top row
        app.select(session: a.id)

        app.selectIndex(1)
        XCTAssertEqual(app.activeSessionID, b.id, "⌘1 = top row (newest live session)")
        app.selectIndex(2)
        XCTAssertEqual(app.activeSessionID, a.id, "⌘2 = second row")
    }

    func testCmdN_outOfRangeIsNoOp() throws {
        let app = makeApp()
        let p = addProject(app)
        let a = try launch(app, p, task: "only")
        app.select(session: a.id)
        app.selectIndex(5)                       // only 1 row
        XCTAssertEqual(app.activeSessionID, a.id, "out of range = no-op")
        app.selectIndex(0)
        XCTAssertEqual(app.activeSessionID, a.id)
    }

    /// Sections after Projects (Chats/Settings/Archived) count in render order too.
    func testCmdN_spansSectionsInRenderOrder() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "proj-row", name: "project row", projectCwd: p.cwd, createdAt: Date())
        try plant(id: "chat-row", name: "chat row", projectCwd: app.chatsProject.cwd, createdAt: Date())
        app.refreshHistory()

        // Projects section row first, then the Chats section row.
        XCTAssertEqual(app.visibleSessionRows().map(\.name), ["project row", "chat row"])
        app.selectIndex(2)
        XCTAssertEqual(app.selectedHistoryID, "chat-row")
    }
}
