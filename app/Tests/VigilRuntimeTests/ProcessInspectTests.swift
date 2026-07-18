import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import VigilRuntime

/// OS identity primitives + HostPTY pid exposure, driven by REAL forkpty'd children under plain
/// `swift test` (no surface, no LLM). These pin the load-bearing half of the reaper: that we can
/// read a live process's start time + exec path to prove identity, and that HostPTY hands us the
/// exact pid the reaper will later target.
final class ProcessInspectTests: XCTestCase {

    private func waitUntil(_ deadline: TimeInterval = 5, _ cond: () -> Bool) {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    // Our own process is always inspectable: start time is a real timestamp, exec path is the
    // test runner, and we are alive.
    func testSelfIdentityReads() {
        let me = getpid()
        XCTAssertTrue(ProcessInspect.alive(me))
        let st = ProcessInspect.startTime(me)
        XCTAssertNotNil(st)
        XCTAssertGreaterThan(st ?? 0, 1_600_000_000)   // sometime after 2020
        XCTAssertNotNil(ProcessInspect.execPath(me))
    }

    // A non-existent pid reads as dead / uninspectable, never as a false-positive target.
    func testDeadPidReadsNothing() {
        // pid 0 and negatives are never real single-process targets.
        XCTAssertFalse(ProcessInspect.alive(0))
        XCTAssertFalse(ProcessInspect.alive(-1))
        // A very high pid is almost certainly unused → dead + no start time.
        let ghost: pid_t = 2_000_000
        XCTAssertFalse(ProcessInspect.alive(ghost))
        XCTAssertNil(ProcessInspect.startTime(ghost))
    }

    // HostPTY exposes the forked child's pid, and that pid is exactly the process we can then
    // inspect: alive, exec path = the launched binary. This is the record→verify round trip
    // the reaper depends on, minus the disk hop.
    func testHostPTYChildPidMatchesInspectedProcess() {
        let pty = HostPTY()
        // A child that lives long enough to be inspected, then exits on its own.
        let done = NSLock(); var exited = false
        pty.start(executable: "/bin/sleep", args: ["1"],
                  env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], cwd: "/tmp",
                  onData: { _ in },
                  onExit: { _ in done.lock(); exited = true; done.unlock() })
        // pid is published synchronously after forkpty returns.
        let pid = pty.childProcessID()
        XCTAssertNotNil(pid, "HostPTY must expose the forked child pid")
        if let pid {
            XCTAssertGreaterThan(pid, 0)
            XCTAssertTrue(ProcessInspect.alive(pid))
            // start time is set at fork — readable immediately, even pre-exec, and always the
            // child's own (kernel proc metadata, never the forking parent's).
            XCTAssertNotNil(ProcessInspect.startTime(pid))
            // argv/exec-path (KERN_PROCARGS2) during the pre-exec window returns the FORKING
            // PARENT's argv (the xctest runner) — the child's memory image before execve lands.
            // Poll until it flips to the launched binary; this is exactly why recordCellPid
            // records the ground-truth launch path instead of reading argv back here.
            waitUntil { ProcessInspect.execPath(pid)?.hasSuffix("/sleep") ?? false }
            let exe = ProcessInspect.execPath(pid)
            XCTAssertTrue(exe?.hasSuffix("/sleep") ?? false, "exec path was \(exe ?? "nil")")
        }
        waitUntil { done.lock(); defer { done.unlock() }; return exited }
    }

    // signal() targets exactly the given pid: SIGTERM ends a cooperating child. (We never test
    // by-name/pgroup here because the reaper never does that — the process-hygiene red line.)
    func testSignalTerminatesExactPid() {
        let pty = HostPTY()
        let done = NSLock(); var exited = false
        pty.start(executable: "/bin/sleep", args: ["30"],
                  env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], cwd: "/tmp",
                  onData: { _ in },
                  onExit: { _ in done.lock(); exited = true; done.unlock() })
        let pid = pty.childProcessID()
        XCTAssertNotNil(pid)
        guard let pid else { return }
        XCTAssertTrue(ProcessInspect.alive(pid))
        // forkpty child is a session/pgroup leader; the sleep runs in it. Signal the leader.
        _ = ProcessInspect.signal(pid, SIGTERM)
        waitUntil { !ProcessInspect.alive(pid) }
        XCTAssertFalse(ProcessInspect.alive(pid), "SIGTERM to the exact pid must end it")
        waitUntil { done.lock(); defer { done.unlock() }; return exited }
    }
}
