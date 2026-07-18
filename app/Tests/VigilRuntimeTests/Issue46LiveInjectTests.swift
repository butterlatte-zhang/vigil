import XCTest
import VigilCore
@testable import VigilRuntime

/// Live end-to-end: drives the real injection path (RealCell.deliverInitialPrompt →
/// probeInputLine → performInject → HeadlessBackend.send → real HostPTY → real claude 2.1.206),
/// then observes whether the initialPrompt actually landed & submitted. This is the exact
/// code path the GUI uses (HeadlessBackend = HostPTY + HostScreenParser, same as
/// GhosttyViewBackend minus the surface). Gated on ISSUE46_LIVE=1 (needs claude + proxy).
final class Issue46LiveInjectTests: XCTestCase {
    func testInitialPromptLandsThroughRealPath() async throws {
        guard ProcessInfo.processInfo.environment["ISSUE46_LIVE"] == "1" else {
            throw XCTSkip("set ISSUE46_LIVE=1 to run the live claude injection test")
        }
        let claude = ProcessInfo.processInfo.environment["CLAUDE_BIN"] ?? "claude"
        var env = ProcessInfo.processInfo.environment
        env["http_proxy"] = "http://127.0.0.1:7890"
        env["https_proxy"] = "http://127.0.0.1:7890"
        env["TERM"] = "xterm-256color"

        let backend = HeadlessBackend(cols: 120, rows: 40)
        let marker = "VIGIL46OK"
        let prompt = "Reply with exactly the token \(marker) and nothing else. Do not use any tools."
        let cwd = NSTemporaryDirectory()

        let launch = LaunchSpec(executable: claude,
                                args: ["--permission-mode", "bypassPermissions", "--model", "claude-haiku-4-5-20251001"],
                                env: env, initialPrompt: prompt)
        let cell = RealCell(nodeID: NodeID("live46"), launch: launch, cwd: cwd,
                            backend: backend, initialPrompt: prompt,
                            injectPollInterval: 0.5, initialPromptReadyTimeout: 30,
                            onExit: { _, _ in })
        await cell.start()

        // Poll up to 60s: watch the input line probe verdict + whether the prompt text /
        // the model's echo of the marker shows up in the transcript.
        var landed = false
        var lastScreen = ""
        var timeline: [String] = []
        for tick in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let screen = backend.renderScreen()
            lastScreen = screen
            let verdict = RealCell.probeInputLine(backend.renderAttributed())
            if tick % 4 == 0 { timeline.append("t=\(Double(tick)*0.5)s probe=\(verdict)") }
            if screen.contains(marker) || screen.contains("Reply with exactly") {
                landed = true
                print("=== ISSUE46 LIVE landed at tick \(tick) (\(Double(tick)*0.5)s) ===")
                break
            }
        }
        print("=== ISSUE46 LIVE timeline ===\n\(timeline.joined(separator: "\n"))")
        print("=== ISSUE46 LIVE final screen ===\n\(lastScreen)")
        await cell.terminate()
        XCTAssertTrue(landed, "initialPrompt never landed/submitted through the real path")
    }
}
