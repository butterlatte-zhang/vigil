import Foundation

/// The one clock schema for the session's jsonl trails ("ts" in orchestration.jsonl and
/// perm_dogfood.jsonl): ISO8601 UTC at second precision — e.g. "2026-07-08T12:34:56Z".
/// Writer (Orchestrator stamps at Effect egress) and reader (SessionArchive.replay) must
/// share this pair: two independent formatters risk a write-side change silently nil'ing
/// every replayed timestamp. Format pinned byte-level by OrchClockTests.
public enum OrchClock {
    /// Default options = .withInternetDateTime. ISO8601DateFormatter is documented thread-safe.
    private static let formatter = ISO8601DateFormatter()

    public static func format(_ date: Date) -> String { formatter.string(from: date) }
    public static func parse(_ s: String) -> Date? { formatter.date(from: s) }
}
