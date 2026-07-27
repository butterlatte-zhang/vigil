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
    /// no-ops under XCTest (the standard spawn guard). Gated only on the agent's own mode-2031
    /// subscription — NOT on whether a surface is attached.
    ///
    /// Round 1 (2026-07-27) also gated this on `!hasSurface`, on the assumption that an
    /// attached surface's own per-surface broadcast (`ghostty_surface_set_color_scheme`)
    /// already delivers this report, so a host duplicate would double-notify rather than fill
    /// a gap. `vigil-colorflip` (a real mounted `GhosttyViewBackend` surface driven through the
    /// actual production `TerminalController.setColorScheme` call) disproved that: across
    /// repeated dark/light flips, with the resolved config's background line genuinely
    /// alternating between the two theme colors, the surface's own unsolicited push to the
    /// child PTY was observed stuck at `CSI ?997;2n` (light) every single time, independent of
    /// the requested scheme. A mounted surface cannot be trusted to inform its own child
    /// process, so the host push must always run — a redundant (if briefly wrong) push from
    /// ghostty's own broadcast is harmless since this one always fires after it and wins.
    static func shouldSend(modeOn: Bool) -> Bool {
        modeOn
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
