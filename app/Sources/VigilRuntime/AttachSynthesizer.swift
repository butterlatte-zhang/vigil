import Foundation

/// Synthesize a clean VT stream from the parser's screen state for surface attach, instead of
/// a bounded raw-byte replay buffer.
///
/// A byte-based replay of raw PTY output into a freshly built surface is correct only while
/// the whole stream fits a bounded buffer: once a long-lived cell's output exceeds it, the
/// HEAD is dropped and the replay starts mid-sequence, so a TUI's absolute-CUP repaints land
/// on a screen with no base frame → scattered characters (attach-garble). Regenerating the
/// display from the parser's grid+scrollback STATE avoids this: it is volume-independent and
/// can never truncate.
///
/// This file is the PURE half: `ScreenSnapshot` is a plain-data capture of the parser screen
/// (produced by `VtScreen.snapshot()` — the only code that touches the C API), and
/// `AttachScreenSynthesizer.serialize` turns it into standard VT bytes with **no query
/// sequences** (no DA/DSR/DECRQM), so replaying it can never provoke a surface→PTY answer that
/// would corrupt the child. Being pure + data-in/bytes-out, it is unit-testable off any queue.

// MARK: - Snapshot data model

/// The subset of a cell's visual style the synthesizer can faithfully re-emit as SGR.
///
/// Honest boundary (capture as much as possible; honestly degrade what can't be captured): CAPTURED are foreground/background
/// (default | 16-color / 256-color palette | truecolor RGB), bold, faint (SGR 2 / dim — read by
/// the input-line probe), italic, underline (as on/off), inverse, strikethrough, and blink. DEGRADED
/// (silently dropped, re-drawn on the child's next repaint which the attach nudge triggers):
/// the underline COLOR, the underline STYLE (double/curly collapse to a plain SGR 4),
/// overline, invisible, hyperlinks (OSC 8), and Kitty/Sixel graphics. None of these can cause
/// garble; at worst a rare decoration is briefly absent.
struct SynthStyle: Equatable {
    enum Color: Equatable { case `default`; case palette(UInt8); case rgb(UInt8, UInt8, UInt8) }
    var fg: Color = .default
    var bg: Color = .default
    var bold = false
    var faint = false
    var italic = false
    var underline = false
    var inverse = false
    var strikethrough = false
    var blink = false
    /// The default SGR state (all attributes off). Trailing cells equal to this are trimmed.
    static let plain = SynthStyle()
}

struct SynthCell: Equatable {
    var char: Character
    var style: SynthStyle
}

/// One row of the grid, left→right, with trailing (space + default-style) cells trimmed —
/// matching the §12.3 `trimRight` the scrape renderer applies, so an unwritten MIDDLE gap
/// survives as real spaces but the unwritten tail does not.
struct SynthRow: Equatable {
    var cells: [SynthCell]
}

/// A plain-data capture of the parser screen sufficient to reconstruct its display.
struct ScreenSnapshot: Equatable {
    var cols: Int
    var rows: Int
    /// Scrollback rows, top→bottom, that sit before the active area (empty when on alt-screen).
    var history: [SynthRow]
    /// Exactly `rows` visible rows (the active area).
    var active: [SynthRow]
    var cursorX: Int
    var cursorY: Int
    var cursorVisible: Bool
    var altScreen: Bool
    var bracketedPaste: Bool
}

// MARK: - Serializer

enum AttachScreenSynthesizer {

    /// Turn a screen snapshot into a self-contained VT byte stream that, replayed into a fresh
    /// (cleared, correctly-sized) surface, reproduces the snapshot's display. Contains only
    /// state-setting sequences — never a query — so it is inert with respect to the PTY.
    static func serialize(_ s: ScreenSnapshot) -> Data {
        var out = Data()
        func w(_ str: String) { out.append(contentsOf: str.utf8) }

        // Start from a known-default SGR so the per-cell diff below has a fixed baseline.
        w("\u{1b}[0m")
        var current = SynthStyle.plain

        if s.altScreen {
            // Enter the alternate screen (1049h also clears it and saves the primary cursor).
            // The primary screen UNDERNEATH is not reconstructed — libghostty-vt exposes only
            // the active screen's grid/history through the point tags, so primary content is
            // unreadable while alt is active (documented degradation: after the child later
            // exits the TUI, pre-attach primary scrollback is absent). We still lay down the
            // current alt grid so there is a correct frame immediately; the child fully repaints
            // it on the post-attach redraw nudge regardless.
            w("\u{1b}[?1049h")
            emitRows(s.active, current: &current, into: &out)
        } else {
            // Fresh surface: home + clear, then stream history into scrollback followed by the
            // active rows. Printing `history + active` lines separated by CR/LF pushes exactly
            // `history.count` lines off the top into scrollback, leaving the active rows visible.
            w("\u{1b}[H\u{1b}[2J")
            emitRows(s.history + s.active, current: &current, into: &out)
        }

        // Park the cursor at its real active-area position (CUP is 1-based).
        w("\u{1b}[\(s.cursorY + 1);\(s.cursorX + 1)H")
        if !s.cursorVisible { w("\u{1b}[?25l") }
        if s.bracketedPaste { w("\u{1b}[?2004h") }
        // Leave SGR clean: the child re-emits its own attributes before drawing, and the visible
        // grid was already laid down with explicit per-cell SGR above.
        w("\u{1b}[0m")
        return out
    }

    /// Emit rows separated by CR/LF (between rows, none trailing), diffing each cell's style
    /// against the running SGR state so a style transition emits exactly one escape. CR before
    /// LF also cancels any pending soft-wrap left by a full-width row.
    private static func emitRows(_ rows: [SynthRow], current: inout SynthStyle, into out: inout Data) {
        for (i, row) in rows.enumerated() {
            if i > 0 { out.append(contentsOf: [0x0d, 0x0a]) }   // CR LF
            for cell in row.cells {
                if cell.style != current {
                    out.append(contentsOf: sgr(cell.style).utf8)
                    current = cell.style
                }
                out.append(contentsOf: String(cell.char).utf8)
            }
        }
    }

    /// Build a single `ESC [ 0 ; … m` that resets then sets exactly this style's attributes.
    private static func sgr(_ st: SynthStyle) -> String {
        var p = ["0"]
        if st.bold { p.append("1") }
        if st.faint { p.append("2") }
        if st.italic { p.append("3") }
        if st.underline { p.append("4") }
        if st.blink { p.append("5") }
        if st.inverse { p.append("7") }
        if st.strikethrough { p.append("9") }
        appendColor(st.fg, base: 30, extended: 38, into: &p)
        appendColor(st.bg, base: 40, extended: 48, into: &p)
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }

    /// Palette 0–7 → `base+n` (e.g. 31/41), 8–15 → `base+60+(n-8)` (bright, 91/101), 16–255 →
    /// `extended;5;n`, RGB → `extended;2;r;g;b`. The palette INDEX round-trips identically
    /// whichever named/extended form is used.
    private static func appendColor(_ c: SynthStyle.Color, base: Int, extended: Int,
                                    into p: inout [String]) {
        switch c {
        case .default:
            break
        case .palette(let n):
            if n < 8 { p.append("\(base + Int(n))") }
            else if n < 16 { p.append("\(base + 60 + Int(n) - 8)") }
            else { p.append("\(extended)"); p.append("5"); p.append("\(n)") }
        case .rgb(let r, let g, let b):
            p.append("\(extended)"); p.append("2"); p.append("\(r)"); p.append("\(g)"); p.append("\(b)")
        }
    }
}
