import XCTest
import SwiftUI
import ViewInspector
import Darwin
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Codex-style bottom terminal panel. Four families, all deterministic:
//   A) BottomShell model lifecycle on a SPY backend (start/terminate/natural-exit) — no fork;
//   B) SessionVM wiring: toggle show/hide keeps the process, × ends it, shutdown ends it,
//      and the harvester-exemption invariant (the shell is NOT a tree node, so it can never
//      change what the rest harvester sees);
//   C) view wiring (ViewInspector): top.termToggle present + flips state, bottom.terminal
//      appears/disappears with visibility;
//   D) ONE real-fork integration test proving the host-PTY chain the shell rides actually
//      spawns and reaps a live `$SHELL` — PID recorded from a pidfile and reaped by that exact
//      PID (process-hygiene iron law: never a by-name kill).
@MainActor
final class BottomShellTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
        AgentNotice.permissionGrace = 2.5
    }

    private var apps: [AppModel] = []
    /// Real child PIDs the real-fork test forked; reaped by EXACT pid in tearDown as a
    /// belt-and-suspenders (the backend already killpg's its own child).
    private var forkedPIDs: [pid_t] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        for pid in forkedPIDs where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        forkedPIDs.removeAll()
        super.tearDown()
    }

    // MARK: - spy backend

    /// Records start/terminate calls without forking. `simulateExit()` drives the natural-death
    /// path (the child exiting on its own, e.g. the user typed `exit`).
    final class SpyBackend: TerminalBackend, @unchecked Sendable {
        private(set) var startCount = 0
        private(set) var terminateCount = 0
        private(set) var lastExecutable = ""
        private(set) var lastArgs: [String] = []
        private(set) var lastCwd = ""
        private var onEnd: ((Int32?) -> Void)?

        func start(executable: String, args: [String], env: [String: String], cwd: String,
                   onEnd: @escaping (Int32?) -> Void) {
            startCount += 1
            lastExecutable = executable; lastArgs = args; lastCwd = cwd
            self.onEnd = onEnd
        }
        func send(_ text: String) {}
        func renderScreen() -> String { "" }
        func renderAttributed() -> AttributedScreen { AttributedScreen(lines: []) }
        func terminate() { terminateCount += 1 }
        /// The child died on its own — fire the exit callback like a real backend would.
        func simulateExit() { onEnd?(0); onEnd = nil }
    }

    // MARK: - A. model lifecycle (spy)

    func testStart_forksLoginShellAtCwd_idempotent() {
        let spy = SpyBackend()
        let sh = BottomShell(cwd: "/tmp/proj", makeBackend: { spy })
        XCTAssertFalse(sh.running)
        sh.start()
        XCTAssertTrue(sh.running)
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.lastCwd, "/tmp/proj")
        // Login shell recipe: $SHELL (or the /bin/zsh fallback) with -l -i.
        XCTAssertEqual(spy.lastExecutable,
                       ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        XCTAssertEqual(spy.lastArgs, ["-l", "-i"])
        sh.start()                                   // re-open while running = no respawn
        XCTAssertEqual(spy.startCount, 1)
    }

    func testTerminate_endsProcess_nextStartIsFreshShell() {
        var spies: [SpyBackend] = []
        let sh = BottomShell(cwd: "/tmp", makeBackend: { let s = SpyBackend(); spies.append(s); return s })
        sh.start()
        XCTAssertTrue(sh.running)
        sh.terminate()
        XCTAssertFalse(sh.running)
        XCTAssertEqual(spies.count, 1)
        XCTAssertEqual(spies[0].terminateCount, 1)
        sh.start()                                   // × then re-open = a brand-new backend
        XCTAssertTrue(sh.running)
        XCTAssertEqual(spies.count, 2)
        XCTAssertEqual(spies[1].startCount, 1)
    }

    func testNaturalExit_firesOnEnded_andDropsBackend() {
        let spy = SpyBackend()
        let sh = BottomShell(cwd: "/tmp", makeBackend: { spy })
        var ended = 0
        sh.onEnded = { ended += 1 }
        sh.start()
        spy.simulateExit()
        pump(0.05)                                    // onEnd hops through Task { @MainActor }
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(sh.running)
    }

    // MARK: - B. SessionVM wiring

    private func makeSession() -> SessionVM {
        let vm = SessionVM(id: "bs-\(UUID().uuidString.prefix(6))", name: "t",
                           rootCwd: NSTemporaryDirectory(), initialTask: "task")
        return vm
    }

    func testToggle_showStartsShell_hideKeepsProcess() {
        let vm = makeSession(); defer { vm.shutdown() }
        var spies: [SpyBackend] = []
        vm.makeBottomShellBackend = { let s = SpyBackend(); spies.append(s); return s }

        XCTAssertFalse(vm.bottomShellVisible)
        vm.toggleBottomShell()                        // show
        XCTAssertTrue(vm.bottomShellVisible)
        XCTAssertEqual(spies.count, 1)
        XCTAssertEqual(spies[0].startCount, 1)

        vm.toggleBottomShell()                        // hide — process stays alive
        XCTAssertFalse(vm.bottomShellVisible)
        XCTAssertEqual(spies[0].terminateCount, 0, "hiding must NOT kill the shell")

        vm.toggleBottomShell()                        // show again — same backend, no respawn
        XCTAssertTrue(vm.bottomShellVisible)
        XCTAssertEqual(spies.count, 1, "re-show reuses the live shell")
        XCTAssertEqual(spies[0].startCount, 1)
    }

    func testClose_endsShellAndPanel_reopenIsFresh() {
        let vm = makeSession(); defer { vm.shutdown() }
        var spies: [SpyBackend] = []
        vm.makeBottomShellBackend = { let s = SpyBackend(); spies.append(s); return s }

        vm.toggleBottomShell()
        vm.closeBottomShell()                         // × button
        XCTAssertFalse(vm.bottomShellVisible)
        XCTAssertEqual(spies[0].terminateCount, 1)

        vm.toggleBottomShell()                        // reopen = new shell
        XCTAssertEqual(spies.count, 2)
        XCTAssertEqual(spies[1].startCount, 1)
    }

    func testShutdown_terminatesShell() {
        let vm = makeSession()
        let spy = SpyBackend()
        vm.makeBottomShellBackend = { spy }
        vm.toggleBottomShell()
        vm.shutdown()                                 // session close/archive/harvest → shell dies with it
        XCTAssertEqual(spy.terminateCount, 1)
    }

    /// Harvester-exemption invariant: the shell is NOT a tree node, so it can never add a live
    /// node or change the session indicator the harvester reads — opening it is invisible to
    /// the reap decision (the "exempt from the 30-min reaper" rule, by construction).
    func testBottomShell_isInvisibleToHarvester() {
        let vm = makeSession(); defer { vm.shutdown() }
        vm.makeBottomShellBackend = { SpyBackend() }
        let nodesBefore = vm.store.tree.nodes.count
        let indBefore = sessionIndicator(badge: vm.badge, tree: vm.store.tree)

        vm.toggleBottomShell()

        XCTAssertEqual(vm.store.tree.nodes.count, nodesBefore, "shell must add NO tree node")
        XCTAssertEqual(sessionIndicator(badge: vm.badge, tree: vm.store.tree), indBefore,
                       "shell must not change the harvester's indicator input")
    }

    // MARK: - C. view wiring (ViewInspector)

    private func makeApp() -> AppModel { let a = AppModel(); apps.append(a); return a }

    @discardableResult
    private func addProject(_ app: AppModel) -> ProjectVM {
        let dir = NSTemporaryDirectory() + "vigil-bs-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: "Demo", cwd: dir)
        app.projects.append(p)
        return p
    }

    @discardableResult
    private func launch(_ app: AppModel, _ p: ProjectVM) throws -> SessionVM {
        XCTAssertEqual(UITestSupport.fakeAgentCommand, WiringTests.stubScript,
                       "fake-agent seam inactive — refusing a real launch")
        let vm = try XCTUnwrap(app.launchSession(in: p.id, task: "task", agent: "claude"))
        vm.makeBottomShellBackend = { SpyBackend() }   // no fork, no real ghostty view in wiring tests
        return vm
    }

    func testTermToggle_presentAndFlipsState() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let body = AppBody(app: app)

        XCTAssertNoThrow(try body.inspect().find(viewWithAccessibilityIdentifier: "top.termToggle"))
        XCTAssertFalse(vm.bottomShellVisible)
        try body.inspect()
            .find(ViewType.Button.self, where: { (try? $0.accessibilityIdentifier()) == "top.termToggle" })
            .tap()
        XCTAssertTrue(vm.bottomShellVisible)
    }

    func testPanel_appearsWhenVisible_disappearsWhenHidden() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)

        // Hidden by default → no panel (snapshots of the closed state stay unchanged).
        XCTAssertThrowsError(try AppBody(app: app).inspect()
            .find(viewWithAccessibilityIdentifier: "bottom.terminal"))

        vm.toggleBottomShell()
        XCTAssertNoThrow(try AppBody(app: app).inspect()
            .find(viewWithAccessibilityIdentifier: "bottom.terminal"))
        XCTAssertNoThrow(try AppBody(app: app).inspect()
            .find(viewWithAccessibilityIdentifier: "bottom.terminal.close"))

        vm.toggleBottomShell()                        // hide
        XCTAssertThrowsError(try AppBody(app: app).inspect()
            .find(viewWithAccessibilityIdentifier: "bottom.terminal"))
    }

    /// The × button is wired to closeBottomShell (ends the shell + closes the panel).
    func testCloseButton_endsShell() throws {
        let app = makeApp()
        let p = addProject(app)
        let vm = try launch(app, p)
        let spy = SpyBackend()
        vm.makeBottomShellBackend = { spy }
        vm.toggleBottomShell()

        try AppBody(app: app).inspect()
            .find(ViewType.Button.self, where: { (try? $0.accessibilityIdentifier()) == "bottom.terminal.close" })
            .tap()
        XCTAssertFalse(vm.bottomShellVisible)
        XCTAssertEqual(spy.terminateCount, 1)
    }

    // MARK: - D. real fork (host-PTY chain) — records PID, reaps by exact PID

    /// Proves the exact backend chain BottomShell rides (HostPTY + libghostty-vt, via
    /// HeadlessBackend — the surface-less twin of the production GhosttyViewBackend) forks a
    /// live `$SHELL` and that terminate() reaps it. The shell writes its own pid to a file
    /// (`$$` survives the `exec`), which we record and reap by exact pid in tearDown — never a
    /// by-name kill.
    func testRealShell_forksAndTerminates() throws {
        let dir = NSTemporaryDirectory() + "vigil-bs-fork-\(getpid())-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let pidfile = dir + "/pid"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let backend = HeadlessBackend(cols: 80, rows: 24)
        let exited = expectation(description: "child reaped")
        backend.start(executable: shell,
                      args: ["-c", "echo $$ > '\(pidfile)'; exec cat"],
                      env: ["TERM": "xterm-256color",
                            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                      cwd: dir) { _ in exited.fulfill() }

        // Wait for the shell to publish its pid.
        var pid: pid_t = -1
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: pidfile, encoding: .utf8),
               let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
                pid = p; break
            }
            pump(0.05)
        }
        XCTAssertGreaterThan(pid, 0, "shell never published its pid — fork failed")
        forkedPIDs.append(pid)                        // reap-by-pid safety net
        XCTAssertEqual(kill(pid, 0), 0, "forked shell must be alive")

        backend.terminate()                           // the × path — killpg the exact child
        wait(for: [exited], timeout: 5)
        // Give the OS a beat to finish reaping, then the pid must be gone (ESRCH).
        var gone = false
        let d2 = Date(timeIntervalSinceNow: 3)
        while Date() < d2 { if kill(pid, 0) != 0 { gone = true; break }; pump(0.05) }
        XCTAssertTrue(gone, "terminate() must reap the shell process")
    }

    // MARK: - pumping

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
