import Foundation
import XCTest
@testable import VigilRuntime

// A hard-killed (SIGKILL) Vigil leaves each cell's agent child
// alive — an interactive claude ignores the PTY hangup, reparents to launchd, and stays a
// registered background agent that makes `claude --resume <sid>` refuse. OrphanReaper's pure
// core reclaims these at the next startup, gated by three independent guards. Every OS/IO
// seam is injected so no real process is ever signalled here.
//
// The three guards under test:
//   ③ session held by a live instance   → NEVER touched
//   ①/liveness recorded pid already dead → nothing to do
//   ② pid alive but identity changed     → SPARED (pid was recycled)
//   all three pass                       → SIGTERM, then SIGKILL only if it clings on
final class OrphanReaperTests: XCTestCase {

    // A programmable process table the fake deps read from.
    private struct FakeProc {
        var alive: Bool
        var startTime: Double
        var exe: String
    }

    /// Build Deps over an in-memory world. `signals` records every (pid,sig) we send, in
    /// order — the assertion surface for "exact pid only, SIGTERM before SIGKILL".
    private func makeDeps(
        dirs: [String],
        held: Set<String>,
        records: [String: [OrphanReaper.CellRecord]],
        procs: [Int32: FakeProc],
        signals: NSMutableArray,
        logs: NSMutableArray,
        // a pid that dies the instant it receives SIGTERM (honors term); others cling on.
        diesOnTerm: Set<Int32> = []
    ) -> OrphanReaper.Deps {
        // Mutable copy so `signal` can flip alive on term/kill and pidAlive re-reads it.
        let table = NSMutableDictionary()
        for (pid, p) in procs { table[pid] = p as Any }
        func get(_ pid: Int32) -> FakeProc? { table[pid] as? FakeProc }
        return OrphanReaper.Deps(
            sessionDirs: { dirs },
            sessionHeld: { held.contains($0) },
            records: { records[$0] ?? [] },
            pidAlive: { get($0)?.alive ?? false },
            startTime: { get($0)?.startTime },
            execPath: { get($0)?.exe },
            signal: { pid, sig in
                signals.add([pid, sig])
                guard var p = get(pid), p.alive else { return }
                if sig == SIGKILL { p.alive = false; table[pid] = p }
                if sig == SIGTERM, diesOnTerm.contains(pid) { p.alive = false; table[pid] = p }
            },
            sleep: { _ in },   // deterministic: no real wait
            log: { dir, node, pid, action in logs.add([dir, node, pid, action.rawValue]) }
        )
    }

    private func rec(_ node: String, _ pid: Int32, _ st: Double, _ exe: String = "/bin/claude")
        -> OrphanReaper.CellRecord {
        OrphanReaper.CellRecord(node: node, pid: pid, startTime: st, exe: exe)
    }

    // MARK: guard ③ — a live-held session is never touched

    func testHeldSessionIsSkipped() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/A"], held: ["/s/A"],
            records: ["/s/A": [rec("root", 100, 1000)]],
            procs: [100: FakeProc(alive: true, startTime: 1000, exe: "/bin/claude")],
            signals: signals, logs: logs)
        let out = OrphanReaper.reap(deps: deps)
        // A held session yields NO candidate outcomes and — crucially — zero signals.
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(signals.count, 0)
    }

    // MARK: guard ①/liveness — owner dead + pid dead = nothing to reap

    func testDeadOwnerDeadPidIsNoop() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/A"], held: [],   // owner dead → not held
            records: ["/s/A": [rec("root", 100, 1000)]],
            procs: [100: FakeProc(alive: false, startTime: 1000, exe: "/bin/claude")],
            signals: signals, logs: logs)
        let out = OrphanReaper.reap(deps: deps)
        XCTAssertEqual(out.map(\.action), [.skippedDead])
        XCTAssertEqual(signals.count, 0)
    }

    // MARK: the happy path — owner dead, pid alive, identity matches → reaped

    func testOrphanReapedViaTERM() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/A"], held: [],
            records: ["/s/A": [rec("root", 100, 1000)]],
            procs: [100: FakeProc(alive: true, startTime: 1000, exe: "/bin/claude")],
            signals: signals, logs: logs,
            diesOnTerm: [100])   // honors SIGTERM within the grace
        let out = OrphanReaper.reap(deps: deps)
        XCTAssertEqual(out.map(\.action), [.reapedTERM])
        // exactly one signal — SIGTERM — to exactly pid 100. No SIGKILL needed.
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0] as? [Int32], [100, SIGTERM])
        XCTAssertEqual(logs.count, 1)
    }

    func testOrphanEscalatesToKILLWhenItIgnoresTERM() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/A"], held: [],
            records: ["/s/A": [rec("root", 100, 1000)]],
            procs: [100: FakeProc(alive: true, startTime: 1000, exe: "/bin/claude")],
            signals: signals, logs: logs,
            diesOnTerm: [])   // clings on past SIGTERM (claude ignores SIGHUP; models a stubborn one)
        let out = OrphanReaper.reap(deps: deps)
        XCTAssertEqual(out.map(\.action), [.reapedKILL])
        // SIGTERM first, THEN SIGKILL — both to exactly pid 100, in order.
        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals[0] as? [Int32], [100, SIGTERM])
        XCTAssertEqual(signals[1] as? [Int32], [100, SIGKILL])
    }

    // MARK: guard ② — identity mismatch spares a recycled pid

    func testRecycledPidStartTimeMismatchIsSpared() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/A"], held: [],
            records: ["/s/A": [rec("root", 100, 1000)]],   // recorded born at t=1000
            // pid 100 is alive but was born LATER (1234) → it's a different, recycled process
            procs: [100: FakeProc(alive: true, startTime: 1234, exe: "/bin/claude")],
            signals: signals, logs: logs, diesOnTerm: [100])
        let out = OrphanReaper.reap(deps: deps)
        XCTAssertEqual(out.map(\.action), [.skippedIdentity])
        XCTAssertEqual(signals.count, 0, "a recycled pid must NEVER be signalled")
    }

    func testRecycledPidExecMismatchIsSpared() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/A"], held: [],
            records: ["/s/A": [rec("root", 100, 1000, "/bin/claude")]],
            // same pid + same start time, but now a DIFFERENT binary → recycled → spare it
            procs: [100: FakeProc(alive: true, startTime: 1000, exe: "/usr/bin/vim")],
            signals: signals, logs: logs, diesOnTerm: [100])
        let out = OrphanReaper.reap(deps: deps)
        XCTAssertEqual(out.map(\.action), [.skippedIdentity])
        XCTAssertEqual(signals.count, 0)
    }

    func testUnreadableIdentityIsSpared() {
        // startTime/execPath return nil (EPERM / vanished) → can't confirm → fail-safe skip.
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = OrphanReaper.Deps(
            sessionDirs: { ["/s/A"] }, sessionHeld: { _ in false },
            records: { _ in [self.rec("root", 100, 1000)] },
            pidAlive: { _ in true },
            startTime: { _ in nil },       // unreadable
            execPath: { _ in nil },
            signal: { pid, sig in signals.add([pid, sig]) },
            sleep: { _ in }, log: { _, _, _, _ in })
        let out = OrphanReaper.reap(deps: deps)
        XCTAssertEqual(out.map(\.action), [.skippedIdentity])
        XCTAssertEqual(signals.count, 0)
    }

    // MARK: multi-session / multi-node isolation

    func testMixedWorldReapsOnlyTheTrueOrphans() {
        let signals = NSMutableArray(), logs = NSMutableArray()
        let deps = makeDeps(
            dirs: ["/s/live", "/s/dead"],
            held: ["/s/live"],                                  // /s/live is held → untouched
            records: [
                "/s/live": [rec("root", 200, 2000)],            // would-be orphan but held
                "/s/dead": [rec("root", 300, 3000),             // true orphan → reap
                            rec("w1", 301, 3001),               // dead pid → noop
                            rec("w2", 302, 3002, "/bin/codex")],// recycled → spare
            ],
            procs: [
                200: FakeProc(alive: true, startTime: 2000, exe: "/bin/claude"),
                300: FakeProc(alive: true, startTime: 3000, exe: "/bin/claude"),
                301: FakeProc(alive: false, startTime: 3001, exe: "/bin/claude"),
                302: FakeProc(alive: true, startTime: 9999, exe: "/bin/codex"), // wrong birth
            ],
            signals: signals, logs: logs, diesOnTerm: [300])
        let out = OrphanReaper.reap(deps: deps)
        // only pid 300 is signalled, exactly once, with SIGTERM. 200 (held) never examined.
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0] as? [Int32], [300, SIGTERM])
        let dead = out.first { $0.pid == 300 }
        XCTAssertEqual(dead?.action, .reapedTERM)
        XCTAssertEqual(out.first { $0.pid == 301 }?.action, .skippedDead)
        XCTAssertEqual(out.first { $0.pid == 302 }?.action, .skippedIdentity)
        XCTAssertNil(out.first { $0.pid == 200 }, "held session's pid must not even be a candidate")
    }

    // MARK: start-time equality is microsecond-exact

    func testSameStartMicrosecondBoundary() {
        XCTAssertTrue(OrphanReaper.sameStart(1000.000001, 1000.000001))
        XCTAssertFalse(OrphanReaper.sameStart(1000.000001, 1000.000002))
        // representation noise within a microsecond still matches (rounded compare)
        XCTAssertTrue(OrphanReaper.sameStart(1000.0000010000001, 1000.0000009999999))
    }

    // MARK: log parsing — latest cell_pid per node wins; malformed skipped

    func testRecordsFromLogParsesLatestPerNode() throws {
        let dir = NSTemporaryDirectory() + "vigil_reap_log_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lines = [
            #"{"event":"cell_launch","node":"root"}"#,
            #"{"event":"cell_pid","node":"root","pid":100,"startTime":1000.5,"exe":"/bin/claude"}"#,
            #"{"event":"cell_pid","node":"w1","pid":200,"startTime":2000.25,"exe":"/bin/codex"}"#,
            // a resume relaunch of root → newer pid wins
            #"{"event":"cell_pid","node":"root","pid":101,"startTime":1001.0,"exe":"/bin/claude"}"#,
            #"{"event":"cell_pid","node":"bad","pid":0,"startTime":1.0,"exe":"/x"}"#,   // pid 0 skipped
            #"garbage not json"#,
            #"{"event":"cell_pid","node":"nomissing"}"#,                                 // missing fields skipped
        ]
        try lines.joined(separator: "\n").write(toFile: dir + "/orchestration.jsonl",
                                                 atomically: true, encoding: .utf8)
        let recs = OrphanReaper.recordsFromLog(dir: dir)
        XCTAssertEqual(recs.count, 2)
        let root = try XCTUnwrap(recs.first { $0.node == "root" })
        XCTAssertEqual(root.pid, 101)                 // latest wins
        XCTAssertEqual(root.startTime, 1001.0)
        let w1 = try XCTUnwrap(recs.first { $0.node == "w1" })
        XCTAssertEqual(w1.pid, 200)
        XCTAssertEqual(w1.exe, "/bin/codex")
        XCTAssertNil(recs.first { $0.node == "bad" })
        XCTAssertNil(recs.first { $0.node == "nomissing" })
    }
}
