import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Model layer + wiring for the sidebar's Codex-style grouping:
//   Dead sessions are grouped into their project by meta.projectCwd, merged with
//   live sessions in reverse chronological order; >5 collapses by default, with a
//   trailing "Expand all (N)" row; orphans (cwd matching no project) aren't shown.
//   Chats/Settings = built-in pseudo-projects (not persisted into projects); the
//   three section headers can be collapsed; "New chat" with no current project
//   lands in [Chats].

@MainActor
final class SidebarGroupingTests: XCTestCase {

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

    private func makeApp() -> AppModel {
        let app = AppModel()
        apps.append(app)
        return app
    }

    @discardableResult
    private func addProject(_ app: AppModel, name: String = "Demo Project") -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-group-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    @discardableResult
    private func plant(id: String, name: String, projectCwd: String?,
                       createdAt: Date) throws -> String {
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"t"}"#
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: name, projectName: nil, projectCwd: projectCwd,
                               agent: "claude", model: nil, createdAt: createdAt),
            dir: dir)
        return dir
    }

    // MARK: grouping + reverse-chronological merge

    func testRowsMergeLiveAndDeadNewestFirstAndDropOrphans() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "a-dead-old", name: "old-dead", projectCwd: p.cwd,
                  createdAt: Date(timeIntervalSinceNow: -7200))
        try plant(id: "b-dead-new", name: "new-dead", projectCwd: p.cwd,
                  createdAt: Date(timeIntervalSinceNow: 3600))   // future → must sort first
        try plant(id: "c-orphan", name: "orphan", projectCwd: "/tmp/vigil-gone",
                  createdAt: Date())
        app.refreshHistory()
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "active",
                                                 agent: "claude", access: .standard))

        let rows = app.rows(for: p)
        XCTAssertEqual(rows.map(\.name), ["new-dead", "active", "old-dead"], "live+dead merged, reverse chronological")
        XCTAssertFalse(app.rows(for: app.chatsProject).contains { $0.name == "orphan" })
        _ = vm
    }

    // MARK: built-in pseudo-projects

    func testBuiltinsAreNotPersistedAsProjects() {
        let app = makeApp()
        XCTAssertEqual(app.allProjects.suffix(2).map(\.id),
                       ["builtin-chats", "builtin-settings"], "chats/settings pinned last")
        XCTAssertFalse(app.projects.contains { $0.id.hasPrefix("builtin-") })
    }

    func testNewChatWithoutCurrentProjectLandsInChats() {
        let app = makeApp()
        app.newChat()
        XCTAssertEqual(app.currentProjectID, app.chatsProject.id)
        XCTAssertNil(app.activeSessionID, "the chats bucket's launcher lives in the center pane")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.chatsProject.cwd),
                      "the chats directory is created on first use")
    }

    func testSettingsArchivedSessionsGroupUnderSettings() throws {
        let app = makeApp()
        try plant(id: "cfg-hist", name: "last config", projectCwd: app.settingsProject.cwd,
                  createdAt: Date())
        app.refreshHistory()
        XCTAssertEqual(app.rows(for: app.settingsProject).map(\.name), ["last config"])
    }

    // MARK: section-header collapse (view wiring)

    func testSectionCollapseHidesProjectRows() throws {
        let app = makeApp()
        let p = addProject(app)
        _ = p

        let sidebar = SidebarView(app: app)
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "rail.project.\(p.id)"))

        try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.section.projects").button().tap()
        XCTAssertTrue(app.collapsedSections.contains("projects"))
        XCTAssertThrowsError(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "rail.project.\(p.id)"),
                             "project rows are hidden once the section is collapsed")
    }

    // MARK: dead session rows leave the status slot blank ("every other state is hidden," the gray dot removed)

    func testDeadRowShowsNoStatusDot() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "dead-dot-check", name: "dead session", projectCwd: p.cwd, createdAt: Date())
        app.refreshHistory()

        let sidebar = SidebarView(app: app)
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.dead-dot-check"))
        XCTAssertThrowsError(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.dead-dot-check.status.dead"),
                             "dead session rows no longer show a gray dot — the status slot only expresses spinner/yellow-dot/unread-done")
    }

    // MARK: archive — rows move between their project group and the Archived section

    func testArchiveDeadRowMovesToArchivedSectionAndBack() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "arch-1", name: "row-one", projectCwd: p.cwd, createdAt: Date())
        app.refreshHistory()
        XCTAssertTrue(app.rows(for: p).contains { $0.name == "row-one" })
        XCTAssertTrue(app.archivedRows.isEmpty)

        app.setHistoryArchived("arch-1", true)
        XCTAssertFalse(app.rows(for: p).contains { $0.name == "row-one" },
                       "an archived row leaves its project group")
        XCTAssertEqual(app.archivedRows.map(\.name), ["row-one"])

        app.setHistoryArchived("arch-1", false)
        XCTAssertTrue(app.rows(for: p).contains { $0.name == "row-one" })
        XCTAssertTrue(app.archivedRows.isEmpty)
    }

    func testArchiveLiveSessionClosesProcessAndFlagsDir() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "live-task",
                                                 agent: "claude", access: .standard))
        let dir = vm.archiveDir
        let archiveId = (dir as NSString).lastPathComponent

        app.archiveSession(vm.id)
        XCTAssertTrue(app.allSessions.isEmpty, "archiving a live row closes the session first")
        XCTAssertEqual(SessionArchive.readMeta(dir: dir)?.archived, true)
        XCTAssertTrue(app.archivedRows.contains { $0.id == "dead-\(archiveId)" })
        XCTAssertFalse(app.rows(for: p).contains { $0.id == "dead-\(archiveId)" },
                       "the archived dir must not double-show in its project group")
    }

    func testResumeUnarchives() throws {
        let app = makeApp()
        let p = addProject(app)
        let dir = try plant(id: "arch-res", name: "revive-me", projectCwd: p.cwd,
                            createdAt: Date())
        var meta = try XCTUnwrap(SessionArchive.readMeta(dir: dir))
        meta.rootSessionId = "fake-sid"                    // resumable
        SessionArchive.writeMeta(meta, dir: dir)
        SessionArchive.setArchived(dir: dir, true)
        app.refreshHistory()

        let summary = try XCTUnwrap(app.history.first { $0.id == "arch-res" })
        app.resumeSession(summary)
        XCTAssertNotEqual(SessionArchive.readMeta(dir: dir)?.archived, true,
                          "reviving an archived session un-archives it")
        XCTAssertTrue(app.archivedRows.isEmpty)
        XCTAssertEqual(app.allSessions.count, 1, "the row is live again")
    }

    func testArchivedSectionViewWiring_unarchiveButtonReturnsRow() throws {
        let app = makeApp()
        let p = addProject(app)
        try plant(id: "arch-ui", name: "archived-ui", projectCwd: p.cwd, createdAt: Date())
        app.refreshHistory()
        app.setHistoryArchived("arch-ui", true)

        let sidebar = SidebarView(app: app)
        // The section header exists, carries NO accessory button, and the row sits in it
        // with an Unarchive (not Archive) hover action.
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.section.archived"))
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.arch-ui"))
        XCTAssertThrowsError(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.arch-ui.archive"),
                             "rows inside Archived must offer Unarchive, not Archive")

        // The button is hover-gated: un-hovered it must be visible to AX but NOT
        // tappable (phantom-click guard — allowsHitTesting(hover)). ViewInspector
        // reports exactly that; the hover+tap interaction itself is T2/axdriver
        // territory (honest skip — @State hover doesn't persist on un-hosted views).
        XCTAssertThrowsError(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.arch-ui.unarchive")
            .find(ViewType.Button.self).tap()) { err in
            XCTAssertTrue("\(err)".contains("allowsHitTesting"),
                          "expected the hover hit-test gate, got: \(err)")
        }

        // The un-archive round trip (model layer) — the same action the button fires.
        app.setHistoryArchived("arch-ui", false)
        XCTAssertTrue(app.archivedRows.isEmpty)
        XCTAssertTrue(app.rows(for: p).contains { $0.name == "archived-ui" })
        // Back in its project group the hover action is Archive again.
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.arch-ui.archive"))
    }

    // MARK: collapse past 5 + expand-all (view wiring)

    func testGroupCapsAtFiveWithExpandAllRow() throws {
        // The threshold comes from runtime.json (default 10) — this test
        // pins the "adjustability" itself: explicitly set it to 5, then plant 7 rows.
        RuntimeTuning.current.sidebarCollapseThreshold = 5
        addTeardownBlock { RuntimeTuning.current = .defaults }
        let app = makeApp()
        let p = addProject(app)
        for i in 0..<7 {
            try plant(id: "hist-\(i)", name: "dead session\(i)", projectCwd: p.cwd,
                      createdAt: Date(timeIntervalSinceNow: TimeInterval(-i * 60)))
        }
        app.refreshHistory()
        XCTAssertEqual(app.rows(for: p).count, 7)

        let sidebar = SidebarView(app: app)
        // Collapsed state: the 6th row (hist-5) isn't visible, the trailing row reads "Expand all (7)".
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.hist-0"))
        XCTAssertThrowsError(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.hist-5"))
        let expand = try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.group.\(p.id).showAll")
        XCTAssertNoThrow(try expand.find(text: "Show all (7)"))

        try expand.button().tap()
        XCTAssertTrue(p.showAllRows)
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.history.hist-6"))
        XCTAssertNoThrow(try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.group.\(p.id).showAll")
            .find(text: "Collapse"))
    }
}
