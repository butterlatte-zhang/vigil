import XCTest
import VigilCore
@testable import VigilRuntime

/// codex ≥0.142 uses a border-LESS `› <placeholder|typed>` composer line instead of a
/// `│ > … │` box. The input-line probe must anchor on the `›` marker rather than the
/// header banner `│ >_ OpenAI Codex (vX.Y.Z) │` — anchoring on the banner reads
/// `.userTyping` forever, which holds `deliverInitialPrompt` and the first-turn task
/// injection hostage past their fail-open window. The probe splits placeholder (SGR-2 dim)
/// vs typed (plain) content, verified against real captured 0.144.1 byte streams fed
/// through the production scrape (HostScreenParser / VtScreen).
/// opencode's `┃`-barred composer is covered too: its empty placeholder reads `.clear`
/// instead of `.unknown`, so its initial prompt injects promptly.
///
/// The fail-open loop, the bracketed-paste inject sequence (multi-line body + separate raw
/// CR), and the injectMaxQueueWait wiring are independently verified correct
/// (`testInitialPromptFailsOpenOnPersistentUserTyping` below pins the loop) — the fail-open
/// safety net holds regardless of the composer probe's accuracy.
final class Issue49ProbeRegressionTests: XCTestCase {

    private func probeCapture(_ resource: String) throws -> RealCell.InputLineProbe {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "raw"),
              let data = try? Data(contentsOf: url) else { throw XCTSkip("missing fixture \(resource).raw") }
        let parser = HostScreenParser(cols: 120, rows: 40)
        parser.feed(data)
        let sem = DispatchSemaphore(value: 0); parser.afterPending { sem.signal() }; _ = sem.wait(timeout: .now() + 5)
        return RealCell.probeInputLine(parser.renderAttributed())
    }

    // MARK: real captured codex 0.144.1 streams through the production scrape

    func testRealCodexEmptyComposerIsClear() throws {
        // Empty composer (rotating dim placeholder `› Implement {feature}`) must read
        // .clear so deliverInitialPrompt injects — never the header banner's .userTyping.
        XCTAssertEqual(try probeCapture("codex-0.144-composer-empty"), .clear)
    }

    func testRealCodexTypedComposerIsUserTyping() throws {
        // Real typed content (`› fix the flaky parse test`, plain/non-dim) must hold.
        XCTAssertEqual(try probeCapture("codex-0.144-composer-typed"),
                       .userTyping("fix the flaky parse test"))
    }

    // MARK: real captured opencode streams

    func testRealOpenCodeEmptyComposerIsClear() throws {
        // opencode empty composer (`┃  Ask anything... "…"`) must read .clear so the
        // initial prompt injects promptly.
        XCTAssertEqual(try probeCapture("opencode-composer-empty"), .clear)
    }

    func testRealOpenCodeTypedComposerFallsOpen() throws {
        // Documented limitation: opencode's typed line is not structurally separable from its
        // `· model` status row, so typed content stays .unknown (fail-open), never
        // a wrong .userTyping. Pinned so the conservative choice is a decision, not an accident.
        XCTAssertEqual(try probeCapture("opencode-composer-typed"), .unknown)
    }

    // MARK: synthetic — the header banner alone must NEVER be read as the input line

    private func plain(_ s: String) -> AttributedLine {
        AttributedLine(text: s, dim: Array(repeating: false, count: s.count))
    }
    /// A `› <content>` composer line with an explicit dim mask over the content (marker never dim).
    private func codexComposer(_ content: String, dim: Bool) -> AttributedLine {
        let text = "\u{203A} " + content
        var mask = [false, false]                       // `›` + space
        mask += Array(repeating: dim, count: content.count)
        return AttributedLine(text: text, dim: mask)
    }

    func testHeaderBannerAloneIsNotUserTyping() {
        // The codex header banner `│ >_ OpenAI Codex (v0.144.1) │` with NO
        // `›` composer line present (a transient redraw frame). The box fallback must SKIP the `>_`
        // splash marker, so the verdict is .unknown (fail-open) — never .userTyping("_ OpenAI …")
        // that would hold the message forever.
        let screen = AttributedScreen(lines: [
            plain("╭───────────────────────────────────────╮"),
            plain("│ >_ OpenAI Codex (v0.144.1)            │"),
            plain("╰───────────────────────────────────────╯"),
            plain("• Booting MCP server: codex_apps (2s • esc to interrupt)"),
        ])
        if case .userTyping = RealCell.probeInputLine(screen) {
            XCTFail("codex header banner must never read as userTyping")
        }
        XCTAssertEqual(RealCell.probeInputLine(screen), .unknown)
    }

    func testHeaderBannerWithComposerReadsComposer() {
        // The real startup screen: banner + `›` composer. The `›` layer wins outright.
        let screen = AttributedScreen(lines: [
            plain("│ >_ OpenAI Codex (v0.144.1)            │"),
            codexComposer("Implement {feature}", dim: true),   // dim placeholder
            plain("  gpt-5.5 default · /private/tmp"),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    func testCodexDimPlaceholderIsClear() {
        let screen = AttributedScreen(lines: [
            plain("│ >_ OpenAI Codex (v0.144.1)            │"),
            codexComposer("Explain this codebase", dim: true),
            plain("  gpt-5.5 default · /tmp"),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    func testCodexPlainTypedIsUserTyping() {
        let screen = AttributedScreen(lines: [
            plain("│ >_ OpenAI Codex (v0.144.1)            │"),
            codexComposer("refactor the parser", dim: false),
            plain("  gpt-5.5 default · /tmp"),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("refactor the parser"))
    }

    func testCodexMarkerOnlyIsClear() {
        let screen = AttributedScreen(lines: [
            plain("│ >_ OpenAI Codex (v0.144.1)            │"),
            plain("\u{203A} "),                              // just the marker, nothing typed
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    func testCodexComposerWinsOverBannerBottomUp() {
        // The banner `│ >_ …` sits ABOVE the `›` composer and a footer below; the bottom-up `›`
        // scan must find the composer and ignore the banner entirely.
        let screen = AttributedScreen(lines: [
            plain("│ >_ OpenAI Codex (v0.144.1)            │"),
            plain("• earlier transcript output"),
            codexComposer("fix the crash", dim: false),
            plain("  gpt-5.5 default · /tmp"),               // footer below composer
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("fix the crash"))
    }

    // MARK: the initial prompt is never held forever

    private func waitUntil(_ deadline: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testInitialPromptFailsOpenOnPersistentUserTyping() async throws {
        // Even if the input line reads .userTyping forever (a probe that never clears), the
        // first-turn task rides start()→deliverInitialPrompt→inject and MUST fail-open
        // within injectMaxQueueWait, never hang — pinning that the fail-open safety net is
        // intact through the real delivery path.
        let b = FakeBackend()
        b.attributed = AttributedScreen(lines: [   // a persistent human-typing line (holds until cap)
            plain(String(repeating: "\u{2500}", count: 60)),
            AttributedLine(text: "\u{276F} half typed by the human",
                           dim: Array(repeating: false, count: "\u{276F} half typed by the human".count)),
            plain(String(repeating: "\u{2500}", count: 60)),
        ])
        XCTAssertEqual(RealCell.probeInputLine(b.attributed!), .userTyping("half typed by the human"))
        let cell = RealCell(nodeID: NodeID("n1"),
                            launch: LaunchSpec(executable: "/bin/echo", args: [], env: [:]),
                            cwd: "/tmp", backend: b,
                            initialPrompt: "the first-turn task",
                            injectPollInterval: 0.02,
                            injectMaxQueueWait: 0.3,
                            injectHoldNoticeDelay: 0.05,
                            initialPromptReadyTimeout: 0.2,
                            onExit: { _, _ in })
        await cell.start()
        await waitUntil { b.sent.count >= 2 }
        XCTAssertEqual(b.sent, ["the first-turn task", "\r"],
                       "initial prompt must fail-open (never held forever) — root cause B safety net")
    }
}
