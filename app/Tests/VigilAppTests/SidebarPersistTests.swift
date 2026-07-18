import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// All sidebar collapse/expand/selection state must persist and survive an app relaunch.
// Carrier = SidebarUIRecord (per-project expanded / show-all, current project, selected
// row, whole-rail collapsed); snapshot/replay is pure logic (T1a testable); UserDefaults
// reads/writes reuse railWidth's existing seam (UITest mode never touches real defaults),
// so this file tests the snapshot/apply round trip directly rather than the disk.

@MainActor
final class SidebarPersistTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // UITestSupport.env is a static let that freezes on first access — must stay in sync with the other test classes.
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
    private func addProject(_ app: AppModel, id: String, name: String = "Demo Project") -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-persist-proj-\(id)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: id, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    @discardableResult
    private func plantArchive(_ app: AppModel, id: String, projectCwd: String) throws -> String {
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"t"}"#
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: "history session", projectName: nil,
                               projectCwd: projectCwd, agent: "claude", model: nil,
                               createdAt: Date()),
            dir: dir)
        return dir
    }

    // MARK: snapshot — capture all fold/selection state in full

    func testSnapshotCapturesFoldsAndSelection() {
        let app = makeApp()
        let p1 = addProject(app, id: "p1")
        let p2 = addProject(app, id: "p2")

        app.toggleProjectExpanded(p1)          // p1 collapsed
        app.toggleShowAllRows(p2)              // p2 show all
        app.selectProject(p2.id)
        app.toggleSidebar()                    // whole rail collapsed

        let r = app.sidebarUISnapshot()
        XCTAssertEqual(r.collapsedProjects, ["p1"])
        XCTAssertEqual(r.showAllProjects, ["p2"])
        XCTAssertEqual(r.currentProjectID, "p2")
        XCTAssertTrue(r.railCollapsed)
        XCTAssertNil(r.selectedArchiveID, "no selected row → nothing recorded")
    }

    func testSnapshotRecordsActiveSessionAsItsArchiveID() throws {
        // After a restart, a live session becomes that history row (archive dir name =
        // history id) — the selection state carries over through this.
        let app = makeApp()
        let p = addProject(app, id: "p1")
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "active",
                                                 agent: "claude", access: .standard))
        XCTAssertEqual(app.sidebarUISnapshot().selectedArchiveID,
                       (vm.archiveDir as NSString).lastPathComponent)
    }

    func testSnapshotRecordsHistorySelection() throws {
        let app = makeApp()
        let p = addProject(app, id: "p1")
        try plantArchive(app, id: "20260708-090000-persist1", projectCwd: p.cwd)
        app.refreshHistory()
        app.openHistory("20260708-090000-persist1")
        XCTAssertEqual(app.sidebarUISnapshot().selectedArchiveID, "20260708-090000-persist1")
    }

    // MARK: apply — replay after a restart

    func testApplyRestoresFoldsAndSelection() {
        let app = makeApp()
        addProject(app, id: "p1")
        let p2 = addProject(app, id: "p2")

        var r = SidebarUIRecord()
        r.collapsedProjects = ["p1"]
        r.showAllProjects = ["p2"]
        r.currentProjectID = "p2"
        r.railCollapsed = true
        app.applySidebarUI(r)

        XCTAssertFalse(app.projects.first { $0.id == "p1" }!.expanded)
        XCTAssertTrue(p2.expanded)
        XCTAssertTrue(p2.showAllRows)
        XCTAssertEqual(app.currentProjectID, "p2")
        XCTAssertNil(app.activeSessionID, "a restored project selection lands on the launcher")
        XCTAssertTrue(app.railCollapsed)
    }

    func testApplyRestoresHistorySelection() throws {
        let app = makeApp()
        let p = addProject(app, id: "p1")
        try plantArchive(app, id: "20260708-090000-persist2", projectCwd: p.cwd)
        app.refreshHistory()

        var r = SidebarUIRecord()
        r.currentProjectID = "p1"
        r.selectedArchiveID = "20260708-090000-persist2"
        app.applySidebarUI(r)

        XCTAssertEqual(app.selectedHistoryID, "20260708-090000-persist2",
                       "the selected history row is restored after a restart")
        XCTAssertNotNil(app.historyArchive, "openHistory loads the archive in sync")
    }

    func testApplyIgnoresStaleIDs() {
        // A project removed, an archive cleaned up → stale ids are all silently ignored,
        // no crash and no pretending.
        let app = makeApp()
        addProject(app, id: "p1")

        var r = SidebarUIRecord()
        r.collapsedProjects = ["gone-project"]
        r.currentProjectID = "gone-project"
        r.selectedArchiveID = "gone-archive"
        app.applySidebarUI(r)

        XCTAssertNil(app.currentProjectID)
        XCTAssertNil(app.selectedHistoryID)
        XCTAssertTrue(app.projects.first { $0.id == "p1" }!.expanded, "unrelated projects are unaffected")
    }

    func testApplyThenSnapshotRoundTrips() {
        let app = makeApp()
        addProject(app, id: "p1")
        addProject(app, id: "p2")
        var r = SidebarUIRecord()
        r.collapsedProjects = ["p2"]
        r.showAllProjects = ["p1"]
        r.currentProjectID = "p1"
        r.railCollapsed = true
        app.applySidebarUI(r)
        XCTAssertEqual(app.sidebarUISnapshot(), r, "apply→snapshot lossless round trip")
    }

    // MARK: view wiring — fold changes must go through AppModel (iron rule + persistence hook)

    func testExpandAllRowGoesThroughAppModel() throws {
        RuntimeTuning.current.sidebarCollapseThreshold = 5   // threshold is tunable, pinned at 5
        addTeardownBlock { RuntimeTuning.current = .defaults }
        let app = makeApp()
        let p = addProject(app, id: "p1")
        for i in 0..<6 {
            _ = try plantArchive(app, id: "hist-\(i)", projectCwd: p.cwd)
        }
        app.refreshHistory()

        let sidebar = SidebarView(app: app)
        try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "side.group.p1.showAll").button().tap()
        XCTAssertTrue(p.showAllRows)
        XCTAssertEqual(app.sidebarUISnapshot().showAllProjects, ["p1"])
    }

    func testProjectChevronToggleGoesThroughAppModel() throws {
        let app = makeApp()
        let p = addProject(app, id: "p1")
        app.selectProject(p.id)

        let sidebar = SidebarView(app: app)
        try sidebar.inspect()
            .find(viewWithAccessibilityIdentifier: "rail.project.p1").button().tap()
        XCTAssertFalse(p.expanded, "already the current project → click = collapse")
        XCTAssertEqual(app.sidebarUISnapshot().collapsedProjects, ["p1"])
    }
}
