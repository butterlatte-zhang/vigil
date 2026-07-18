import Foundation

/// The three duration/relative-time formatters, one namespace.
/// Each output format is INTENTIONALLY distinct — relative time (sidebar rows / notif
/// cards), runtime column (tree panel, zero-padded), wall clock (transcript stats,
/// same as claude /status, no zero-padding) — collecting them here only kills the
/// scatter; every call site's output stays byte-identical.
enum VGDuration {
    /// "just now" / "N min" / "N hr" / "N days" — sidebar rows & notification cards.
    /// Honesty rule: always derived from an actual Date, never a fabricated arrival time.
    static func relative(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) hr" }
        return "\(s / 86400) days"
    }

    /// "Ns" / "Nm 0Ns" / "Nh 0Nm" (zero-padded) — the tree panel's runtime column.
    static func runtime(seconds s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    /// "Ns" / "Nm Ns" / "Nh Nm" (no padding, same format as claude /status) — transcript stats.
    static func wall(seconds s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
