import XCTest
import VigilCore
@testable import VigilRuntime

/// Live end-to-end for the closed-loop submit. Real codex started on a COLD CODEX_HOME (always
/// the case in the product: every node gets a fresh per-node home) draws its composer at ~0.2s
/// but swallows an Enter that arrives in the first seconds of startup, so the pasted first
/// prompt used to sit unsubmitted in the composer. A warm home does not reproduce it. Drives
/// the exact product path (RealCell.deliverInitialPrompt → performInject → HeadlessBackend →
/// real HostPTY → real codex) and asserts the turn actually starts.
///
/// Gated on CODEX_SUBMIT_LIVE=1 (needs codex + a logged-in ~/.codex/auth.json, or
/// CODEX_AUTH_JSON). The test builds its own throwaway CODEX_HOME with
/// `check_for_update_on_startup = false` — never point an injecting harness at the default
/// ~/.codex: an "Update available" box there turns an injected Enter into a global
/// `npm install`. CODEX_BIN overrides the binary. CODEX_SUBMIT_OPENLOOP=1 zeroes the landing
/// wait and the retry budget, which degrades to the original open-loop send → 0.15s → CR and
/// reproduces the stall (diagnostic, asserts nothing).
final class CodexSubmitLiveTests: XCTestCase {
    func testInitialPromptSubmitsDuringCodexStartup() async throws {
        let penv = ProcessInfo.processInfo.environment
        guard penv["CODEX_SUBMIT_LIVE"] == "1" else {
            throw XCTSkip("set CODEX_SUBMIT_LIVE=1 to run the live codex submit test")
        }
        let codex = penv["CODEX_BIN"] ?? "codex"
        let openLoop = penv["CODEX_SUBMIT_OPENLOOP"] == "1"
        let auth = penv["CODEX_AUTH_JSON"] ?? (NSHomeDirectory() + "/.codex/auth.json")
        guard FileManager.default.fileExists(atPath: auth) else {
            throw XCTSkip("no codex auth.json at \(auth)")
        }

        // Cold, throwaway CODEX_HOME + trusted cwd (realpath: codex keys trust on the
        // canonical path, and the temp dir sits behind the /var → /private/var symlink).
        let fm = FileManager.default
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vigil-codex-submit-\(UUID().uuidString)")
        let home = base + "/home", work = base + "/work"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        let cwd = realpath(work, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? work
        try fm.createSymbolicLink(atPath: home + "/auth.json", withDestinationPath: auth)
        try """
            check_for_update_on_startup = false
            approval_policy = "never"
            sandbox_mode = "read-only"
            model_reasoning_effort = "low"

            [projects.\(CodexHarness.tomlString(cwd))]
            trust_level = "trusted"

            """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        var env = penv
        env["CODEX_HOME"] = home
        env["TERM"] = "xterm-256color"
        env["PATH"] = ((codex as NSString).deletingLastPathComponent) + ":" + (penv["PATH"] ?? "")

        let marker = "VIGILSUBMITOK"
        // Multi-line and >1000 chars: rides a bracketed paste and codex shows it as a
        // "[Pasted Content N chars]" placeholder, so the marker is on screen only after submit.
        var prompt = "Reply with exactly the token \(marker) and nothing else. Do not use any tools.\n"
        while prompt.count < 1500 { prompt += "Filler line, ignore it completely.\n" }

        // Production dark cells answer OSC 10/11 colour queries host-side (a surface-attached
        // cell has ghostty answer them); CODEX_SUBMIT_COLORS=0 leaves them unanswered.
        let answerColors = penv["CODEX_SUBMIT_COLORS"] != "0"
        let backend = HeadlessBackend(cols: 160, rows: 50,
                                      foregroundColorSpec: answerColors ? "#000000" : nil,
                                      backgroundColorSpec: answerColors ? "#ffffff" : nil)
        let acks = AckBox()
        let launch = LaunchSpec(executable: codex,
                                args: [],
                                env: env, initialPrompt: prompt)
        let cell = RealCell(nodeID: NodeID("livecodex"), launch: launch, cwd: cwd,
                            backend: backend, initialPrompt: prompt,
                            injectLandTimeout: openLoop ? 0 : 5,
                            injectRetryTimeout: openLoop ? 0 : 30,
                            onInitialPromptAck: { _, ack in acks.set(ack) },
                            onExit: { _, _ in })
        await cell.start()

        // Submitted = the marker is on screen (codex echoes the sent message into history)
        // while the composer is empty again. The marker alone is not enough: codex paints the
        // raw paste in the composer for a moment before collapsing it into the placeholder.
        var submitted = false
        var lastScreen = ""
        var timeline: [String] = []
        var lastProbe: RealCell.InputLineProbe?
        for tick in 0..<600 {                       // up to 60s
            try? await Task.sleep(nanoseconds: 100_000_000)
            lastScreen = backend.renderScreen()
            if lastScreen.contains("Update available") {
                await cell.terminate()
                XCTFail("update box on screen — the update-check pin did not take")
                return
            }
            let probe = RealCell.probeInputLine(backend.renderAttributed())
            if probe != lastProbe {
                var d = "\(probe)"; if d.count > 70 { d = String(d.prefix(70)) + "…" }
                timeline.append("t=\(Double(tick + 1) / 10)s probe=\(d)")
                lastProbe = probe
            }
            if probe == .clear, lastScreen.contains(marker) {
                submitted = true
                print("=== CODEX SUBMIT LIVE: submitted at \(Double(tick + 1) / 10)s ===")
                break
            }
            if openLoop, tick >= 200 { break }       // diagnostic run: 20s is plenty to show the stall
        }
        if submitted {                              // informational: did the model answer?
            for _ in 0..<150 where !lastScreen.contains("\u{2022} \(marker)") {
                try? await Task.sleep(nanoseconds: 100_000_000)
                lastScreen = backend.renderScreen()
            }
            print("=== CODEX SUBMIT LIVE replied=\(lastScreen.contains("\u{2022} \(marker)")) ===")
        }
        print("=== CODEX SUBMIT LIVE timeline ===\n\(timeline.joined(separator: "\n"))")
        print("=== CODEX SUBMIT LIVE ack: delivered=\(acks.value?.delivered ?? false) note=\(acks.value?.note ?? "nil") ===")
        print("=== CODEX SUBMIT LIVE final screen ===\n\(lastScreen)")
        await cell.terminate()
        if openLoop {
            print("=== CODEX SUBMIT LIVE (open loop): submitted=\(submitted) ===")
        } else {
            XCTAssertTrue(submitted, "initial prompt was pasted but never submitted")
        }
    }
}

private final class AckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ack: InjectAck?
    func set(_ a: InjectAck) { lock.lock(); ack = a; lock.unlock() }
    var value: InjectAck? { lock.lock(); defer { lock.unlock() }; return ack }
}
