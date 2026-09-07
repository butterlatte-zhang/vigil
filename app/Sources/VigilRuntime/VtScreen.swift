import Foundation
import GhosttyVt

/// The headless VT emulator on libghostty-vt (ghostty's terminal engine, C ABI).
///
/// The visible surface (libghostty GhosttyKit) and the scrape source parse from ONE engine
/// family — a single scrape source. `VtScreen` owns only the parse half — no process, no PTY
/// (`HostPTY` forks the child; `HostScreenParser`/`HeadlessBackend` pump bytes in). Its
/// `renderScreen()`/`renderAttributed()` implement the exact §12.3 semantics:
///   • unwritten/empty cells → real spaces (cursor-positioned NUL gaps)
///   • trailing blanks trimmed (translateToString(trimRight:true) equivalent)
///   • control codepoints (<0x20) → space (defensive; vt keeps them out of the grid anyway)
///   • per-Character dim = `GhosttyStyle.faint` (SGR 2), a first-class struct field.
///
/// NOT thread-safe: the owning `HostScreenParser`/`HeadlessBackend` confines every call to its
/// own serial queue (the vt `Terminal` is fed and read on the same queue, never concurrently).
final class VtScreen {
    private var terminal: GhosttyTerminal!
    private(set) var cols: Int
    private(set) var rows: Int

    /// Scrollback the shadow parser retains so surface attach can synthesize scroll-up history,
    /// not just the visible grid (see `AttachScreenSynthesizer`). The libghostty-vt
    /// `max_scrollback` is a BYTE budget of packed cell storage — NOT a row count, despite the
    /// vendored header's "lines" wording (pinned empirically:
    /// `AttachSynthesisTests.testScrollbackAccumulatesAndSynthesizes` — 8192 → only ~609 short
    /// lines). Pages allocate lazily, so this is a CAP not a reservation: a worker uses memory
    /// only for the history it actually produces, up to ~2 MB; ~30 concurrent workers → tens of
    /// MB worst case. State-synthesis attach reads screen STATE directly, so it cannot truncate it.
    static let maxScrollbackBytes = 2 * 1024 * 1024

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        var opts = GhosttyTerminalOptions()
        opts.cols = UInt16(clamping: self.cols)
        opts.rows = UInt16(clamping: self.rows)
        opts.max_scrollback = size_t(Self.maxScrollbackBytes)
        var t: GhosttyTerminal?
        let r = ghostty_terminal_new(nil, &t, opts)   // nil allocator = libc default
        precondition(r == GHOSTTY_SUCCESS && t != nil, "ghostty_terminal_new failed: \(r)")
        terminal = t
    }

    deinit {
        if let terminal { ghostty_terminal_free(terminal) }
    }

    /// Feed one chunk of PTY output through the VT parser. Side-effect sequences (DA/DSR/…)
    /// are ignored by default (no effects registered), so — like the old ShadowDelegate that
    /// dropped `send:` replies — this shadow parser never answers the child.
    func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            ghostty_terminal_vt_write(terminal, buf.baseAddress, buf.count)
        }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        // cell_width/height px are only used for pixel-based size reports (mode 2048); the
        // scrape never reads them, so nominal 8×16 is fine and avoids a zero-metric edge.
        _ = ghostty_terminal_resize(terminal, UInt16(clamping: self.cols),
                                    UInt16(clamping: self.rows), 8, 16)
    }

    /// Bracketed-paste DEC mode (2004) truth for the injection wrap.
    var bracketedPasteMode: Bool {
        var on = false
        _ = ghostty_terminal_mode_get(terminal, ghostty_mode_new(2004, false), &on)
        return on
    }

    /// mode-2031 dark-cell notification: DEC private mode 2031 (`GHOSTTY_MODE_COLOR_SCHEME_
    /// REPORT`) — the agent has opted into unsolicited color-scheme change reports
    /// (`ESC[?997;1n`/`;2n`, same wire shape as a CSI ?996n query reply). A live surface
    /// answers a scheme flip itself once this mode is on; a surfaceless cell needs the host
    /// to gate an unsolicited send on this same truth (see `GhosttyViewBackend`'s
    /// color-scheme observer).
    var colorSchemeReportMode: Bool {
        var on = false
        _ = ghostty_terminal_mode_get(terminal, ghostty_mode_new(2031, false), &on)
        return on
    }

    /// Input-affecting DEC private modes captured for attach synthesis (see
    /// `ScreenSnapshot.modes`): cursor keys (1), autowrap (7), X10/normal/button/any mouse
    /// (9/1000/1002/1003), focus events (1004), mouse formats (1005/1006/1015/1016), alternate
    /// scroll (1007), application keypad (66), cursor blink (12), grapheme clustering (2027),
    /// color-scheme reports (2031), in-band resize (2048). 25 / 47 / 1047 / 1049 / 2004 are
    /// carried by their own snapshot fields; 2026 (sync output) is transient by design.
    static let synthModes: [UInt16] = [1, 7, 9, 12, 66, 1000, 1002, 1003, 1004, 1005, 1006,
                                       1007, 1015, 1016, 2027, 2031, 2048]

    /// The parser's built-in reset value for each `synthModes` entry (pinned against a fresh
    /// parser by `AttachSynthesisTests.testSynthModeDefaultsMatchParser`). The synthesizer
    /// emits only modes that DIFFER from these: a mode the child never touched stays at the
    /// SURFACE's own default, which ghostty configures per surface (e.g. 2027 grapheme
    /// clustering is ON under `grapheme-width-method = unicode` while the parser resets it
    /// OFF) — replaying the parser's default explicitly would silently downgrade the surface.
    /// Honest boundary: a child that explicitly RESETS a surface-only default (e.g. `?2027l`)
    /// is indistinguishable from one that never touched it and is not replayed.
    static let synthModeDefaults: [UInt16: Bool] =
        Dictionary(uniqueKeysWithValues: synthModes.map { ($0, $0 == 7 || $0 == 1007) })

    /// Truth of one DEC private (`?`) mode.
    func mode(_ number: UInt16) -> Bool {
        var on = false
        _ = ghostty_terminal_mode_get(terminal, ghostty_mode_new(number, false), &on)
        return on
    }

    /// Whether any mouse tracking family member is active (the folded flag ghostty's surface
    /// consults before converting wheel ticks into cursor keys on the alt screen).
    var mouseTracking: Bool {
        var on = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on)
        return on
    }

    /// Kitty keyboard protocol flags currently in effect (0 = legacy).
    var kittyKeyboardFlags: UInt8 {
        var flags: UInt8 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        return flags
    }

    /// The visible grid as text — the ONE scrape source (§12.3 via the shared row builder).
    func renderScreen() -> String {
        var out = ""
        for y in 0..<rows {
            if y > 0 { out.append("\n") }
            out.append(buildLine(row: y, wantDim: false).text)
        }
        return out
    }

    /// The visible grid as text + per-Character dim — the attributed sibling. Guaranteed
    /// `lines.map(\.text).joined("\n") == renderScreen()`: both call `buildLine`, whose text
    /// path is identical regardless of `wantDim`.
    func renderAttributed() -> AttributedScreen {
        var lines: [AttributedLine] = []
        lines.reserveCapacity(rows)
        for y in 0..<rows { lines.append(buildLine(row: y, wantDim: true)) }
        return AttributedScreen(lines: lines)
    }

    // MARK: - Attach synthesis snapshot (worktree/attach-synthesis)

    /// Capture the full screen STATE — scrollback history, active grid (with per-cell style),
    /// cursor, the alt-screen / bracketed-paste modes, the input-regime DEC modes and kitty
    /// keyboard flags — as plain data for
    /// `AttachScreenSynthesizer`. Same serial-queue confinement as every other C-API touch: the
    /// owning `HostScreenParser` calls this inside `queue.sync`. Only the ACTIVE screen is
    /// readable through the point tags, so on the alternate screen `history` is empty (the
    /// primary buffer underneath is unreachable — documented degradation in the synthesizer).
    func snapshot() -> ScreenSnapshot {
        var cursorX: UInt16 = 0, cursorY: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY)
        var visible = true
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        let alt = (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE)

        var history: [SynthRow] = []
        if !alt {
            var sb: size_t = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb)
            let n = Int(sb)
            history.reserveCapacity(n)
            for y in 0..<n { history.append(snapshotRow(tag: GHOSTTY_POINT_TAG_HISTORY, y: y)) }
        }
        var active: [SynthRow] = []
        active.reserveCapacity(rows)
        for y in 0..<rows { active.append(snapshotRow(tag: GHOSTTY_POINT_TAG_ACTIVE, y: y)) }

        return ScreenSnapshot(cols: cols, rows: rows, history: history, active: active,
                              cursorX: Int(cursorX), cursorY: Int(cursorY),
                              cursorVisible: visible, altScreen: alt,
                              bracketedPaste: bracketedPasteMode,
                              modes: Dictionary(uniqueKeysWithValues:
                                                    Self.synthModes.map { ($0, mode($0)) }),
                              kittyKeyboardFlags: kittyKeyboardFlags)
    }

    /// One snapshot row (char + full `SynthStyle`) for the given coordinate space, mirroring
    /// `buildLine`'s cell walk (spacer-tail skip, control→space, §12.3 trailing trim) but
    /// capturing style instead of just the dim bit.
    private func snapshotRow(tag: GhosttyPointTag, y: Int) -> SynthRow {
        guard terminal != nil, y >= 0 else { return SynthRow(cells: []) }
        var cells: [SynthCell] = []
        for x in 0..<cols {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.stride
            var pt = GhosttyPoint()
            pt.tag = tag
            pt.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: x),
                                                         y: UInt32(clamping: y))
            guard ghostty_terminal_grid_ref(terminal, pt, &ref) == GHOSTTY_SUCCESS else { break }

            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { continue }

            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }

            var hasText = false
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)

            let ch: Character
            if hasText {
                let g = grapheme(ref: &ref, cell: cell)
                // Defensive: a control codepoint in the grid → space (matches buildLine).
                if g.unicodeScalars.count == 1 && g.unicodeScalars.first!.value < 0x20 { ch = " " }
                else { ch = g }
            } else {
                ch = " "
            }

            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.stride
            ghostty_grid_ref_style(&ref, &style)
            cells.append(SynthCell(char: ch, style: synthStyle(style)))
        }
        // §12.3 trimRight: drop the trailing run of default-styled spaces (unwritten tail).
        while let last = cells.last, last.char == " ", last.style == .plain { cells.removeLast() }
        return SynthRow(cells: cells)
    }

    private func synthStyle(_ s: GhosttyStyle) -> SynthStyle {
        var out = SynthStyle()
        out.bold = s.bold
        out.faint = s.faint
        out.italic = s.italic
        out.underline = s.underline != 0
        out.inverse = s.inverse
        out.strikethrough = s.strikethrough
        out.blink = s.blink
        out.fg = synthColor(s.fg_color)
        out.bg = synthColor(s.bg_color)
        return out
    }

    private func synthColor(_ c: GhosttyStyleColor) -> SynthStyle.Color {
        if c.tag == GHOSTTY_STYLE_COLOR_PALETTE { return .palette(c.value.palette) }
        if c.tag == GHOSTTY_STYLE_COLOR_RGB {
            return .rgb(c.value.rgb.r, c.value.rgb.g, c.value.rgb.b)
        }
        return .default
    }

    // MARK: - Shared row builder (the single §12.3 renderer)

    /// Build one ACTIVE-area row. Iterates columns left→right; a wide char's SPACER_TAIL cell
    /// is skipped (the base cell already emitted its grapheme), an empty/blank cell emits a
    /// space, everything else its grapheme (base codepoint + any combining marks). Trailing
    /// blanks are trimmed AFTER the row is built (matching `getTrimmedLength`), so an
    /// unwritten gap in the MIDDLE survives as real spaces. `dim` is index-aligned
    /// to `text` (one bit per emitted Character) and empty only when `wantDim` is false.
    private func buildLine(row y: Int, wantDim: Bool) -> AttributedLine {
        guard terminal != nil, y >= 0, y < rows else { return AttributedLine(text: "", dim: []) }
        var chars: [Character] = []
        var dim: [Bool] = []
        var blank: [Bool] = []   // per emitted position: trailing run of these is trimmed

        for x in 0..<cols {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.stride   // == C sizeof (ABI version tag)
            var pt = GhosttyPoint()
            pt.tag = GHOSTTY_POINT_TAG_ACTIVE
            pt.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: x),
                                                         y: UInt32(clamping: y))
            guard ghostty_terminal_grid_ref(terminal, pt, &ref) == GHOSTTY_SUCCESS else { break }

            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { continue }

            // A wide char occupies 2 columns: base cell (emitted) + spacer tail (skip).
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }

            var hasText = false
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)

            let ch: Character
            var isBlank: Bool
            if hasText {
                ch = grapheme(ref: &ref, cell: cell)
                // Defensive: a control codepoint in the grid → space (vt normally keeps them
                // out; matches renderGrid's clean step). A space glyph is also blank.
                isBlank = ch == " " || (ch.unicodeScalars.count == 1
                                        && ch.unicodeScalars.first!.value < 0x20)
            } else {
                ch = " "
                isBlank = true
            }
            let emitted: Character = isBlank ? " " : ch

            chars.append(emitted)
            blank.append(isBlank)
            if wantDim {
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.stride
                ghostty_grid_ref_style(&ref, &style)
                dim.append(style.faint)
            }
        }

        // trimRight: drop the trailing run of blank positions (unwritten tail + trailing spaces).
        var end = chars.count
        while end > 0 && blank[end - 1] { end -= 1 }
        let text = String(chars[0..<end])
        return AttributedLine(text: text, dim: wantDim ? Array(dim[0..<end]) : [])
    }

    /// The grapheme for a text cell: base codepoint plus any grapheme-cluster codepoints
    /// (combining marks) folded into a single Character, so the per-Character dim mask
    /// stays index-aligned. Invalid scalars fall back to space.
    private func grapheme(ref: inout GhosttyGridRef, cell: GhosttyCell) -> Character {
        var cp: UInt32 = 0
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
        var scalars: [Unicode.Scalar] = []
        if let base = Unicode.Scalar(cp) { scalars.append(base) }

        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
        if tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
            var buf = [UInt32](repeating: 0, count: 16)
            var outLen: size_t = 0
            let r = buf.withUnsafeMutableBufferPointer {
                ghostty_grid_ref_graphemes(&ref, $0.baseAddress, $0.count, &outLen)
            }
            if r == GHOSTTY_SUCCESS {
                for i in 0..<Int(outLen) where buf[i] != cp {
                    if let s = Unicode.Scalar(buf[i]) { scalars.append(s) }
                }
            }
        }
        guard !scalars.isEmpty else { return " " }
        var s = ""
        for sc in scalars { s.unicodeScalars.append(sc) }
        return s.first ?? " "
    }
}
