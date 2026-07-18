import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import VigilRuntime

/// T1a — the FULL production reap path against a REAL forked child and a REAL on-disk
/// session, minus the app + LLM. Exercises `reapAll` → `liveDeps` (recordsFromLog +
/// SessionLock.isLive + ProcessInspect + real `kill`) end-to-end, so the deterministic proof
/// matches the real-machine chain: a stranded child with a dead lock owner is terminated; a
/// child whose session is still live-held is spared.
final class OrphanReapIntegrationTests: XCTestCase {

    private var tmpRoots: [String] = []
    private var strays: [pid_t] = []   // children to clean up by EXACT pid on teardown

    override func tearDown() {
        for pid in strays where ProcessInspect.alive(pid) { _ = ProcessInspect.signal(pid, SIGKILL) }
        strays.removeAll()
        for r in tmpRoots { try? FileManager.default.removeItem(atPath: r) }
        tmpRoots.removeAll()
        super.tearDown()
    }

    private func waitUntil(_ deadline: TimeInterval = 5, _ cond: () -> Bool) {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// Fork a real, long-lived child under a PTY and return its (pty, pid). Records the pid for
    /// teardown so a failed assertion never leaks a process.
    private func spawnChild() -> (HostPTY, pid_t) {
        let pty = HostPTY()
        pty.start(executable: "/bin/sleep", args: ["120"],
                  env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], cwd: "/tmp",
                  onData: { _ in }, onExit: { _ in })
        let pid = pty.childProcessID()!
        strays.append(pid)
        // Wait for the REAL exec to land — pre-exec, execPath returns the xctest parent's path,
        // so poll for the launched binary specifically (matches recordCellPid's ground truth).
        waitUntil { ProcessInspect.execPath(pid)?.hasSuffix("/sleep") ?? false }
        return (pty, pid)
    }

    /// Build a session dir under a fresh root, seed orchestration.jsonl with a real cell_pid
    /// record for `pid`, and write a live.lock owned by `lockPid` with a fresh heartbeat.
    private func makeSession(node: String, pid: pid_t, lockPid: Int32) throws -> (root: String, dir: String) {
        let root = NSTemporaryDirectory() + "vigil_reap_it_\(UUID().uuidString)"
        let dir = root + "/20260713-000000-deadbeef"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tmpRoots.append(root)
        let st = ProcessInspect.startTime(pid)!
        let exe = ProcessInspect.execPath(pid)!
        let line = #"{"event":"cell_pid","node":"\#(node)","pid":\#(Int(pid)),"startTime":\#(st),"exe":"\#(exe)"}"#
        try line.write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionLock.write(dir: dir, pid: lockPid, now: Date())
        return (root, dir)
    }

    // End to end: lock owner is dead (a ghost pid) → the recorded child is a
    // true orphan → reapAll terminates it by exact pid and appends a cell_reaped record.
    func testReapAllKillsOrphanWhenLockOwnerDead() throws {
        let (_, pid) = spawnChild()
        let deadOwner: Int32 = 2_000_000   // no such process → lock reads not-live
        XCTAssertFalse(ProcessInspect.alive(deadOwner))
        let (root, dir) = try makeSession(node: "root", pid: pid, lockPid: deadOwner)

        XCTAssertTrue(ProcessInspect.alive(pid), "precondition: orphan is alive")
        let outcomes = OrphanReaper.reapAll(root: root, graceSeconds: 0.3)

        let mine = outcomes.first { $0.pid == pid }
        XCTAssertNotNil(mine)
        XCTAssertTrue(mine?.action == .reapedTERM || mine?.action == .reapedKILL,
                      "orphan should be reaped, got \(String(describing: mine?.action))")
        waitUntil { !ProcessInspect.alive(pid) }
        XCTAssertFalse(ProcessInspect.alive(pid), "the exact recorded pid must be dead after reap")

        // forensic trail: a cell_reaped line landed in the session's orchestration.jsonl.
        let log = try String(contentsOfFile: dir + "/orchestration.jsonl", encoding: .utf8)
        XCTAssertTrue(log.contains(#""event":"cell_reaped""#), "reap must be recorded:\n\(log)")
    }

    // Guard ③ end to end: the lock owner is THIS live test process → the session is held →
    // reapAll must NOT touch the child, even though its pid is recorded.
    func testReapAllSparesChildWhenSessionHeldLive() throws {
        let (_, pid) = spawnChild()
        let (root, _) = try makeSession(node: "root", pid: pid, lockPid: getpid())  // alive owner

        let outcomes = OrphanReaper.reapAll(root: root, graceSeconds: 0.3)
        XCTAssertNil(outcomes.first { $0.pid == pid },
                     "a live-held session's child must not even be a candidate")
        XCTAssertTrue(ProcessInspect.alive(pid), "held session's child must survive")
        // cleanup by exact pid
        _ = ProcessInspect.signal(pid, SIGKILL)
    }

    // Identity guard end to end: lock owner dead, but the recorded exe no longer matches the
    // live pid (simulating pid reuse) → the child is spared.
    func testReapAllSparesRecycledPid() throws {
        let (_, pid) = spawnChild()
        // Seed a record with a DIFFERENT exe than the live process actually has.
        let root = NSTemporaryDirectory() + "vigil_reap_it_\(UUID().uuidString)"
        let dir = root + "/20260713-000000-recycled"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tmpRoots.append(root)
        let st = ProcessInspect.startTime(pid)!
        let line = #"{"event":"cell_pid","node":"root","pid":\#(Int(pid)),"startTime":\#(st),"exe":"/usr/bin/vim"}"#
        try line.write(toFile: dir + "/orchestration.jsonl", atomically: true, encoding: .utf8)
        SessionLock.write(dir: dir, pid: 2_000_000, now: Date())   // dead owner

        let outcomes = OrphanReaper.reapAll(root: root, graceSeconds: 0.3)
        XCTAssertEqual(outcomes.first { $0.pid == pid }?.action, .skippedIdentity)
        XCTAssertTrue(ProcessInspect.alive(pid), "recycled-identity pid must be spared")
        _ = ProcessInspect.signal(pid, SIGKILL)
    }
}
