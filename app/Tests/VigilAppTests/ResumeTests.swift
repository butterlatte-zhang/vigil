import XCTest
import SwiftUI
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Click-to-resume app-layer wiring:
//   1) resumeSession(summary): when meta carries rootSessionId + projectCwd → spawn
//      another incarnation into the same archive dir (sessions never truly die),
//      the row returns to its project group and gets focused;
//   2) meta missing rootSessionId / projectCwd (old data, very short sessions) → fall
//      back to the read-only HistoryPane (never pretend resume is possible);
//   3) rest harvester: rest + unfocused + past-threshold duration → silent shutdown
//      into history.
// Test infra mirrors HistoryTests: VIGIL_UITEST=1 isolates persistence, the fake-agent
// seam runs the real stack.

@MainActor
final class ResumeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
        RuntimeTuning.current = .defaults   // tests mutate the global tuning; isolate
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
        let dir = NSTemporaryDirectory() + "vigil-resume-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: name, cwd: dir)
        app.projects.append(p)
        return p
    }

    /// A dead session left on disk by the previous app run; rootSessionId/projectCwd
    /// are set by the caller.
    @discardableResult
    private func plantArchivedSession(id: String, name: String,
                                      projectCwd: String?,
                                      rootSessionId: String?) throws -> String {
        let dir = VigilArchive.root + "/" + id
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"ts":"2026-07-07T10:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"old task"}"#
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: id, name: name, projectName: "Demo Project",
                               projectCwd: projectCwd, agent: "claude", model: nil,
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               rootSessionId: rootSessionId),
            dir: dir)
        return dir
    }

    // MARK: resume grafts the previous incarnation's tree skeleton + dead workers can be revived on demand

    func testResumeGraftsPreviousIncarnationTreeAndDerivesWorkerResumeKeys() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let dir = VigilArchive.root + "/20260707-080000-treetree"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Previous incarnation: root + two workers (n1 wrapped up naturally, n2 has no
        // terminal event = died along with the app); n1's session id goes the old route
        // (no session_id line) — it can only be derived from the transcript filename.
        try [
            #"{"ts":"2026-07-07T08:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"old root task"}"#,
            #"{"ts":"2026-07-07T08:01:00Z","event":"cell_launch","node":"n1","role":"leaf","root":false,"task":"old worker A","parent":"root"}"#,
            #"{"ts":"2026-07-07T08:01:10Z","event":"agent_prompt","node":"n1","transcript":"/tmp/x/587d2178-77e9-4359-8240-34767669deda.jsonl"}"#,
            #"{"ts":"2026-07-07T08:02:00Z","event":"cell_launch","node":"n2","role":"leaf","root":false,"task":"old worker B","parent":"root"}"#,
            #"{"ts":"2026-07-07T08:30:00Z","event":"exit","node":"n1","code":0}"#,
        ].map { $0 + "\n" }.joined()   // the last line must end with a newline — resume appends to the same file
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: "20260707-080000-treetree", name: "job with a tree",
                               projectName: p.name, projectCwd: p.cwd,
                               agent: "claude", model: nil,
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               rootSessionId: "sid-root"),
            dir: dir)
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)

        let vm = try XCTUnwrap(p.sessions.first)
        // The skeleton is back: dead workers enter the live tree in their terminal state (root alive, n1 done, n2 killed).
        XCTAssertEqual(vm.store.tree.count, 3)
        XCTAssertEqual(vm.store.tree[NodeID("n1")]?.status, .done)
        XCTAssertEqual(vm.store.tree[NodeID("n1")]?.title, "old worker A")
        XCTAssertEqual(vm.store.tree[NodeID("n2")]?.status, .killed)
        XCTAssertFalse(vm.store.tree.root.status.isTerminal, "live root is not overwritten by the previous incarnation")
        // Revival is per-node: n1's key can be derived from the transcript filename, so it
        // can be revived; n2 has no trace to follow = honestly cannot be.
        XCTAssertTrue(vm.canResume(NodeID("n1")))
        XCTAssertFalse(vm.canResume(NodeID("n2")))
        // The skeleton graft happens before observation registration, so
        // watchTreeForAutoExpand never sees a "change" — resume with a tree must expand
        // it directly.
        XCTAssertFalse(vm.treeCollapsed, "resume grafted a skeleton (count>1) → tree pane auto-expands")
    }

    /// Pressing Enter on a dead worker selected in the history view revives that node too,
    /// alongside the session (when its key is derivable); Enter's landing spot = the node
    /// you're currently viewing.
    func testResumeSessionWithFocusNodeRevivesThatWorker() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let dir = VigilArchive.root + "/20260707-081500-focusnod"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try [
            #"{"ts":"2026-07-07T08:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"old root task"}"#,
            #"{"ts":"2026-07-07T08:01:00Z","event":"cell_launch","node":"n1","role":"leaf","root":false,"task":"old worker A","parent":"root"}"#,
            #"{"ts":"2026-07-07T08:01:10Z","event":"agent_prompt","node":"n1","transcript":"/tmp/x/587d2178-77e9-4359-8240-34767669deda.jsonl"}"#,
            #"{"ts":"2026-07-07T08:30:00Z","event":"exit","node":"n1","code":0}"#,
        ].map { $0 + "\n" }.joined()
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: "20260707-081500-focusnod", name: "job with a worker",
                               projectName: p.name, projectCwd: p.cwd,
                               agent: "claude", model: nil,
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               rootSessionId: "sid-root"),
            dir: dir)
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary, focusNode: NodeID("n1"))

        let vm = try XCTUnwrap(p.sessions.first)
        XCTAssertEqual(vm.selectedID, NodeID("n1"))
        XCTAssertFalse(vm.store.tree[NodeID("n1")]!.status.isTerminal,
                       "n1 has a derivable key → revived in place (terminal state cleared, cell respawned)")
    }

    // MARK: resume's boot state must be honest (resuming an old conversation must not spin forever)

    /// State truth comes only from the turn hook: a claude that just resumed sits in
    /// its TUI waiting for input — no turn is running, Stop will never fire — so the boot
    /// state must be idle (rest), not the .running the launch path uses (that one closes
    /// the loop via "inject initial task → Stop", and resume has no such step).
    func testResumedSessionBootsIdleNotSpinning() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        try plantArchivedSession(id: "20260708-090000-idleboot", name: "old conversation",
                                 projectCwd: p.cwd, rootSessionId: "sid-root")
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)

        let vm = try XCTUnwrap(p.sessions.first)
        XCTAssertEqual(vm.store.tree.root.status, .idle,
                       "resume = turn closed, waiting on the user — must not spin forever")
        XCTAssertEqual(sessionIndicator(badge: vm.badge, tree: vm.store.tree), .rest)
        XCTAssertFalse(vm.completedUnseen, "resume boot leaves no unread blue badge")
    }

    /// Same story for a single revived node: after relaunch(.starting)→nodeOnline(.running)
    /// nothing flips the state further. A revived worker is likewise a TUI waiting for
    /// input — it must settle at idle.
    func testRevivedWorkerBootsIdleNotSpinning() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let dir = VigilArchive.root + "/20260708-091000-widleboo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try [
            #"{"ts":"2026-07-08T08:00:00Z","event":"cell_launch","node":"root","role":"manager","root":true,"task":"old root task"}"#,
            #"{"ts":"2026-07-08T08:01:00Z","event":"cell_launch","node":"n1","role":"leaf","root":false,"task":"old worker","parent":"root"}"#,
            #"{"ts":"2026-07-08T08:01:10Z","event":"agent_prompt","node":"n1","transcript":"/tmp/x/587d2178-77e9-4359-8240-34767669deda.jsonl"}"#,
            #"{"ts":"2026-07-08T08:30:00Z","event":"exit","node":"n1","code":0}"#,
        ].map { $0 + "\n" }.joined()
            .write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionArchive.writeMeta(
            SessionArchiveMeta(id: "20260708-091000-widleboo", name: "job with a worker",
                               projectName: p.name, projectCwd: p.cwd,
                               agent: "claude", model: nil,
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                               rootSessionId: "sid-root"),
            dir: dir)
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary, focusNode: NodeID("n1"))

        let vm = try XCTUnwrap(p.sessions.first)
        XCTAssertEqual(vm.store.tree[NodeID("n1")]?.status, .idle,
                       "a revived worker is also a TUI waiting for input — must not spin forever")
    }

    // MARK: a normal root exit archives the session into history state

    /// Wait for the observation callback to cross the MainActor Task hop (withObservationTracking → Task).
    private func waitUntil(_ cond: @autoclosure () -> Bool) async throws {
        for _ in 0..<200 where !cond() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testRootCleanExitArchivesSessionAndShowsHistory() async throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "finish and leave",
                                                 agent: "claude", access: .standard))
        let archiveId = (vm.archiveDir as NSString).lastPathComponent
        XCTAssertEqual(app.activeSessionID, vm.id)

        vm.store.send(.nodeExited(vm.store.tree.rootID, code: 0))   // clean exit, wraps up
        try await waitUntil(p.sessions.isEmpty)

        XCTAssertTrue(p.sessions.isEmpty, "clean root exit → session leaves the live list")
        XCTAssertTrue(app.history.contains { $0.id == archiveId }, "archived as a history row")
        XCTAssertEqual(app.selectedHistoryID, archiveId,
                       "you were watching it → the center pane seamlessly switches to the same archive's history view")
    }

    func testRootCrashStaysLiveForDiagnosis() async throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "job that crashes",
                                                 agent: "claude", access: .standard))

        vm.store.send(.nodeExited(vm.store.tree.rootID, code: 1))   // a crash ≠ wrapping up
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(p.sessions.first?.id, vm.id,
                       "a failed root does not auto-archive — the dead-node pane keeps a frozen frame for diagnosis")
    }

    func testRootExitReapsWorkersAndArchives() async throws {
        // Root dying means the subtree is reaped (orphan prevention) — so even if a
        // worker is still running when root exits cleanly, the whole tree still ends up
        // terminal and the session still archives immediately.
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "job with a worker",
                                                 agent: "claude", access: .standard))
        // A real spawn of a worker (goes through the Command path; the cell is a fake agent).
        vm.store.send(.requestStruct(.spawn(parent: vm.store.tree.rootID, role: .leaf,
                                            task: "worker job"),
                                     from: vm.store.tree.rootID, replyID: UUID()))
        let worker = try XCTUnwrap(vm.store.tree.root.children.first)
        vm.store.send(.nodeOnline(worker))

        vm.store.send(.nodeExited(vm.store.tree.rootID, code: 0))
        try await waitUntil(p.sessions.isEmpty)
        XCTAssertTrue(p.sessions.isEmpty, "root wraps up (worker reaped) → whole tree terminal → archived")
        XCTAssertTrue(app.history.contains {
            $0.id == (vm.archiveDir as NSString).lastPathComponent
        })
    }

    // MARK: clicking a dead session = respawning into the same archive dir

    func testResumeSessionRelaunchesIntoSameArchiveDir() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let dir = try plantArchivedSession(id: "20260707-090000-aaaaaaaa", name: "last night's job",
                                           projectCwd: p.cwd, rootSessionId: "sid-old")
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)

        let vm = try XCTUnwrap(p.sessions.first, "after resume the row returns to its project group")
        XCTAssertEqual(vm.archiveDir, dir, "D-a session never dies: same archive dir, jsonl appends across incarnations")
        XCTAssertEqual(vm.name, "last night's job")
        XCTAssertEqual(vm.rootSessionId, "sid-old", "resume key first inherits from meta, then hook — newest wins")
        XCTAssertEqual(app.activeSessionID, vm.id)
        XCTAssertNil(app.selectedHistoryID)
        XCTAssertFalse(app.history.contains { $0.dir == dir }, "the revived dir leaves the history list")
        // meta's identity fields are preserved verbatim (createdAt = first creation, not the resume moment).
        XCTAssertEqual(vm.createdAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testResumeWithoutSessionIdFallsBackToHistoryPane() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        try plantArchivedSession(id: "20260707-090000-bbbbbbbb", name: "very short session",
                                 projectCwd: p.cwd, rootSessionId: nil)
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)

        XCTAssertEqual(app.selectedHistoryID, summary.id, "no resume key → read-only playback, never pretend resume is possible")
        XCTAssertTrue(p.sessions.isEmpty)
        XCTAssertNil(app.activeSessionID)
    }

    func testResumeTwiceFocusesTheLiveSessionInsteadOfForking() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        try plantArchivedSession(id: "20260707-090000-cccccccc", name: "job",
                                 projectCwd: p.cwd, rootSessionId: "sid-x")
        app.refreshHistory()
        let summary = try XCTUnwrap(app.history.first)

        app.resumeSession(summary)
        let first = try XCTUnwrap(p.sessions.first)
        app.activeSessionID = nil
        app.resumeSession(summary)                 // double-click / repeated click

        XCTAssertEqual(p.sessions.count, 1, "the same logical session never spawns two incarnations")
        XCTAssertEqual(app.activeSessionID, first.id)
    }

    // MARK: the rest harvester (silent shutdown, the automatic path once there's no exit entry point)

    func testHarvesterClosesRestSessionAfterThreshold() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "task",
                                                 agent: "claude", access: .standard))
        let dir = vm.archiveDir
        // The fake agent boots with root=running (live); turnEnded → idle = the rest indicator state.
        vm.store.send(.turnEnded(NodeID("root"), gen: nil))
        app.activeSessionID = nil                   // must be unfocused to be harvestable

        // The threshold comes from runtime.json (default 60min) — check both sides of the effective value.
        let after = AppModel.harvestAfter
        let t0 = Date()
        app.harvestRestSessions(now: t0)            // first look: records the rest start point, doesn't harvest
        XCTAssertFalse(p.sessions.isEmpty)
        app.harvestRestSessions(now: t0.addingTimeInterval(after - 60))
        XCTAssertFalse(p.sessions.isEmpty, "not harvested before the threshold")
        app.harvestRestSessions(now: t0.addingTimeInterval(after + 60))
        XCTAssertTrue(p.sessions.isEmpty, "rest sustained past threshold → silent harvest")
        XCTAssertTrue(app.history.contains { $0.dir == dir }, "after harvest the row exists as history")
    }

    func testHarvesterSparesFocusedAndNonRestSessions() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let focused = try XCTUnwrap(app.launchSession(in: p.id, task: "focused",
                                                      agent: "claude", access: .standard))
        focused.store.send(.turnEnded(NodeID("root"), gen: nil))          // rest, but focused
        let busy = try XCTUnwrap(app.launchSession(in: p.id, task: "still running",
                                                   agent: "claude", access: .standard))
        _ = busy                                                // running = live, not harvested
        app.activeSessionID = focused.id

        let t0 = Date()
        app.harvestRestSessions(now: t0)
        app.harvestRestSessions(now: t0.addingTimeInterval(31 * 60))

        XCTAssertEqual(p.sessions.count, 2, "neither the focused rest session nor the still-running session is harvested")
    }

    func testHarvesterRestClockResetsWhenSessionWakes() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "task",
                                                 agent: "claude", access: .standard))
        vm.store.send(.turnEnded(NodeID("root"), gen: nil))
        app.activeSessionID = nil

        let t0 = Date()
        app.harvestRestSessions(now: t0)
        vm.store.send(.turnStarted(NodeID("root")))             // woke up (new prompt)
        app.harvestRestSessions(now: t0.addingTimeInterval(20 * 60))   // live → clears the clock
        vm.store.send(.turnEnded(NodeID("root"), gen: nil))
        app.harvestRestSessions(now: t0.addingTimeInterval(31 * 60))   // only 11min into rest

        XCTAssertFalse(p.sessions.isEmpty, "woke up midway → rest clock resets, not harvested before the threshold")
    }

    // MARK: maxLiveSessions LRU eviction (spawning a new root over the cap → harvest the least-recently-active rest tree)

    /// Make a launched session settle into clean-rest (root idle, non-focused-eligible).
    private func makeRest(_ app: AppModel, _ p: ProjectVM, task: String) throws -> SessionVM {
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: task,
                                                 agent: "claude", access: .standard))
        vm.store.send(.turnEnded(NodeID("root"), gen: nil))   // running → idle = rest
        return vm
    }

    /// Make a launched session stuck in attention with NO live node (a dead spawn / a stalled tree).
    private func makeStuck(_ app: AppModel, _ p: ProjectVM, task: String) throws -> SessionVM {
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: task,
                                                 agent: "claude", access: .standard))
        vm.store.send(.turnEnded(NodeID("root"), gen: nil))   // no running node…
        vm.store.send(.spawnStalled(NodeID("root")))          // …but stalled = attention
        return vm
    }

    private func withCap(_ n: Int, _ stuckHours: Int = 24) {
        var t = RuntimeTuning.defaults
        t.maxLiveSessions = n
        t.harvestStuckAfterHours = stuckHours
        RuntimeTuning.current = t
    }

    func testCapEvictsOldestRestTree() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let a = try makeRest(app, p, task: "oldest")
        let b = try makeRest(app, p, task: "middle")
        let c = try makeRest(app, p, task: "newest")
        app.activeSessionID = nil                             // all are eviction-eligible

        // Stagger the rest clock: A enters rest first, then B, then C.
        let t0 = Date()
        app.harvestRestSessions(now: t0)                      // A/B/C all recorded at t0? No — all right now
        // To stagger them, wake each one up then let it rest again, to refresh a later restSince.
        b.store.send(.turnStarted(NodeID("root")))
        c.store.send(.turnStarted(NodeID("root")))
        app.harvestRestSessions(now: t0.addingTimeInterval(60))   // A stays at t0; B/C are live → cleared
        b.store.send(.turnEnded(NodeID("root"), gen: nil))
        app.harvestRestSessions(now: t0.addingTimeInterval(120))  // B recorded at t0+120; A still at t0
        c.store.send(.turnEnded(NodeID("root"), gen: nil))
        app.harvestRestSessions(now: t0.addingTimeInterval(180))  // C recorded at t0+180

        withCap(2)                                            // 3 live trees > cap of 2 → evict 1
        let aDir = a.archiveDir
        app.enforceLiveSessionCap(now: t0.addingTimeInterval(200))

        XCTAssertEqual(p.sessions.count, 2, "over the cap → evict one tree")
        XCTAssertFalse(p.sessions.contains { $0.id == a.id }, "the evicted one is A, the least-recently-active")
        XCTAssertTrue(p.sessions.contains { $0.id == b.id })
        XCTAssertTrue(p.sessions.contains { $0.id == c.id })
        XCTAssertTrue(app.history.contains { $0.dir == aDir }, "eviction = silent harvest, the row stays in history and can be resumed")
    }

    func testCapNeverEvictsLiveOrAttentionOrFocusedTree() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let live = try XCTUnwrap(app.launchSession(in: p.id, task: "running",
                                                   agent: "claude", access: .standard))
        _ = live                                              // root running = a live tree, a red line, never evicted
        let stuck = try makeStuck(app, p, task: "stalled job")        // an attention tree, not evicted
        let focused = try makeRest(app, p, task: "focused rest")
        app.activeSessionID = focused.id                      // a focused rest tree isn't evicted either

        withCap(1)                                            // 3 > 1, but nothing matches "unfocused rest with no live node" to evict
        app.enforceLiveSessionCap(now: Date())

        XCTAssertEqual(p.sessions.count, 3, "live tree / attention tree / focused tree are never evicted — a selling-point red line")
    }

    func testCapBypassWhenNonPositive() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        _ = try makeRest(app, p, task: "one")
        _ = try makeRest(app, p, task: "two")
        _ = try makeRest(app, p, task: "three")
        app.activeSessionID = nil

        withCap(0)                                            // 0 = unlimited → bypass
        app.enforceLiveSessionCap(now: Date())
        XCTAssertEqual(p.sessions.count, 3, "maxLiveSessions<=0 evicts no session")
    }

    /// The LRU clock settles its books after eviction: an evicted tree moves into history
    /// (no longer a live session), and later sweeps don't revive its timer.
    func testCapClearsRestClockOnEviction() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let a = try makeRest(app, p, task: "evicted")
        let b = try makeRest(app, p, task: "kept")
        app.activeSessionID = nil
        let t0 = Date()
        app.harvestRestSessions(now: t0)
        b.store.send(.turnStarted(NodeID("root")))
        app.harvestRestSessions(now: t0.addingTimeInterval(60))   // A stays at t0, the oldest
        b.store.send(.turnEnded(NodeID("root"), gen: nil))

        withCap(1)
        app.enforceLiveSessionCap(now: t0.addingTimeInterval(120))
        XCTAssertFalse(p.sessions.contains { $0.id == a.id }, "oldest A is evicted")
        // Bookkeeping check: one more sweep must not crash and must not wrongly touch the surviving B (A's restSince was cleared when it was evicted).
        app.harvestRestSessions(now: t0.addingTimeInterval(180))
        XCTAssertEqual(p.sessions.count, 1)
        XCTAssertTrue(p.sessions.contains { $0.id == b.id })
    }

    // MARK: harvestStuckAfterHours fallback (force-harvest stalled/attention trees hung far too long)

    func testStuckTreeHarvestedAfterFallbackTimeout() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        let vm = try makeStuck(app, p, task: "dead spawn")
        let dir = vm.archiveDir
        app.activeSessionID = nil
        withCap(0, 24)                                        // cap off, 24h fallback on

        let after = AppModel.harvestStuckAfter               // 24h in seconds
        let t0 = Date()
        app.harvestRestSessions(now: t0)                     // records the stall start point, doesn't harvest
        XCTAssertFalse(p.sessions.isEmpty)
        app.harvestRestSessions(now: t0.addingTimeInterval(after - 3600))
        XCTAssertFalse(p.sessions.isEmpty, "not harvested before the fallback threshold")
        app.harvestRestSessions(now: t0.addingTimeInterval(after + 3600))
        XCTAssertTrue(p.sessions.isEmpty, "stalled past fallback threshold → force-harvest")
        XCTAssertTrue(app.history.contains { $0.dir == dir }, "fallback harvest likewise stays in history")
    }

    func testStuckHarvestNeverTouchesLiveTree() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        // root running (live) + one stalled child node → indicator state attention, but the tree still has a live node.
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "running with a stalled child",
                                                 agent: "claude", access: .standard))
        var arch = Tree(root: Node(id: NodeID("old"), role: .manager))
        try arch.spawn(parent: NodeID("old"),
                       child: Node(id: NodeID("n1"), role: .leaf, status: .idle))
        vm.store.send(.restoreSkeleton(arch))
        vm.store.send(.spawnStalled(NodeID("n1")))           // the child is stalled; root is still running
        app.activeSessionID = nil
        withCap(0, 24)

        let t0 = Date()
        app.harvestRestSessions(now: t0)
        app.harvestRestSessions(now: t0.addingTimeInterval(AppModel.harvestStuckAfter * 2))
        XCTAssertEqual(p.sessions.count, 1, "a tree with a running/starting node is never fallback-harvested — a selling-point red line")
    }

    func testStuckHarvestDisabledWhenNonPositive() throws {
        try assertFakeSeamActive()
        let app = makeApp()
        let p = addProject(app)
        _ = try makeStuck(app, p, task: "stalled with fallback off")
        app.activeSessionID = nil
        withCap(0, 0)                                         // harvestStuckAfterHours = 0 → off

        let t0 = Date()
        app.harvestRestSessions(now: t0)
        app.harvestRestSessions(now: t0.addingTimeInterval(100 * 3600))
        XCTAssertEqual(p.sessions.count, 1, "harvestStuckAfterHours<=0 disables fallback harvest")
    }
}
