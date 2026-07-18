import XCTest
import VigilCore
@testable import VigilRuntime

/// Same-source self-consistency, proven with existing tests.
///
/// The dark-screen scrape closure moves `renderScreen()`'s source from the
/// ghostty surface to a host-side libghostty-vt parser (`HostScreenParser`) fed straight off
/// the host PTY. This test proves the NEW source works by wiring it into the REAL
/// `TurnWatcher` / `PermWatcher` objects (not re-implemented logic) and asserting the same
/// emissions their unit tests assert — but here the bytes are real, forkpty'd, and NO
/// surface exists (exactly the dark-screen condition). Everything runs under `swift test`.
///
/// Determinism: each child script paints a phase, then blocks on stdin (`read`); the test
/// polls the scrape source for the expected content, drives watcher ticks, then writes a
/// newline to release the next phase. No fixed sleeps gate the watcher sequence.
final class HostScrapeIntegrationTests: XCTestCase {

    private let env = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]

    /// Poll to a condition or a deadline — never a fixed sleep (guards against slow CI machines, mirroring HostPTYTests).
    private func waitUntil(_ deadline: TimeInterval = 5, _ cond: () -> Bool) {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Footer running anchor present → armed; then cleared off the host-scrape source →
    /// two anchor-free ticks → `.turnEnded`. Proves the footer-tail anchor still holds on
    /// the new source (renderScreen preserves the footer row).
    @MainActor
    func testTurnEndedDrivenByHostScrapeSource() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        let pty = HostPTY()
        let node = NodeID("n1")
        var emitted: [Command] = []
        let tw = TurnWatcher(openTurnNodes: { [(node, 1)] },
                             screen: { _ in parser.renderScreen() },
                             emit: { emitted.append($0) })

        // Phase 1: footer WITH the running anchor. Phase 2 (after a newline): clear it.
        let script = """
        printf '\\033[2J\\033[HCrunching...\\nworking on it\\nesc to interrupt\\n'
        read x
        printf '\\033[2J\\033[Hall done, back to idle\\n'
        read x
        """
        pty.start(executable: "/bin/sh", args: ["-c", script], env: env, cwd: "/tmp",
                  onData: { parser.feed($0) }, onExit: { _ in })
        defer { pty.terminate() }

        waitUntil { parser.renderScreen().lowercased().contains(TurnWatcher.runningAnchor) }
        tw.tick()                                             // anchor in footer → armed
        XCTAssertTrue(emitted.isEmpty, "anchor on the host-scrape footer = turn running")

        pty.write(Data("\n".utf8))                            // release phase 2 → clears anchor
        waitUntil { !parser.renderScreen().lowercased().contains(TurnWatcher.runningAnchor) }
        // Three anchor-free ticks: the first is the phase-1→phase-2 transition (the screen CHANGED),
        // which the width-robust liveness rule treats as still alive; the anchor-free screen
        // then stays STATIC, so the miss counter advances and reaps on the following two ticks.
        tw.tick(); tw.tick(); tw.tick()
        XCTAssertTrue(emitted.contains { cmd in
            if case .turnEnded(let n, _) = cmd { return n == node } else { return false }
        }, "footer anchor left the host-scrape source → turnEnded, got \(emitted)")
    }

    /// Permission box present → armed; then cleared off the host-scrape source →
    /// `.resolveNotice(via: .scrape)`. Proves the perm anchor still fires on the new source.
    @MainActor
    func testPermScrapeResolveDrivenByHostScrapeSource() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        let pty = HostPTY()
        let node = NodeID("n1")
        let notice = AgentNotice(seq: 1, nodeID: node, kind: .permission, text: "perm",
                                 promptID: "p1", toolName: "Bash",
                                 toolInput: #"{"command":"git push"}"#, arrivedAt: Date())
        var emitted: [Command] = []
        let pw = PermWatcher(notices: { [notice] },
                             screen: { _ in parser.renderScreen() },
                             emit: { emitted.append($0) })

        let script = """
        printf '\\033[2J\\033[HBash(git push)\\nDo you want to proceed?\\n 1. Yes\\n 3. No\\n'
        read x
        printf '\\033[2J\\033[Hresolved and moving on\\n'
        read x
        """
        pty.start(executable: "/bin/sh", args: ["-c", script], env: env, cwd: "/tmp",
                  onData: { parser.feed($0) }, onExit: { _ in })
        defer { pty.terminate() }

        waitUntil { parser.renderScreen().contains(PermWatcher.anchors[0]) }
        pw.tick()                                             // box on screen → armed
        XCTAssertTrue(emitted.isEmpty, "box on the host-scrape source = card unresolved")

        pty.write(Data("\n".utf8))                            // release phase 2 → clears box
        waitUntil { !parser.renderScreen().contains(PermWatcher.anchors[0]) }
        pw.tick()                                             // box gone + armed → resolve
        XCTAssertTrue(emitted.contains { cmd in
            if case .resolveNotice(let from, _, let via) = cmd {
                return from == node && via == .scrape
            }
            return false
        }, "perm box left the host-scrape source → scrape resolve, got \(emitted)")
    }
}
