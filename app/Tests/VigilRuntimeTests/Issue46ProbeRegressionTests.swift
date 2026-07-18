import XCTest
@testable import VigilRuntime

/// claude does not reliably emit SGR-2 dim for its `Try "…"` placeholder; under a Vigil forkpty
/// it can render as plain text. The input-line probe must detect the placeholder by TEXT, not
/// by dim styling, so an undim placeholder still reads as `.clear` rather than `.userTyping`.
/// These tests pin both the synthetic non-dim form and real captured 2.1.206 byte streams
/// (dim + non-dim), fed through the exact HostScreenParser (VtScreen) scrape the GUI uses.
final class Issue46ProbeRegressionTests: XCTestCase {

    // MARK: synthetic — a claude empty box whose placeholder carries NO dim (SGR-2 absent)

    private func rule(_ n: Int = 60) -> AttributedLine {
        AttributedLine(text: String(repeating: "\u{2500}", count: n), dim: Array(repeating: false, count: n))
    }
    /// `❯\u{a0}Try "…"` with EVERY cell dim=false — the forkpty render (no SGR-2 anywhere).
    private func nonDimPlaceholder(_ content: String) -> AttributedLine {
        let text = "\u{276F}\u{a0}" + content
        return AttributedLine(text: text, dim: Array(repeating: false, count: text.count))
    }

    func testNonDimPlaceholderIsClear() {
        // An undim placeholder must still read as .clear, recognized by its `Try "…"` text.
        let screen = AttributedScreen(lines: [
            rule(), nonDimPlaceholder("Try \"refactor <filepath>\""), rule(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    func testNonDimRealUserTypingStillHolds() {
        // A genuine human line (no dim, not the placeholder shape) must still read userTyping —
        // mid-typed input must not be misread as the placeholder.
        let screen = AttributedScreen(lines: [
            rule(), nonDimPlaceholder("fix the flaky parse test"), rule(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .userTyping("fix the flaky parse test"))
    }

    func testNonDimUserTypingTryLiteralIsTheAcceptedFalsePositive() {
        // Documented tradeoff: a human typing exactly `Try "…"` reads as .clear. Pinned so the
        // tradeoff is a decision, not an accident.
        let screen = AttributedScreen(lines: [
            rule(), nonDimPlaceholder("Try \"this exact thing\""), rule(),
        ])
        XCTAssertEqual(RealCell.probeInputLine(screen), .clear)
    }

    // MARK: real captured 2.1.206 byte streams through the production scrape (VtScreen)

    private func probeCapture(_ resource: String) throws -> RealCell.InputLineProbe {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "raw"),
              let data = try? Data(contentsOf: url) else {
            throw XCTSkip("missing fixture \(resource).raw")
        }
        let parser = HostScreenParser(cols: 120, rows: 40)
        parser.feed(data)
        let sem = DispatchSemaphore(value: 0); parser.afterPending { sem.signal() }; _ = sem.wait(timeout: .now() + 5)
        return RealCell.probeInputLine(parser.renderAttributed())
    }

    func testRealNonDimCaptureIsClear() throws {
        // This captured byte stream has claude emitting the placeholder with no SGR-2.
        XCTAssertEqual(try probeCapture("claude-2.1.206-input-nondim"), .clear)
    }

    func testRealDimCaptureIsClear() throws {
        // The other real render (placeholder WAS dim) — must also read clear (dim path).
        XCTAssertEqual(try probeCapture("claude-2.1.206-input-dim"), .clear)
    }
}
