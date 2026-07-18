import Foundation
import GhosttyVt

/// mode-2031 dark-cell notification: encodes an unsolicited color-scheme change report
/// using libghostty-vt's canonical encoder — the exact same bytes a terminal emits in
/// reply to its own `CSI ?996n` query (`ESC[?997;1n` dark, `ESC[?997;2n` light). Callers
/// must gate a send on `GHOSTTY_MODE_COLOR_SCHEME_REPORT` (mode 2031, see
/// `HostScreenParser.colorSchemeReportMode`) being set — this type only encodes, it does
/// not decide whether to send.
enum ColorSchemeReport {
    /// The host-push decision, factored out of `GhosttyViewBackend`'s wiring so it is
    /// directly unit-testable: `GhosttyViewBackend.startOnMain` is macOS-surface-only and
    /// no-ops under XCTest (the standard spawn guard), and `InMemoryTerminalSession.
    /// currentSurface` cannot be driven non-nil in a test without a live ghostty surface —
    /// so the boolean facts it's gated on (mode subscribed, surface attached) are passed
    /// in rather than read from those objects here. A surface existing means its own
    /// per-surface broadcast owns the report; sending anyway would double-notify the agent,
    /// not fill a gap.
    static func shouldSend(modeOn: Bool, hasSurface: Bool) -> Bool {
        modeOn && !hasSurface
    }

    /// A fixed 16-byte buffer comfortably covers the encoded sequence (9 bytes); the
    /// precondition below is a canary for a future libghostty-vt wire-format change, not a
    /// runtime possibility.
    static func encode(isDark: Bool) -> Data {
        let scheme: GhosttyColorScheme = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        var buf = [UInt8](repeating: 0, count: 16)
        var written: size_t = 0
        let result = buf.withUnsafeMutableBytes { raw -> GhosttyResult in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return ghostty_color_scheme_report_encode(scheme, ptr, raw.count, &written)
        }
        precondition(result == GHOSTTY_SUCCESS,
                     "ghostty_color_scheme_report_encode failed: \(result)")
        return Data(buf.prefix(Int(written)))
    }
}
