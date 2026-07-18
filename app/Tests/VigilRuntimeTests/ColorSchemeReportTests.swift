import XCTest
@testable import VigilRuntime

/// mode-2031 dark-cell notification: a live ghostty surface answers a scheme flip itself
/// (a DEC mode 2031 subscriber gets an unsolicited `ESC[?997;1n`/`;2n`); a background cell
/// may never build one, so nobody would ever tell the agent the terminal's scheme changed.
/// These tests cover the three pieces `GhosttyViewBackend` wires together —
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

    /// Wires the exact same three collaborators `GhosttyViewBackend` does (parser mode read,
    /// observer, gate, encode) around a plain `Data` sink standing in for `HostPTY.write` —
    /// `InMemoryTerminalSession.currentSurface` cannot be driven non-nil here without a live
    /// ghostty surface (setSurface is package-internal to VigilGhosttyTerminal), so
    /// `hasSurface` is threaded through directly, matching how `ColorSchemeReport.shouldSend`
    /// was factored out for exactly this reason.
    private final class Sink {
        private(set) var writes: [Data] = []
        func write(_ data: Data) { writes.append(data) }
    }

    private func wire(parser: HostScreenParser, source: TerminalColorSource,
                       hasSurface: @escaping () -> Bool, sink: Sink) {
        source.addObserver { terminalTheme in
            guard ColorSchemeReport.shouldSend(modeOn: parser.colorSchemeReportMode,
                                               hasSurface: hasSurface()) else { return }
            sink.write(ColorSchemeReport.encode(isDark: terminalTheme == "dark"))
        }
    }

    func testIntegrationModeOnNoSurfaceThemeChangeSendsReport() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, hasSurface: { false }, sink: sink)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [Data("\u{1B}[?997;1n".utf8)])
    }

    func testIntegrationModeOnNoSurfaceLightFlipSendsCode2() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, hasSurface: { false }, sink: sink)

        source.update(terminalTheme: "light", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [Data("\u{1B}[?997;2n".utf8)])
    }

    func testIntegrationModeOffSendsNothing() {
        let parser = HostScreenParser(cols: 80, rows: 24)   // never subscribed to 2031
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, hasSurface: { false }, sink: sink)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [], "agent never opted into mode 2031 — host must stay silent")
    }

    func testIntegrationSurfaceAttachedSendsNothing() {
        let parser = HostScreenParser(cols: 80, rows: 24)
        parser.feed(Data("\u{1B}[?2031h".utf8))
        let source = TerminalColorSource()
        let sink = Sink()
        wire(parser: parser, source: source, hasSurface: { true }, sink: sink)

        source.update(terminalTheme: "dark", foreground: nil, background: nil)

        XCTAssertEqual(sink.writes, [],
                        "a surface owns its own broadcast — a host duplicate would double-notify")
    }

    // MARK: - d) encode API output matches the documented wire bytes exactly

    func testEncodeDarkMatchesHandwrittenSequence() {
        XCTAssertEqual(ColorSchemeReport.encode(isDark: true), Data("\u{1B}[?997;1n".utf8))
    }

    func testEncodeLightMatchesHandwrittenSequence() {
        XCTAssertEqual(ColorSchemeReport.encode(isDark: false), Data("\u{1B}[?997;2n".utf8))
    }
}
