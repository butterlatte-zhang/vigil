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

    /// The host-nudge decision for agents with NO mode-2031 subscription that instead
    /// re-query OSC 10/11 (and repaint) on a plain terminal resize — confirmed by a
    /// real-binary PTY A/B against codex 0.145.0 (2026-07-27 root-codex-dark-block
    /// investigation): it re-queries on boot and on SIGWINCH, never spontaneously while idle,
    /// and bakes the answer as an EXPLICIT truecolor background on its message boxes
    /// (`48;2;244;244;244` light / `48;2;30;30;30` dark) rather than the terminal's live
    /// default — so once printed, that box is frozen until the process is nudged again.
    /// `GhosttyViewBackend` already sends exactly this nudge (`HostPTY.nudgeRedraw`, a
    /// SIGWINCH double-pulse) on every surface ATTACH; a background cell that goes long
    /// stretches between attaches (spanning a day/night appearance flip while nobody is
    /// looking) never gets nudged on its own and stays stuck at whatever palette was live at
    /// its last attach/boot. Firing this on every real flip bounds that staleness to "since
    /// the last flip" instead of "since the last attach". Unconditional on mode-2031 (unlike
    /// `shouldSend` above) — a claude/opencode cell that already gets the push notification
    /// harmlessly receives a resize alongside it (the same nudge `handleSurfaceAttach` already
    /// sends them without issue); an agent that ignores resizes entirely is simply unaffected.
    /// A surface existing means IT is the live display and already gets its own repaint via
    /// `TerminalColorSchemeBroadcast`/`ghostty_surface_update_config` — a host-sent nudge
    /// would be redundant there, not a missing one (mirrors `shouldSend`'s surface gate).
    static func shouldNudgeRedraw(hasSurface: Bool) -> Bool {
        !hasSurface
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
