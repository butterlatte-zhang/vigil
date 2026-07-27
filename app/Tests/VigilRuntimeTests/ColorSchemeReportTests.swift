import XCTest
@testable import VigilRuntime

/// mode-2031 dark-cell notification: the host sends an unsolicited `ESC[?997;1n`/`;2n` to a
/// DEC mode 2031 subscriber on every real theme flip, unconditionally — mounted or not. Round 1
/// (2026-07-27) gated this on `!hasSurface`, trusting a live ghostty surface's own broadcast to
/// inform a MOUNTED cell's child process; `vigil-colorflip` disproved that (a mounted surface's
/// own push was observed stuck reporting the wrong scheme, see `ColorSchemeReport.shouldSend`'s
/// doc), so round 2 removed the gate. These tests cover the three pieces `GhosttyViewBackend` wires together —
/// the DEC mode 2031 read (`VtScreen`/`HostScreenParser`), the change-only observer
/// (`TerminalColorSource`), and the encode + send-gate (`ColorSchemeReport`) — independently
/// of `GhosttyViewBackend` itself, which is macOS-surface-only and no-ops under XCTest (the
/// standard spawn guard also used by `GhosttyBackendTests`).
final class ColorSchemeReportTests: XCTestCase {

    // MARK: - a) VtScreen / HostScreenParser mode-2031 read

    func testColorSchemeReportModeOffByDefault() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        XCTAssertFalse(parser.colorSchemeReportMode)
    }

    func testColorSchemeReportModeTrueAfterDECSET2031() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        XCTAssertTrue(parser.colorSchemeReportMode)
    }

    func testColorSchemeReportModeFalseAfterDECRST2031() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        XCTAssertTrue(parser.colorSchemeReportMode)
        parser.feed(Data("\u{1B}[?2031l".utf8))
        XCTAssertFalse(parser.colorSchemeReportMode)
    }

    func testColorSchemeReportModeDoesNotAffectBracketedPasteMode() {
        // Read-only mode-truth addition — must not perturb the pre-existing bracketed-paste
        // truth or any parse semantics vigil-parity depends on.
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2004h\u{1B}[?2031h".utf8))
        XCTAssertTrue(parser.bracketedPasteMode)
        XCTAssertTrue(parser.colorSchemeReportMode)
    }

    // MARK: - b) TerminalColorSource observer: change-only, unregister stops delivery

    func testObserverFiresOnThemeChange() {
        let source = TerminalColorSource()
        var seen: [String] = []
        source.addObserver { seen.append($0) }
        source.update(terminalTheme: "dark", foreground: nil, background: nil)
        XCTAssertEqual(seen, ["dark"])
    }

    func testObserverDoesNotFireWhenThemeUnchanged() {
        let source = TerminalColorSource()
        source.update(terminalTheme: "dark", foreground: "rgb:0/0/0", background: "rgb:1/1/1")
        var seen: [String] = []
        source.addObserver { seen.append($0) }
        // Same theme string, only the color specs move (an accent change) — must not fire.
        source.update(terminalTheme: "dark", foreground: "rgb:2/2/2", background: "rgb:3/3/3")
        XCTAssertEqual(seen, [], "accent-only republish with the same theme must not notify")
    }

    func testObserverFiresOnceMorePerActualFlip() {
        let source = TerminalColorSource()
        var seen: [String] = []
        source.addObserver { seen.append($0) }
        source.update(terminalTheme: "dark", foreground: nil, background: nil)
        source.update(terminalTheme: "dark", foreground: nil, background: nil)  // no-op repeat
        source.update(terminalTheme: "light", foreground: nil, background: nil)
        source.update(terminalTheme: "dark", foreground: nil, background: nil)
        XCTAssertEqual(seen, ["dark", "light", "dark"])
    }

    func testRemovedObserverDoesNotFire() {
        let source = TerminalColorSource()
        var seen: [String] = []
        let token = source.addObserver { seen.append($0) }
        source.removeObserver(token)
        source.update(terminalTheme: "dark", foreground: nil, background: nil)
        XCTAssertEqual(seen, [], "an unregistered observer (cell death) must never be called")
    }

    func testRemoveObserverIsIdempotent() {
        let source = TerminalColorSource()
        let token = source.addObserver { _ in }
        source.removeObserver(token)
        source.removeObserver(token)   // must not crash / throw on double-teardown
    }

    func testMultipleObserversEachReceiveIndependently() {
        let source = TerminalColorSource()
        var a: [String] = []
        var b: [String] = []
        source.addObserver { a.append($0) }
        let tokenB = source.addObserver { b.append($0) }
        source.update(terminalTheme: "dark", foreground: nil, background: nil)
        source.removeObserver(tokenB)
        source.update(terminalTheme: "light", foreground: nil, background: nil)
        XCTAssertEqual(a, ["dark", "light"])
        XCTAssertEqual(b, ["dark"])
    }

    // MARK: - c) integration: gate + encode + observer wired together, fake pty sink

    /// Wires the exact same collaborators `GhosttyViewBackend` does (parser mode read,
    /// observer, gate, encode) around a plain `Data` sink standing in for `HostPTY.write`.
    /// No `hasSurface` parameter — round 2 (2026-07-27, `vigil-colorflip`) proved a mounted
    /// surface's own broadcast cannot be trusted to inform its child process, so the host push
    /// now runs unconditionally, mounted or not (see `ColorSchemeReport.shouldSend`).
    private final class Sink {
        private(set) var writes: [Data] = []
        func write(_ data: Data) { writes.append(data) }
    }

    private func wire(parser: HostScreenParser, source: TerminalColorSource, sink: Sink) {
        source.addObserver { terminalTheme in
            guard ColorSchemeReport.shouldSend(modeOn: parser.colorSchemeReportMode) else { return }
            sink.write(ColorSchemeReport.encode(isDark: terminalTheme == "dark"))
        }
    }

    func testIntegrationModeOnThemeChangeSendsReport() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, sink: sink)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [Data("\u{1B}[?997;1n".utf8)])
    }

    func testIntegrationModeOnLightFlipSendsCode2() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, sink: sink)

        source.update(terminalTheme: "light", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [Data("\u{1B}[?997;2n".utf8)])
    }

    func testIntegrationModeOffSendsNothing() {
        let parser = HostScreenParser(cols: 80, rows: 24)   // never subscribed to 2031
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, sink: sink)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [], "agent never opted into mode 2031 — host must stay silent")
    }

    // MARK: - e) integration: theme flip nudges redraw alongside (or instead of) the
    // mode-2031 push, mirroring how GhosttyViewBackend wires both together — unconditionally,
    // mounted or not (see the class doc for why the mounted case is no longer special-cased).

    private final class NudgeCounter {
        private(set) var count = 0
        func nudge() { count += 1 }
    }

    private func wireBoth(parser: HostScreenParser, source: TerminalColorSource,
                          sink: Sink, nudge: NudgeCounter) {
        source.addObserver { terminalTheme in
            if ColorSchemeReport.shouldSend(modeOn: parser.colorSchemeReportMode) {
                sink.write(ColorSchemeReport.encode(isDark: terminalTheme == "dark"))
            }
            nudge.nudge()
        }
    }

    func testIntegrationNoMode2031StillGetsNudgedOnFlip() {
        // codex: never subscribes to mode-2031, so `shouldSend` never fires for it — the nudge
        // is its ONLY path to ever hear about a live theme change.
        let parser = HostScreenParser(cols: 80, rows: 24)
        let source = TerminalColorSource()
        let sink = Sink()
        let nudge = NudgeCounter()
        wireBoth(parser: parser, source: source, sink: sink, nudge: nudge)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [], "codex never opted into mode-2031 — no push expected")
        XCTAssertEqual(nudge.count, 1, "a cell must always get nudged so a codex-shaped agent re-queries OSC 10/11 on its own — mounted or not")
    }

    func testIntegrationMode2031AgentGetsBothPushAndNudge() {
        // claude/opencode: subscribed to mode-2031 — gets the push AND the harmless nudge.
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        let source = TerminalColorSource()
        let sink = Sink()
        let nudge = NudgeCounter()
        wireBoth(parser: parser, source: source, sink: sink, nudge: nudge)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [Data("\u{1B}[?997;1n".utf8)])
        XCTAssertEqual(nudge.count, 1)
    }

    func testIntegrationNudgeFiresOncePerActualFlipNotPerRepublish() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        let source = TerminalColorSource()
        let sink = Sink()
        let nudge = NudgeCounter()
        wireBoth(parser: parser, source: source, sink: sink, nudge: nudge)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)
        source.update(terminalTheme: "dark", foreground: "rgb:1/1/1", background: "rgb:2/2/2")  // accent-only republish
        source.update(terminalTheme: "light", foreground: nil, background: nil)

        XCTAssertEqual(nudge.count, 2, "TerminalColorSource already suppresses same-theme republishes upstream — the accent-only update must not add a spurious nudge")
    }

    // MARK: - d) encode API output matches the documented wire bytes exactly

    func testEncodeDarkMatchesHandwrittenSequence() {
        XCTAssertEqual(ColorSchemeReport.encode(isDark: true), Data("\u{1B}[?997;1n".utf8))
    }

    func testEncodeLightMatchesHandwrittenSequence() {
        XCTAssertEqual(ColorSchemeReport.encode(isDark: false), Data("\u{1B}[?997;2n".utf8))
    }
}
