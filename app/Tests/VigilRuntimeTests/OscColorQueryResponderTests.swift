import XCTest
@testable import VigilRuntime

/// codex (≥0.144) and opencode both query the terminal's foreground/background color via
/// OSC 10/11 (`ESC]10;?` / `ESC]11;?`, verified by `strings` on both binaries) at boot to
/// pick a light/dark render palette. A live ghostty surface answers this itself once
/// attached; a background-spawned worker is born with no surface and nobody answers, so
/// the agent silently falls back to the wrong palette. `OscColorQueryResponder` is the
/// host-side stand-in that answers on its behalf while unattached. It sits on the raw PTY
/// byte stream and is agent-agnostic by construction (byte-level match, no knowledge of
/// which binary is on the other end) — these tests exercise it directly with synthetic
/// bytes, never branching on agent kind.
final class OscColorQueryResponderTests: XCTestCase {

    private let fg = "rgb:eded/eded/eded"
    private let bg = "rgb:1616/1717/1919"

    private func makeResponder(attached: Bool = false) -> (OscColorQueryResponder, () -> [Data]) {
        var replies: [Data] = []
        let responder = OscColorQueryResponder(
            foregroundColor: fg,
            backgroundColor: bg,
            isAttached: { attached },
            respond: { replies.append($0) })
        return (responder, { replies })
    }

    private func makeResponder(source: TerminalColorSource)
        -> (OscColorQueryResponder, () -> [Data]) {
        var replies: [Data] = []
        let responder = OscColorQueryResponder(
            colorSource: source,
            respond: { replies.append($0) })
        return (responder, { replies })
    }

    // MARK: - OSC 10 / 11 basic answer + color correctness

    func testOSC10QueryAnswersWithForegroundColorBEL() {
        let (r, replies) = makeResponder()
        r.feed(Data("\u{1B}]10;?\u{07}".utf8))
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    func testOSC11QueryAnswersWithBackgroundColorBEL() {
        let (r, replies) = makeResponder()
        r.feed(Data("\u{1B}]11;?\u{07}".utf8))
        XCTAssertEqual(replies(), [Data("\u{1B}]11;\(bg)\u{07}".utf8)])
    }

    // MARK: - Terminator mirrors the query (xterm semantics)

    func testSTTerminatorIsMirroredBack() {
        let (r, replies) = makeResponder()
        r.feed(Data("\u{1B}]10;?\u{1B}\\".utf8))
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{1B}\\".utf8)],
                       "a query terminated with ST must be answered with ST, not BEL")
    }

    func testBELTerminatorIsMirroredBack() {
        let (r, replies) = makeResponder()
        r.feed(Data("\u{1B}]11;?\u{07}".utf8))
        XCTAssertEqual(replies(), [Data("\u{1B}]11;\(bg)\u{07}".utf8)],
                       "a query terminated with BEL must be answered with BEL, not ST")
    }

    // MARK: - Cross-chunk splitting (real reads can cut the sequence anywhere)

    func testQuerySplitAcrossManyChunksStillMatches() {
        let (r, replies) = makeResponder()
        let query = "\u{1B}]10;?\u{07}"
        for byte in query.utf8 {
            r.feed(Data([byte]))     // worst case: one byte per read()
        }
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    func testTwoQueriesSplitAtArbitraryChunkBoundary() {
        let (r, replies) = makeResponder()
        let full = "\u{1B}]11;?\u{07}"
        let idx = full.utf8.index(full.utf8.startIndex, offsetBy: 3)
        r.feed(Data(full.utf8[..<idx]))
        r.feed(Data(full.utf8[idx...]))
        XCTAssertEqual(replies(), [Data("\u{1B}]11;\(bg)\u{07}".utf8)])
    }

    // MARK: - Attach state gates the answer (ghostty itself answers once attached)

    func testNoAnswerWhileSurfaceIsAttached() {
        let (r, replies) = makeResponder(attached: true)
        r.feed(Data("\u{1B}]10;?\u{07}".utf8))
        r.feed(Data("\u{1B}]11;?\u{07}".utf8))
        XCTAssertTrue(replies().isEmpty, "a live surface answers for itself; the host must stay quiet")
    }

    // MARK: - Actual surface delivery owns each complete query

    func testDynamicColorSourceUpdateIsUsedByLaterQueries() {
        let source = TerminalColorSource()
        let (r, replies) = makeResponder(source: source)
        let newFG = "rgb:1111/2222/3333"
        let newBG = "rgb:aaaa/bbbb/cccc"

        r.feed(Data("\u{1B}]10;?\u{07}".utf8), surfaceDidReceive: false)
        XCTAssertTrue(replies().isEmpty, "an initially empty live source stays inert")

        source.update(foreground: newFG, background: newBG)
        let colors = source.snapshot()
        XCTAssertEqual(colors.fg, newFG)
        XCTAssertEqual(colors.bg, newBG)

        r.feed(Data("\u{1B}]10;?\u{07}".utf8), surfaceDidReceive: false)
        r.feed(Data("\u{1B}]11;?\u{07}".utf8), surfaceDidReceive: false)
        XCTAssertEqual(replies(), [
            Data("\u{1B}]10;\(newFG)\u{07}".utf8),
            Data("\u{1B}]11;\(newBG)\u{07}".utf8),
        ])
    }

    func testQuerySplitFromNotReceivedToReceivedStillGetsOneHostReply() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        r.feed(Data("\u{1B}]10;".utf8), surfaceDidReceive: false)
        r.feed(Data("?\u{07}".utf8), surfaceDidReceive: true)
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    func testQuerySplitFromReceivedToNotReceivedStillGetsOneHostReply() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        r.feed(Data("\u{1B}]11;".utf8), surfaceDidReceive: true)
        r.feed(Data("?\u{07}".utf8), surfaceDidReceive: false)
        XCTAssertEqual(replies(), [Data("\u{1B}]11;\(bg)\u{07}".utf8)])
    }

    func testQueryWhollyReceivedBySurfaceGetsNoHostReply() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        r.feed(Data("\u{1B}]10;".utf8), surfaceDidReceive: true)
        r.feed(Data("?\u{07}".utf8), surfaceDidReceive: true)
        XCTAssertTrue(replies().isEmpty)
    }

    func testQuerySplitAcrossTwoSurfaceGenerationsGetsOneHostReply() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        r.feed(Data("\u{1B}]10;".utf8), surfaceGeneration: 41)
        r.feed(Data("?\u{07}".utf8), surfaceGeneration: 42)
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    func testQueryWhollyMissedBySurfaceGetsExactlyOneHostReply() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        for byte in "\u{1B}]10;?\u{07}".utf8 {
            r.feed(Data([byte]), surfaceDidReceive: false)
        }
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    func testAbortedUndeliveredCandidateDoesNotTaintNextDeliveredQuery() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        r.feed(Data("\u{1B}]10;?x".utf8), surfaceDidReceive: false)
        r.feed(Data("\u{1B}]11;?\u{07}".utf8), surfaceDidReceive: true)
        XCTAssertTrue(replies().isEmpty)
    }

    func testSTQueryWhollyReceivedBySurfaceGetsNoHostReply() {
        let source = TerminalColorSource(foreground: fg, background: bg)
        let (r, replies) = makeResponder(source: source)
        r.feed(Data("\u{1B}]10;?".utf8), surfaceDidReceive: true)
        r.feed(Data("\u{1B}\\".utf8), surfaceDidReceive: true)
        XCTAssertTrue(replies().isEmpty)
    }

    // MARK: - No theme = no answer (test/smoke/parity paths, current behavior preserved)

    func testNoAnswerWhenNoColorsConfiguredAtAll() {
        let responder = OscColorQueryResponder(foregroundColor: nil, backgroundColor: nil,
                                               isAttached: { false }, respond: { _ in
            XCTFail("must not respond when neither color is configured (nil theme)")
        })
        responder.feed(Data("\u{1B}]10;?\u{07}".utf8))
        responder.feed(Data("\u{1B}]11;?\u{07}".utf8))
    }

    func testNoAnswerForQueryWithNoConfiguredColorButOtherColorConfigured() {
        var replies: [Data] = []
        let responder = OscColorQueryResponder(foregroundColor: fg, backgroundColor: nil,
                                               isAttached: { false },
                                               respond: { replies.append($0) })
        responder.feed(Data("\u{1B}]11;?\u{07}".utf8))   // background query, but bg is nil
        XCTAssertTrue(replies.isEmpty)
        responder.feed(Data("\u{1B}]10;?\u{07}".utf8))   // foreground query, fg IS configured
        XCTAssertEqual(replies, [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    // MARK: - Non-query bytes are inert (this is a passive scanner, never a filter)

    func testOrdinaryOutputNeverTriggersAResponse() {
        let (r, replies) = makeResponder()
        let noise = "\u{1B}[2J\u{1B}[HHello, world!\r\nWorking on it...\r\n\u{1B}[31mred text\u{1B}[0m\n"
        r.feed(Data(noise.utf8))
        XCTAssertTrue(replies().isEmpty)
    }

    func testEscapeSequencesThatLookAlikeButArentOSC10Or11DontMatch() {
        let (r, replies) = makeResponder()
        // OSC 12 (cursor color) — same family, different code, must NOT match.
        r.feed(Data("\u{1B}]12;?\u{07}".utf8))
        // CSI sequence right after a bare ESC — must not be confused with `ESC ]`.
        r.feed(Data("\u{1B}[31m".utf8))
        XCTAssertTrue(replies().isEmpty)
    }

    func testQueryEmbeddedInOrdinaryOutputStillMatches() {
        let (r, replies) = makeResponder()
        var data = Data("some banner text\r\n".utf8)
        data.append(Data("\u{1B}]10;?\u{07}".utf8))
        data.append(Data("more text after\r\n".utf8))
        r.feed(data)
        XCTAssertEqual(replies(), [Data("\u{1B}]10;\(fg)\u{07}".utf8)])
    }

    func testAlmostMatchThenRealMatchInSameChunk() {
        let (r, replies) = makeResponder()
        // A truncated/aborted OSC 10 query (no terminator, interrupted by an unrelated ESC),
        // immediately followed by a real, complete OSC 11 query — the state machine must
        // recover from the abort and still catch the real one.
        var data = Data("\u{1B}]10;".utf8)
        data.append(Data("\u{1B}]11;?\u{07}".utf8))
        r.feed(data)
        XCTAssertEqual(replies(), [Data("\u{1B}]11;\(bg)\u{07}".utf8)])
    }
}
