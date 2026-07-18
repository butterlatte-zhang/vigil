import XCTest
@testable import VigilRuntime

/// `renderAttributed()` (per-cell dim) acceptance + unit coverage.
///
/// The scrape source is the host-side libghostty-vt parser (`HostScreenParser`), whose
/// `GhosttyStyle.faint` carries the `.dim` bit (SGR 2). On real claude 2.1.205 bytes,
/// the dim placeholder line reads dim=true while user-typed text reads dim=false — the
/// foothold for the input-line probe. No GUI, deterministic (feed then a queue.sync render
/// observes it — FIFO on the parser's serial queue).
final class AttributedScreenTests: XCTestCase {

    private let esc = "\u{1b}"

    /// feed(async) then renderAttributed(sync) on the same serial queue → the render always
    /// observes the feed (no polling needed).
    private func render(_ bytes: String, cols: Int = 80, rows: Int = 24) -> AttributedScreen {
        let parser = HostScreenParser(cols: cols, rows: rows)
        parser.feed(Data(bytes.utf8))
        return parser.renderAttributed()
    }

    private func line(_ screen: AttributedScreen, containing needle: String) -> AttributedLine? {
        screen.lines.first { $0.text.contains(needle) }
    }

    // MARK: - root acceptance line: real captured bytes from claude 2.1.205

    /// The real captured shape: `❯` + NBSP(U+00A0) + ESC[2m + placeholder. The prefix (`❯`,
    /// NBSP) is NOT dim (dim turns on AFTER the NBSP); only the `Try "…"` payload is dim.
    /// After stripping the mode prefix, EVERY remaining content cell must read dim=true.
    func testRealClaudePlaceholderIsDim() {
        // Exactly the real captured bytes: ❯ \xc2\xa0 \x1b[2m Try "…"
        let placeholder = "❯\u{00A0}\(esc)[2mTry \"how do I log an error?\"\(esc)[0m"
        let screen = render("\(esc)[2J\(esc)[H" + placeholder)
        guard let l = line(screen, containing: "Try") else {
            return XCTFail("placeholder line missing\n\(screen.lines.map(\.text))")
        }
        XCTAssertEqual(l.text.count, l.dim.count, "text/dim must be index-aligned")
        // Prefix: ❯ (index 0) then NBSP (index 1) — neither dim.
        XCTAssertEqual(Array(l.text)[0], "❯")
        XCTAssertEqual(Array(l.text)[1], "\u{00A0}")
        XCTAssertFalse(l.dim[0], "❯ precedes ESC[2m → not dim")
        XCTAssertFalse(l.dim[1], "NBSP precedes ESC[2m → not dim")
        // Everything from `Try` to the end is the dim placeholder payload.
        let content = l.dim[2...]
        XCTAssertTrue(content.allSatisfy { $0 }, "every placeholder content cell must be dim=true, got \(Array(l.dim))")
    }

    /// User-typed text (no ESC[2m) in the same frame shape → content dim=false.
    func testRealClaudeUserTypingIsNotDim() {
        let typed = "❯\u{00A0}fix the parse"
        let screen = render("\(esc)[2J\(esc)[H" + typed)
        guard let l = line(screen, containing: "fix the parse") else {
            return XCTFail("typed line missing\n\(screen.lines.map(\.text))")
        }
        XCTAssertEqual(l.text.count, l.dim.count)
        let content = l.dim[2...]   // drop ❯ + NBSP
        XCTAssertFalse(content.contains(true), "user-typed content must be dim=false, got \(Array(l.dim))")
    }

    // MARK: - unit tests: dim segment vs normal segment, column-by-column alignment, blank lines, trimRight

    /// A dim run followed by a normal run, same line — each cell's bit matches its SGR.
    func testDimSegmentVersusNormalSegment() {
        let screen = render("\(esc)[2mDIM\(esc)[0m NORM")
        guard let l = line(screen, containing: "DIM NORM") else {
            return XCTFail("line missing\n\(screen.lines.map(\.text))")
        }
        XCTAssertEqual(l.text, "DIM NORM")
        XCTAssertEqual(l.dim, [true, true, true, false, false, false, false, false])
    }

    /// Cursor-positioned NUL gap: unwritten middle cells render as real spaces with
    /// dim=false, and text/dim stay column-aligned across the gap.
    func testUnwrittenCellsAreSpacesWithDimFalse() {
        // "A" at col 1, cursor → col 10, "B" at col 10; cols 2–9 (8 cells) never written.
        let screen = render("A\(esc)[10GB")
        guard let l = line(screen, containing: "A") else {
            return XCTFail("line missing\n\(screen.lines.map(\.text))")
        }
        XCTAssertEqual(l.text, "A        B", "8 unwritten cells → 8 real spaces")
        XCTAssertEqual(l.text.count, l.dim.count)
        XCTAssertFalse(l.dim.contains(true), "no SGR set → all dim=false")
    }

    /// A dim gap: a dim char, an unwritten gap, then a dim char — the gap's spaces are
    /// dim=false, the written cells dim=true, all index-aligned.
    func testDimAcrossUnwrittenGapAligns() {
        let screen = render("\(esc)[2mA\(esc)[10GB\(esc)[0m")
        guard let l = line(screen, containing: "A") else {
            return XCTFail("line missing")
        }
        XCTAssertEqual(l.text, "A        B")
        XCTAssertEqual(l.text.count, l.dim.count)
        XCTAssertTrue(l.dim.first ?? false, "A is dim")
        XCTAssertTrue(l.dim.last ?? false, "B is dim")
        XCTAssertFalse(l.dim[1...8].contains(true), "the 8-cell unwritten gap is dim=false")
    }

    /// Empty row → empty text, empty dim (trimRight collapses an all-unwritten line).
    func testEmptyLine() {
        // CR+LF between rows; row 2 (index 1) is left entirely unwritten.
        let screen = render("\(esc)[2J\(esc)[Hone\r\n\r\nthree")
        XCTAssertEqual(screen.lines[0].text, "one")
        let blank = screen.lines[1]
        XCTAssertEqual(blank.text, "")
        XCTAssertEqual(blank.dim, [])
    }

    /// trimRight: trailing UNWRITTEN cells are dropped; dim length tracks the trimmed text.
    func testTrimRightKeepsDimLengthEqual() {
        let screen = render("hi")   // rest of the 80-col row is unwritten
        guard let l = line(screen, containing: "hi") else { return XCTFail("line missing") }
        XCTAssertEqual(l.text, "hi", "unwritten tail trimmed")
        XCTAssertEqual(l.dim.count, 2)
        XCTAssertEqual(l.dim, [false, false])
    }

    /// Every line's text/dim are index-aligned regardless of content.
    func testAllLinesIndexAligned() {
        let screen = render("\(esc)[2mfaint\(esc)[0m normal\nplain\n\(esc)[2mmore\(esc)[0m")
        for l in screen.lines {
            XCTAssertEqual(l.text.count, l.dim.count, "misaligned line: [\(l.text)]")
        }
    }

    // MARK: - text uses the same NUL-gap normalization as renderScreen (byte-identical)

    /// renderAttributed's text, joined by newline, is byte-identical to renderScreen() — the
    /// contract that keeps TurnWatcher/PermWatcher (which read renderScreen) and the probe
    /// (which reads renderAttributed) looking at the same screen.
    func testTextIdenticalToRenderScreen() {
        let bytes = "\(esc)[2J\(esc)[H\(esc)[2mDim line\(esc)[0m\nplain line\nA\(esc)[10GB\ntail"
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data(bytes.utf8))
        let text = parser.renderScreen()
        let attributed = parser.renderAttributed()
        XCTAssertEqual(attributed.lines.map(\.text).joined(separator: "\n"), text,
                       "renderAttributed text must match renderScreen NUL-gap normalization exactly")
    }
}
