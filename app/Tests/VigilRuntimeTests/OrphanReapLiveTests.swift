import XCTest
import VigilCore
@testable import VigilRuntime

/// LIVE full chain (Tier-2, MANUAL — gated on ORPHAN_LIVE=1, needs a real claude + API
/// reachability). Exercises the full chain end to end with a REAL claude, in an ISOLATED
/// session root (never the user's ~/Library archive):
///
///   spawn root claude through the full Orchestrator
///     → cell_pid recorded (pid + start time + exe) in orchestration.jsonl
///     → claude registers as a background agent holding <sid>  (the resume-block condition)
///     → simulate the hard-kill: overwrite live.lock with a dead owner (what SIGKILL leaves)
///     → OrphanReaper.reapAll terminates the stranded claude by its EXACT recorded pid
///     → <sid> drops out of `claude agents` → resume is free again (zero manual `claude agents`)
///
/// Run:  ORPHAN_LIVE=1 CLAUDE_BIN=/Users/you/.local/bin/claude swift test --filter OrphanReapLiveTests
final class OrphanReapLiveTests: XCTestCase {

    private func sh(_ args: [String], env: [String: String]? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        if let env { p.environment = env }
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Every registered background agent, as (pid, sessionId).
    private func liveAgents(_ claude: String) -> [(pid: Int32, sid: String)] {
        let json = sh([claude, "agents", "--json"])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let pid = d["pid"] as? Int, let sid = d["sessionId"] as? String else { return nil }
            return (Int32(pid), sid)
        }
    }

    @MainActor
    func testOrphanClaudeReapedThenResumeFree() async throws {
        guard ProcessInfo.processInfo.environment["ORPHAN_LIVE"] == "1" else {
            throw XCTSkip("set ORPHAN_LIVE=1 (needs real claude + API) to run the live orphan-reap chain")
        }
        let claude = ProcessInfo.processInfo.environment["CLAUDE_BIN"] ?? "claude"
        let (hookBin, mcpBin) = SiblingBins.locate()

        // Isolated root under the scratchpad — NOT the user's ~/Library/Application Support/Vigil.
        let root = NSTemporaryDirectory() + "vigil_orphan_live_\(UUID().uuidString)"
        let sessionDir = root + "/20260713-000000-orphanlive"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let rootNode = Node(id: NodeID("root"), role: .manager, status: .running, title: "manager")
        let harness = DispatchHarness(claudeBin: claude, codexBin: "codex", opencodeBin: "opencode",
                                      hookBin: hookBin, mcpBin: mcpBin,
                                      configRoot: sessionDir + "/config", printMode: false,
                                      permissionMode: .bypass, strictMCP: true)
        let orch = Orchestrator(rootNode: rootNode, harness: harness, sessionDir: sessionDir) {
            _ in HeadlessBackend(cols: 120, rows: 40)
        }
        // A task that persists a session and then just idles (interactive root stays alive).
        try orch.start(rootTask: "Reply with exactly the token READY and nothing else. Do not use any tools.")

        // 1) Wait until claude has forked + registered a session id (the resume-block condition).
        //    We match on the recorded cell pid so we never confuse another agent for ours.
        func recordedRootPid() -> Int32? {
            OrphanReaper.recordsFromLog(dir: sessionDir).first { $0.node == "root" }?.pid
        }
        var childPid: Int32?
        var sid: String?
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let pid = recordedRootPid() else { continue }
            childPid = pid
            if let hit = liveAgents(claude).first(where: { $0.pid == pid }) { sid = hit.sid; break }
        }
        let pid = try XCTUnwrap(childPid, "root claude never recorded a cell_pid")
        let session = try XCTUnwrap(sid, "root claude never registered as a background agent")
        print("=== LIVE: root claude pid=\(pid) sid=\(session) ===")

        // 2) cell_pid identity is real: pid alive, exe is the claude binary, start time set.
        let rec = try XCTUnwrap(OrphanReaper.recordsFromLog(dir: sessionDir).first { $0.node == "root" })
        XCTAssertEqual(rec.pid, pid)
        XCTAssertTrue(ProcessInspect.alive(pid))
        XCTAssertGreaterThan(rec.startTime, 1_600_000_000)
        XCTAssertTrue(rec.exe.hasSuffix("claude"), "recorded exe was \(rec.exe)")

        // 3) The resume-block condition holds: <sid> IS a live registered agent right now.
        XCTAssertTrue(liveAgents(claude).contains { $0.sid == session },
                      "precondition: sid must be a registered live agent (this is what blocks resume)")

        // 4) Simulate the hard-kill: the app process is gone, so its live.lock owner is dead.
        //    (Overwrite the orchestrator's own live lock with a definitely-dead pid.)
        SessionLock.write(dir: sessionDir, pid: 2_000_000, now: Date())
        XCTAssertFalse(SessionLock.isLive(dir: sessionDir), "post-crash lock must read not-live")

        // 5) Reap. The orchestrator is still our parent here, so terminate its bookkeeping first
        //    WITHOUT killing the child (we want the reaper to be the one that kills it) — detach
        //    by dropping our reference is not enough, so we let reapAll signal the exact pid.
        let outcomes = OrphanReaper.reapAll(root: root, graceSeconds: 1.0)
        let mine = outcomes.first { $0.pid == pid }
        print("=== LIVE: reap outcome for pid \(pid): \(String(describing: mine?.action)) ===")
        XCTAssertTrue(mine?.action == .reapedTERM || mine?.action == .reapedKILL,
                      "the orphan claude must be reaped")

        // 6) The exact pid is dead, and <sid> is no longer a live agent → resume is free.
        let t0 = Date()
        while ProcessInspect.alive(pid) && Date().timeIntervalSince(t0) < 10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertFalse(ProcessInspect.alive(pid), "recorded pid must be dead after reap")
        // give claude a moment to drop the deregistered agent from its list
        var stillRegistered = true
        for _ in 0..<25 {
            if !liveAgents(claude).contains(where: { $0.sid == session }) { stillRegistered = false; break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        XCTAssertFalse(stillRegistered,
                       "<sid> must drop out of `claude agents` after reap — resume no longer refused")
        print("=== LIVE: sid \(session) deregistered → resume is free ===")

        orch.stop()
        // safety net: nothing of ours should still be alive, but never a by-name kill.
        if ProcessInspect.alive(pid) { _ = ProcessInspect.signal(pid, SIGKILL) }
    }
}
