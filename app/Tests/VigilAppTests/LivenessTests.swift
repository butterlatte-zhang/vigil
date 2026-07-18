import XCTest
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Cross-app-instance session liveness coordination (liveness lock) — app-layer wiring.
//
// The scenario this guards against: two Vigil instances share one archive root; the second
// resumes a session the first still drives → two roots into ONE orchestration.jsonl (split
// brain). The gate: a live.lock ({pid, heartbeat}) in the session dir. resumeSession refuses
// while the lock is live (pid alive + heartbeat fresh) and falls back to read-only playback;
// a crashed instance's stale lock self-heals so nothing wedges. The guard assertion here is
// the exact regression: a REFUSED resume must NOT append a second root cell_launch to the
// jsonl.
//
// Test infra mirrors ResumeTests: VIGIL_UITEST=1 isolates persistence, the fake-agent seam
// runs the real stack without a real claude.
@MainActor
final class LivenessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
        RuntimeTuning.current = .defaults
    }

    private var apps: [AppModel] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        try? FileManager.default.removeItem(atPath: VigilArchive.root)
        super.tearDown()
    }

    private func assertFakeSeamActive() throws {
        guard UITestSupport.fakeAgentCommand == WiringTests.stubScript else {
            XCTFail("fake-agent seam inactive — refusing to launch a real agent")
            throw NSError(domain: "seam", code: 1)
        }
    }

    private func makeApp() -> AppModel {
        let app = AppModel()
        apps.append(app)
        return app
    }

    @discardableResult
    private func addProject(_ app: AppModel, name: String = "Demo Project") -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-liveness-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    /// One dead session on disk: a single root cell_launch line + meta with a resume key.
    @discardableResult
    private func plantArchivedSession(id: String, projectCwd: String) throws -> String {
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try (#"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"old task"}"# + "\n")
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: "last night's job", projectName: "Demo Project",
                               projectCwd: projectCwd, agent: "claude", model: nil,
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               rootSessionId: "sid-old"),
            dir: dir)
        return dir
    }

    /// Count root cell_launch lines in a session's jsonl — the split-brain detector.
    private func rootLaunchCount(_ dir: String) -> Int {
        guard let raw = try? String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        else { return 0 }
        return raw.split(separator: "\n").filter { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return false }
            return obj["event"] as? String == "cell_launch" && obj["root"] as? Bool == true
        }.count
    }

    // MARK: verdict primitive

    func testSessionLivenessVerdict() throws {
        let app = makeApp()
        let dir = try plantArchivedSession(id: "20260707-090000-verdictt",
                                           projectCwd: addProject(app).cwd)
        XCTAssertEqual(app.sessionLiveness(dir: dir), .free, "no lock = resumable")
        SessionLock.write(dir: dir, pid: getpid(), now: Date())
        XCTAssertEqual(app.sessionLiveness(dir: dir), .heldElsewhere, "live lock = held")
        SessionLock.write(dir: dir, pid: getpid(), now: Date().addingTimeInterval(-600))
        XCTAssertEqual(app.sessionLiveness(dir: dir), .free, "expired heartbeat = stale lock self-heals")
    }

    // MARK: guard — a refused resume must NOT fork a second root into the jsonl

    func testResumeRefusedWhileLockedElsewhere() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let dir = try plantArchivedSession(id: "20260707-090000-locked01", projectCwd: p.cwd)
        // Another live instance holds it: a live pid (this test process) + fresh heartbeat.
        SessionLock.write(dir: dir, pid: getpid(), now: Date())
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)

        XCTAssertTrue(p.sessions.isEmpty, "live lock → resume refused, no incarnation spawned")
        XCTAssertNil(app.activeSessionID)
        XCTAssertEqual(app.selectedHistoryID, summary.id, "falls back to read-only playback (playback is unaffected)")
        // Guard assertion: NO second root cell_launch(resume) was appended.
        XCTAssertEqual(rootLaunchCount(dir), 1,
                       "a refused resume must never write a second root cell_launch into the same orchestration.jsonl")
    }

    // MARK: self-heal — a stale lock (crashed holder) never blocks resume

    func testResumeProceedsWhenLockStale() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let dir = try plantArchivedSession(id: "20260707-090000-stale001", projectCwd: p.cwd)
        // Crashed instance: heartbeat far past staleness (pid may even be alive/recycled).
        SessionLock.write(dir: dir, pid: getpid(), now: Date().addingTimeInterval(-3600))
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)

        let vm = try XCTUnwrap(p.sessions.first, "stale lock self-heals → resume proceeds normally")
        XCTAssertEqual(vm.archiveDir, dir)
        XCTAssertEqual(app.activeSessionID, vm.id)
        // Legit second incarnation DID fork a fresh root launch into the same dir.
        XCTAssertEqual(rootLaunchCount(dir), 2, "a legit revival = a second root cell_launch")
    }

    // MARK: end-to-end lock lifecycle — start writes it, close removes it

    func testLiveSessionHoldsThenReleasesLock() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "placeholder job",
                                                 agent: "claude", access: .standard))
        XCTAssertTrue(SessionLock.isLive(dir: vm.archiveDir),
                      "session boot writes a live lock (this process pid + fresh heartbeat)")
        let dir = vm.archiveDir

        app.closeSession(vm.id)
        XCTAssertNil(SessionLock.read(dir: dir), "closeSession → clears the lock, resume immediately allowed")
    }

    // MARK: a session already live IN THIS instance is focused, never lock-refused

    func testResumeOfOwnLiveSessionFocusesNotRefused() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "own job",
                                                 agent: "claude", access: .standard))
        // Our own lock is live — but the caller short-circuits on archiveDir before the gate.
        let summary = ArchivedSessionSummary(id: (vm.archiveDir as NSString).lastPathComponent,
                                             dir: vm.archiveDir, meta: nil, modifiedAt: nil)
        app.activeSessionID = nil
        app.resumeSession(summary)

        XCTAssertEqual(app.activeSessionID, vm.id, "own live session = focused, never refused by the live lock")
        XCTAssertEqual(p.sessions.count, 1, "no second incarnation spawned")
        XCTAssertNil(app.selectedHistoryID)
    }
}
