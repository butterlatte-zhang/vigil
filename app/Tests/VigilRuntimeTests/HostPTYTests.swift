import XCTest
@testable import VigilRuntime

/// The host-managed PTY driver, fully headless (no surface/Metal), exercised end-to-end
/// by real forkpty'd child processes. Everything here runs under plain `swift test`; that
/// is the whole point — pin the forkpty/exec/reap risk in a GUI-less CI.
final class HostPTYTests: XCTestCase {

    /// Thread-safe sink: HostPTY fires onData/onExit from background queues/threads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        private var _exitCode: Int32?
        private var _exitCount = 0

        func onData(_ d: Data) { lock.lock(); _data.append(d); lock.unlock() }
        func onExit(_ c: Int32?) { lock.lock(); _exitCode = c; _exitCount += 1; lock.unlock() }

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: _data, as: UTF8.self) }
        var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return _exitCode }
        var exitCount: Int { lock.lock(); defer { lock.unlock() }; return _exitCount }
        var exited: Bool { lock.lock(); defer { lock.unlock() }; return _exitCount > 0 }
    }

    /// A shell-visible env: absolute-path execs don't need PATH, but `sh -c '<tool>'`
    /// (stty/kill builtins-or-not) resolves via PATH — keep it real.
    private let env = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]

    /// CI slow-machine timing gate (mirrors RealCellTests.waitUntil): poll until the condition
    /// holds or the deadline passes — never a fixed sleep.
    private func waitUntil(_ deadline: TimeInterval = 5, _ cond: () -> Bool) {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // 1) A normal command's stdout reaches onData and its 0 exit reaches onExit.
    func testEchoDataAndCleanExit() {
        let pty = HostPTY(), c = Collector()
        pty.start(executable: "/bin/echo", args: ["hello"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertTrue(c.text.contains("hello"), "stdout not pumped: \(c.text.debugDescription)")
        XCTAssertEqual(c.exitCode, 0)
        XCTAssertEqual(c.exitCount, 1)
    }

    // 2) A non-zero exit code is decoded via WIFEXITED/WEXITSTATUS.
    func testNonZeroExitCode() {
        let pty = HostPTY(), c = Collector()
        pty.start(executable: "/bin/sh", args: ["-c", "exit 5"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertEqual(c.exitCode, 5)
    }

    // 3) Death by signal → onExit(nil) (WIFSIGNALED), matching terminate() semantics.
    func testSignalDeathIsNil() {
        let pty = HostPTY(), c = Collector()
        pty.start(executable: "/bin/sh", args: ["-c", "kill -TERM $$"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertNil(c.exitCode, "signal death must report nil, got \(String(describing: c.exitCode))")
        XCTAssertEqual(c.exitCount, 1)
    }

    // 4) write() reaches the child: the tty line discipline echoes it straight back.
    func testWriteRoundTrip() {
        let pty = HostPTY(), c = Collector()
        pty.start(executable: "/bin/cat", args: [], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        pty.write(Data("ping\n".utf8))
        waitUntil { c.text.contains("ping") }
        XCTAssertTrue(c.text.contains("ping"), "write not echoed: \(c.text.debugDescription)")
        pty.terminate()
        waitUntil { c.exited }
        XCTAssertNil(c.exitCode)   // SIGKILL → signaled → nil
    }

    // 5) resize() sets TIOCSWINSZ: the child's stty sees the new rows/cols.
    func testResizeReflectedInChild() {
        let pty = HostPTY(), c = Collector()
        // stty runs after a beat so the resize below is in effect by then; we poll for
        // the value (no fixed test-side sleep — the delay is the child's, bounded by poll).
        pty.start(executable: "/bin/sh", args: ["-c", "sleep 0.2; stty size"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        pty.resize(cols: 100, rows: 40, widthPx: 800, heightPx: 480)
        waitUntil { c.text.contains("40 100") }
        XCTAssertTrue(c.text.contains("40 100"), "stty size mismatch: \(c.text.debugDescription)")
    }

    // 5b) a resize() BEFORE start() must NOT be dropped. The GhosttyBackend
    // resize event can fire during startOnMain's controller-assign — strictly BEFORE
    // pty.start() forks — while the master fd is still -1. If that size is discarded the
    // child forks at the 80×24 default and (because the surface caches lastResize, no
    // second event follows) stays there forever → resume paints an 80×24 box in the
    // top-left of a much larger surface. The pre-start size must seed the fork winsize.
    func testResizeBeforeStartSeedsForkSize() {
        let pty = HostPTY(), c = Collector()
        pty.resize(cols: 100, rows: 40, widthPx: 800, heightPx: 480)   // BEFORE start (fd == -1)
        pty.start(executable: "/bin/sh", args: ["-c", "stty size"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertTrue(c.text.contains("40 100"),
                      "pre-start resize dropped — child forked at wrong size: \(c.text.debugDescription)")
    }

    // 5c) With no resize at all, the fork falls back to the 24×80 default (unchanged behavior).
    func testDefaultForkSizeWhenNoResize() {
        let pty = HostPTY(), c = Collector()
        pty.start(executable: "/bin/sh", args: ["-c", "stty size"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertTrue(c.text.contains("24 80"),
                      "default fork size regressed: \(c.text.debugDescription)")
    }

    // 5d) fork-time seeding (above) covers a size known BEFORE forkpty runs. But the real
    // backend can push the authoritative grid AROUND the fork — after start() has read the
    // fork winsize yet before the master fd is valid. Such a resize sees fd < 0, so it only
    // updates pendingWinsize and never reaches the already-forked child; without a post-fork
    // re-assert the child would be stuck at the stale (small) fork size while the surface
    // renders full-width → content wraps in a left strip. The seam drives that exact race
    // deterministically: pendingWinsize must re-assert to the freshly-valid fd so the child
    // converges to the authoritative size.
    func testFreshResizeDuringForkReassertedToChild() {
        let pty = HostPTY(), c = Collector()
        pty.resize(cols: 60, rows: 20, widthPx: 480, heightPx: 320)   // pre-start "small" → fork seed
        pty._afterForkForTest = { [weak pty] in
            // fd is still -1 here → this only updates pendingWinsize; the fork already used 60×20.
            pty?.resize(cols: 140, rows: 40, widthPx: 2240, heightPx: 1480)   // authoritative grid
        }
        pty.start(executable: "/bin/sh", args: ["-c", "sleep 0.2; stty size"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.text.contains("40 140") || c.exited }
        XCTAssertTrue(c.text.contains("40 140"),
                      "post-fork authoritative size not re-asserted — child stuck at fork size: \(c.text.debugDescription)")
    }

    // 5e) a single pre-start resize with the real size and NO race around the fork must
    // still seed the fork so the child is correctly sized from birth — the post-fork
    // re-assert path must not disturb this simpler case.
    func testResumePreStartResizeSeedsForkSizeNoRegression() {
        let pty = HostPTY(), c = Collector()
        pty.resize(cols: 140, rows: 40, widthPx: 2240, heightPx: 1480)   // pre-start authoritative
        pty.start(executable: "/bin/sh", args: ["-c", "stty size"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertTrue(c.text.contains("40 140"),
                      "resume fork size regressed (#42 seeding disturbed): \(c.text.debugDescription)")
    }

    // 5f) nudgeRedraw() (attach forced-repaint fallback): a +1-col SIGWINCH round-trip must
    // leave the child at the REAL size (the perturbation is only a signal carrier). If restore
    // regressed, the child would be stuck one column wide.
    func testNudgeRedrawRestoresRealSize() {
        let pty = HostPTY(), c = Collector()
        pty.resize(cols: 120, rows: 40, widthPx: 960, heightPx: 640)
        pty.start(executable: "/bin/sh", args: ["-c", "sleep 0.3; stty size"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil(1) { pty.childProcessID() != nil }
        pty.nudgeRedraw()
        waitUntil { c.text.contains("40 120") }
        XCTAssertTrue(c.text.contains("40 120"),
                      "nudgeRedraw must restore the real winsize: \(c.text.debugDescription)")
    }

    // 5g) nudgeRedraw() before the fork (fd < 0) is a safe no-op — must not crash.
    func testNudgeRedrawBeforeStartIsSafeNoOp() {
        HostPTY().nudgeRedraw()
    }

    // 6) onExit fires exactly once: terminating an already-dead child must not double-fire.
    func testExitIdempotent() {
        let pty = HostPTY(), c = Collector()
        pty.start(executable: "/bin/sh", args: ["-c", "exit 0"], env: env, cwd: "/tmp",
                  onData: c.onData, onExit: c.onExit)
        waitUntil { c.exited }
        XCTAssertEqual(c.exitCount, 1)
        pty.terminate()
        pty.terminate()
        // Give any spurious second fire a window to show up, then assert it never did.
        waitUntil(0.5) { c.exitCount > 1 }
        XCTAssertEqual(c.exitCount, 1, "onExit must fire exactly once")
    }
}
