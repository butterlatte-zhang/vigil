import XCTest
import VigilCore
@testable import VigilRuntime

/// LIVE end-to-end confirmation that a narrow terminal pane does not cause false idle detection:
/// drive the REAL TurnWatcher against REAL streaming claude on a HEADLESS backend at a NARROW
/// pane (58 cols), the width at which claude truncates its running footer to "… · esc to…" so
/// the anchor is off-screen mid-turn. Liveness detection is activity-based, so it must emit zero
/// false turnEnded events even when the anchor text is unreadable.
/// Gated on TURNFLAP_LIVE=1 (needs claude + proxy). Not part of CI.
final class TurnFlapLiveTests: XCTestCase {
    @MainActor
    func testNarrowStreamingDoesNotFalselyEndTurn() async throws {
        guard ProcessInfo.processInfo.environment["TURNFLAP_LIVE"] == "1" else {
            throw XCTSkip("set TURNFLAP_LIVE=1 to run the live narrow-pane false-idle confirmation")
        }
        let claude = ProcessInfo.processInfo.environment["CLAUDE_BIN"] ?? "claude"
        var env = ProcessInfo.processInfo.environment
        env["http_proxy"] = "http://127.0.0.1:7890"
        env["https_proxy"] = "http://127.0.0.1:7890"
        env["TERM"] = "xterm-256color"

        let backend = HeadlessBackend(cols: 58, rows: 24)
        let prompt = "Read-only task, do not modify any files. (1) Read through every Swift file under app/Sources/VigilApp, "
            + "and for each file print a detailed analysis in the terminal (responsibilities, key types, dependencies); print each file's analysis immediately after reading it, "
            + "do not hold back — the goal is to make the terminal accumulate more than 512KB of scrolled output; (2) after reading everything, print a concise summary within 10 lines."
        let cwd = ProcessInfo.processInfo.environment["TURNFLAP_CWD"] ?? FileManager.default.currentDirectoryPath
        let launch = LaunchSpec(executable: claude, args: ["--permission-mode", "bypassPermissions"],
                                env: env, initialPrompt: prompt)
        let node = NodeID("n43repro")
        let cell = RealCell(nodeID: node, launch: launch, cwd: cwd, backend: backend,
                            initialPrompt: prompt, injectPollInterval: 0.5,
                            initialPromptReadyTimeout: 30, onExit: { _, _ in })
        await cell.start()

        var emitted: [Command] = []
        let tw = TurnWatcher(openTurnNodes: { [(node, 1)] },
                             screen: { _ in backend.renderScreen() },
                             emit: { emitted.append($0) })
        for _ in 0..<90 { try? await Task.sleep(nanoseconds: 1_000_000_000); tw.tick() }
        print("=== TURNFLAP narrow(58) emitted turnEnded: \(emitted.count) (expect 0 post-fix) ===")
        await cell.terminate()
        XCTAssertTrue(emitted.isEmpty, "narrow-pane streaming still false-ended: \(emitted.count)")
    }
}
