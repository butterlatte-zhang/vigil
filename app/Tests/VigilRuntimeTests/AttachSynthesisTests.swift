import XCTest
@testable import VigilRuntime

/// Attach-time reconstruction of a cell's terminal state. Attach must not depend on a bounded
/// byte history — replaying a truncated stream into a fresh surface can start mid-sequence and
/// leave a TUI's absolute-position repaints with no base frame to draw onto, producing garbled
/// output.
///
/// Attach **synthesizes** a clean VT stream from the parser's screen STATE (tmux-style): clear
/// → scrollback history → active grid (with per-cell SGR) → cursor. The synthesized bytes are
/// volume-independent, so they can never truncate.
///
/// The judge is self-consistency: feed a known stream into parser A, synthesize, feed the
/// synthesis into a fresh parser B, and B's screen must equal A's — grid text, per-cell style
/// (via the snapshot), cursor, and the alt-screen / bracketed-paste modes. No lit screen
/// required (pure `VtScreen` on its serial queue, same discipline as the other scrape tests).
final class AttachSynthesisTests: XCTestCase {

    private let esc = "\u{1b}"

    /// Round-trip a byte stream through synthesis and return (source, reparsed) parsers.
    private func roundTrip(_ bytes: String, cols: Int = 80, rows: Int = 24)
        -> (a: HostScreenParser, b: HostScreenParser) {
        let a = HostScreenParser(cols: cols, rows: rows)
        a.feed(Data(bytes.utf8))
        let b = HostScreenParser(cols: cols, rows: rows)
        b.feed(a.synthesize())
        return (a, b)
    }

    /// The core contract: the reparsed ACTIVE grid equals the source — text AND per-cell style.
    private func assertActiveEqual(_ a: HostScreenParser, _ b: HostScreenParser,
                                   _ msg: String = "", file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertEqual(b.renderScreen(), a.renderScreen(),
                       "grid text mismatch \(msg)", file: file, line: line)
        XCTAssertEqual(b.snapshot().active, a.snapshot().active,
                       "active cell/style mismatch \(msg)", file: file, line: line)
    }

    // MARK: - T1: synthesizer self-consistency (grid text + style)

    func testPlainTextRoundTrips() {
        let (a, b) = roundTrip("\(esc)[2J\(esc)[Hhello world\r\nsecond line\r\nthird")
        assertActiveEqual(a, b)
        XCTAssertEqual(a.renderScreen().split(separator: "\n").first, "hello world")
    }

    /// Colors + attributes (fg palette / fg rgb / bold / faint / italic) must round-trip
    /// cell-for-cell — the snapshot equality includes the full `SynthStyle`.
    func testColorsAndAttributesRoundTrip() {
        let styled =
            "\(esc)[31mred\(esc)[0m " +          // fg palette 1
            "\(esc)[38;5;208morange\(esc)[0m " + // fg 256-color
            "\(esc)[38;2;10;20;30mrgb\(esc)[0m " + // fg truecolor
            "\(esc)[1mbold\(esc)[0m " +
            "\(esc)[2mfaint\(esc)[0m " +
            "\(esc)[3mital\(esc)[0m " +
            "\(esc)[44mbgblue\(esc)[0m"
        let (a, b) = roundTrip("\(esc)[2J\(esc)[H" + styled)
        assertActiveEqual(a, b, "styled runs")
        // dim mask survives too (the probe input).
        XCTAssertEqual(b.renderAttributed().lines.map(\.dim),
                       a.renderAttributed().lines.map(\.dim), "dim mask mismatch")
    }

    func testCursorPositionRoundTrips() {
        // Draw, then park the cursor at row 5 col 12 (1-based CUP).
        let (a, b) = roundTrip("\(esc)[2J\(esc)[Hcontent\(esc)[5;12H")
        XCTAssertEqual(b.snapshot().cursorX, a.snapshot().cursorX, "cursor x")
        XCTAssertEqual(b.snapshot().cursorY, a.snapshot().cursorY, "cursor y")
        XCTAssertEqual(a.snapshot().cursorY, 4)
        XCTAssertEqual(a.snapshot().cursorX, 11)
    }

    /// Unwritten middle gap (cursor-forward) → real spaces, index-aligned, round-trips.
    func testUnwrittenGapRoundTrips() {
        let (a, b) = roundTrip("A\(esc)[10GB")
        assertActiveEqual(a, b, "cursor-forward gap")
        XCTAssertEqual(a.renderScreen().split(separator: "\n").first, "A        B")
    }

    func testWideCharRoundTrips() {
        let (a, b) = roundTrip("\(esc)[2J\(esc)[H日本語 test 世界")
        assertActiveEqual(a, b, "wide CJK")
    }

    // MARK: - T1: overflow regression (the whole point)

    /// A TUI-style redraw stream: 400 full-screen repaints via CUP-home + rewrite (~800 KB of
    /// input) — comfortably past any bounded-history budget. State synthesis reads only the
    /// FINAL grid, so it is immune to output volume: the reparsed screen still equals the source.
    func testSynthesisSurvivesBeyondOldRingLimit() {
        let cols = 80, rows = 24
        var stream = "\(esc)[2J"
        let filler = String(repeating: "x", count: cols - 8)
        for i in 0..<400 {
            stream += "\(esc)[H"                       // home — overwrite in place
            for r in 0..<rows {
                stream += "\(esc)[\(r + 1);1H"        // CUP row
                stream += String(format: "%03d ", i) + "r\(r) " + filler
            }
        }
        // Final distinguishing frame so we can assert exact content.
        stream += "\(esc)[H\(esc)[2J\(esc)[HFINAL-FRAME iteration done"
        XCTAssertGreaterThan(stream.utf8.count, 512 * 1024, "must exceed the old ring limit")

        let a = HostScreenParser(cols: cols, rows: rows)
        a.feed(Data(stream.utf8))
        let b = HostScreenParser(cols: cols, rows: rows)
        b.feed(a.synthesize())
        assertActiveEqual(a, b, "post-512KB overflow")
        XCTAssertEqual(a.renderScreen().split(separator: "\n").first, "FINAL-FRAME iteration done")
    }

    /// Draw the TOP half (rows 1-12) once, then > 512 KB of grid-neutral padding (SGR resets —
    /// no cell change, no scroll), then the BOTTOM half (rows 13-24). A never-overwritten early
    /// region must not be lost regardless of how much output follows it — synthesis reads the
    /// FINAL grid STATE, so the whole grid reconstructs regardless of output volume.
    func testSynthesisKeepsUnhealedHeadBeyondOldRingLimit() {
        let cols = 80, rows = 24
        var stream = "\(esc)[2J"
        for r in 1...12 { stream += "\(esc)[\(r);1HTOP row \(r) content" }   // early, never redrawn
        stream += String(repeating: "\(esc)[0m", count: 140_000)             // > 512 KB, grid-neutral
        for r in 13...24 { stream += "\(esc)[\(r);1HBOT row \(r) content" }
        XCTAssertGreaterThan(stream.utf8.count, 512 * 1024, "must exceed the old ring limit")

        let a = HostScreenParser(cols: cols, rows: rows)
        a.feed(Data(stream.utf8))
        XCTAssertTrue(a.renderScreen().contains("TOP row 1 content"), "source has the top half")

        let b = HostScreenParser(cols: cols, rows: rows)
        b.feed(a.synthesize())
        XCTAssertEqual(b.renderScreen(), a.renderScreen(),
                       "synthesis reconstruction must MATCH source (unhealed head intact)")
        XCTAssertTrue(b.renderScreen().contains("TOP row 1 content"),
                      "the early, never-overwritten head survives synthesis")
    }

    // MARK: - T1: INV3 cut-point atomicity

    /// The attach cut point (`synthesize()` on the PTY read queue): the snapshot must capture
    /// EXACTLY the bytes fed up to that instant, and live bytes must resume STRICTLY after — no
    /// loss, no duplication (INV3). This models the real read-queue converge sequence
    /// deterministically:
    ///   • pre-attach bytes → parser.feed (source + would-be surface both had them)
    ///   • attach gate ON — "during-gate" bytes → parser.feed ONLY (the surface is held; those
    ///     bytes live only in the parser STATE now, exactly what synthesis must recover)
    ///   • converge (cut point) → surface.feed(source.synthesize())
    ///   • gate OFF — "post-gate" live bytes → BOTH parser.feed and surface.feed
    /// The reconstructed surface must equal the source screen: during-gate bytes appear exactly
    /// once (via synthesis, never re-fed live), post-gate bytes exactly once (via live, never in
    /// the snapshot). A snapshot that missed a held byte, or one that duplicated a live byte,
    /// diverges here.
    func testCutPointAtomicity() {
        let source = HostScreenParser(cols: 80, rows: 24)
        let surface = HostScreenParser(cols: 80, rows: 24)

        // Pre-attach base frame (both screens would already show this).
        source.feed(Data("\(esc)[2J\(esc)[Hbase line one\r\nbase line two".utf8))

        // During the attach gate: live bytes arrive; the parser eats them, the surface is held.
        // Includes a cursor move so the snapshot must restore cursor position, not just text.
        source.feed(Data("\r\nDURING gate line\(esc)[5;3Hmid-region".utf8))

        // Converge: snapshot the source at the cut point and replay it into the surface.
        surface.feed(source.synthesize())

        // Gate lifted: live bytes now flow to BOTH, continuing from the (restored) cursor.
        let post = "\r\nPOST gate live tail\(esc)[2;1Hedit"
        source.feed(Data(post.utf8))
        surface.feed(Data(post.utf8))

        XCTAssertEqual(surface.renderScreen(), source.renderScreen(),
                       "held bytes exactly once (snapshot) + live bytes exactly once (post-gate)")
        XCTAssertEqual(surface.snapshot().active, source.snapshot().active, "cell/style parity")
        XCTAssertEqual(surface.snapshot().cursorX, source.snapshot().cursorX, "cursor x parity")
        XCTAssertEqual(surface.snapshot().cursorY, source.snapshot().cursorY, "cursor y parity")
    }

    // MARK: - T1: modes preserved (alt-screen, bracketed paste)

    /// Alt-screen apps: entering the alternate screen must survive synthesis so the child's
    /// post-attach repaint lands in the right buffer. The alt grid itself round-trips too.
    func testAltScreenPreserved() {
        let (a, b) = roundTrip("\(esc)[?1049h\(esc)[2J\(esc)[Hvim-like alt frame\r\n~\r\n~")
        XCTAssertTrue(a.snapshot().altScreen, "source should be on alt screen")
        XCTAssertTrue(b.snapshot().altScreen, "alt screen must survive synthesis")
        assertActiveEqual(a, b, "alt grid")
    }

    /// Bracketed-paste (DEC 2004) is the injection-wrap truth; it must survive synthesis.
    func testBracketedPastePreserved() {
        let (a, b) = roundTrip("\(esc)[?2004hprompt> ")
        XCTAssertTrue(a.bracketedPasteMode)
        XCTAssertTrue(b.bracketedPasteMode, "bracketed-paste mode must survive synthesis")
    }

    // MARK: - input-affecting DEC modes (alt-scroll history-recall trap)

    /// A TUI that sits on the alternate screen with mouse tracking ON (claude 2.1.x sends
    /// `?1049h` then `?1000h ?1002h ?1003h ?1006h`) must come back that way. If the
    /// synthesized surface believes mouse tracking is OFF while the alt screen is ON, ghostty's
    /// `mouse_alternate_scroll` (mode 1007, default on) turns every wheel tick into a cursor
    /// key: the child receives Up/Down it never asked for, and claude fills the input box with
    /// a history prompt (observed on background-born workers at first select).
    func testMouseAndFocusModesSurviveSynthesis() {
        let modes = "?1049h", tail = "?1000h\(esc)[?1002h\(esc)[?1003h\(esc)[?1006h\(esc)[?1004h\(esc)[?2031h"
        let (a, b) = roundTrip("\(esc)[\(modes)\(esc)[\(tail)\(esc)[2J\(esc)[H> ")
        for m: UInt16 in [1000, 1002, 1003, 1006, 1004, 2031] {
            XCTAssertTrue(a.mode(m), "source should have mode \(m) set")
            XCTAssertTrue(b.mode(m), "mode \(m) must survive synthesis")
        }
        XCTAssertTrue(b.snapshot().altScreen)
        XCTAssertTrue(b.mouseTracking, "mouse tracking flag must be live on the reparsed screen")
    }

    /// Modes the child never touched must not be invented (no spurious `h`), and a mode the
    /// child explicitly turned OFF that defaults ON (1007 alternate scroll, 7 autowrap) must
    /// come back OFF.
    func testUntouchedAndResetModesRoundTrip() {
        let fresh = HostScreenParser(cols: 80, rows: 24)
        XCTAssertTrue(fresh.mode(1007), "precondition: alternate-scroll defaults ON in the parser")
        XCTAssertTrue(fresh.mode(7), "precondition: autowrap defaults ON in the parser")
        let (a, b) = roundTrip("\(esc)[?1007l\(esc)[?7l\(esc)[?1h\(esc)[?66hplain")
        for m: UInt16 in [1007, 7] {
            XCTAssertFalse(a.mode(m)); XCTAssertFalse(b.mode(m), "mode \(m) must stay OFF after synthesis")
        }
        for m: UInt16 in [1, 66] {
            XCTAssertTrue(b.mode(m), "mode \(m) must survive synthesis")
        }
        for m: UInt16 in [1000, 1002, 1003, 1004, 1006, 2031] {
            XCTAssertFalse(b.mode(m), "mode \(m) was never set and must not be invented")
        }
        XCTAssertFalse(b.mouseTracking)
    }

    /// Pure-serializer contract: only modes that differ from the parser defaults are emitted
    /// (an untouched mode must keep the surface's own default — 2027 is ON on a real ghostty
    /// surface under `grapheme-width-method = unicode` but OFF in the parser, so an explicit
    /// `?2027l` would downgrade rendering), resets (`l`) precede sets (`h`) so a later reset can
    /// never clobber a mouse-format/tracking set, and nothing in it is a query.
    func testSerializerEmitsOnlyChangedModesResetsBeforeSets() {
        var snap = ScreenSnapshot(cols: 4, rows: 1, history: [], active: [SynthRow(cells: [])],
                                  cursorX: 0, cursorY: 0, cursorVisible: true, altScreen: false,
                                  bracketedPaste: false)
        snap.modes = VtScreen.synthModeDefaults
        snap.modes[1003] = true; snap.modes[1006] = true; snap.modes[1007] = false
        let out = String(decoding: AttachScreenSynthesizer.serialize(snap), as: UTF8.self)
        let l1007 = out.range(of: "\(esc)[?1007l"), h1003 = out.range(of: "\(esc)[?1003h")
        XCTAssertNotNil(l1007); XCTAssertNotNil(h1003); XCTAssertNotNil(out.range(of: "\(esc)[?1006h"))
        XCTAssertLessThan(l1007!.lowerBound, h1003!.lowerBound, "resets must precede sets")
        for n in [2027, 12, 1005, 1, 66, 2031] {
            XCTAssertFalse(out.contains("\(esc)[?\(n)l"), "untouched mode \(n) must not be replayed")
            XCTAssertFalse(out.contains("\(esc)[?\(n)h"), "untouched mode \(n) must not be replayed")
        }
        XCTAssertFalse(out.contains("\(esc)[?7h"), "default-on mode at default must not be replayed")
        XCTAssertFalse(out.contains("\(esc)[c"), "never a query")
        XCTAssertFalse(out.contains("\(esc)[6n"), "never a query")
    }

    /// The defaults table the serializer diffs against must match the vendored parser's real
    /// reset values — pins the table to the libghostty-vt build so an upgrade cannot drift it.
    func testSynthModeDefaultsMatchParser() {
        let fresh = HostScreenParser(cols: 80, rows: 24)
        for m in VtScreen.synthModes {
            XCTAssertEqual(fresh.mode(m), VtScreen.synthModeDefaults[m], "default of mode \(m)")
        }
        XCTAssertEqual(Set(VtScreen.synthModeDefaults.keys), Set(VtScreen.synthModes))
    }

    /// Real-machine regression: the actual claude 2.1.263 startup stream (alt screen + mouse
    /// tracking + focus reporting + color-scheme reports) must come out of synthesis in the
    /// same input regime, and the synthesized bytes must set the mouse family explicitly —
    /// the exact state that keeps ghostty from converting wheel ticks into cursor keys.
    func testRealClaude263StartupStreamKeepsInputRegime() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "claude-2.1.263-startup-altscreen-mouse", withExtension: "raw"))
        let raw = try Data(contentsOf: url)
        let a = HostScreenParser(cols: 120, rows: 40)
        a.feed(raw)
        XCTAssertTrue(a.snapshot().altScreen, "precondition: claude sits on the alt screen")
        XCTAssertTrue(a.mouseTracking, "precondition: claude enabled mouse tracking")
        for m: UInt16 in [1000, 1002, 1003, 1006, 1004, 2031] {
            XCTAssertTrue(a.mode(m), "precondition: capture sets mode \(m)")
        }
        let synth = a.synthesize()
        let text = String(decoding: synth, as: UTF8.self)
        for m in [1000, 1002, 1003, 1006, 1004, 2031] {
            XCTAssertTrue(text.contains("\(esc)[?\(m)h"), "synthesis must set mode \(m)")
        }
        XCTAssertFalse(text.contains("\(esc)[?2027l"), "untouched 2027 must not be downgraded")
        let b = HostScreenParser(cols: 120, rows: 40)
        b.feed(synth)
        XCTAssertTrue(b.snapshot().altScreen)
        XCTAssertTrue(b.mouseTracking, "reparsed surface must have mouse tracking live")
        for m: UInt16 in [1000, 1002, 1003, 1006, 1004, 2031] { XCTAssertTrue(b.mode(m)) }
        assertActiveEqual(a, b, "real claude frame")
    }

    /// Kitty keyboard protocol flags (codex/opencode-style TUIs push `CSI > flags u`) are part
    /// of the surface→PTY key encoding and must survive too.
    func testKittyKeyboardFlagsSurviveSynthesis() {
        let (a, b) = roundTrip("\(esc)[>1uprompt")
        XCTAssertEqual(a.kittyKeyboardFlags, 1, "precondition: parser tracks CSI > u push")
        XCTAssertEqual(b.kittyKeyboardFlags, 1, "kitty flags must survive synthesis")
    }

    // MARK: - scrollback capture (pins the max_scrollback unit)

    /// The parser retains scrollback. Feeding many lines into a short screen accumulates
    /// scrollback rows, and synthesis reproduces that history in the reparsed screen. 3000 short
    /// lines into a 24-row screen leaves ~2976 in scrollback, well under the 2 MB byte budget
    /// (the libghostty-vt `max_scrollback` unit is bytes of packed cell storage, not rows — see
    /// `VtScreen.maxScrollbackBytes`).
    func testScrollbackAccumulatesAndSynthesizes() {
        let cols = 80, rows = 24
        var stream = "\(esc)[2J\(esc)[H"
        for i in 0..<3000 { stream += "line-\(i)\r\n" }
        let a = HostScreenParser(cols: cols, rows: rows)
        a.feed(Data(stream.utf8))
        let sb = a.snapshot().history.count
        // Substantial history is retained (exact cap is page-granular in libghostty-vt; the
        // memory budget is tuned for typical session sizes).
        XCTAssertGreaterThan(sb, 500, "scrollback should retain a large chunk of history")

        let b = HostScreenParser(cols: cols, rows: rows)
        b.feed(a.synthesize())
        assertActiveEqual(a, b, "visible grid after scrollback")
        // History round-trips: the reparsed screen carries a comparable scrollback depth and
        // the same recent history lines.
        XCTAssertGreaterThan(b.snapshot().history.count, 500, "synthesized history depth")
        XCTAssertEqual(b.snapshot().history.suffix(5), a.snapshot().history.suffix(5),
                       "most-recent scrollback lines must round-trip")
    }
}
