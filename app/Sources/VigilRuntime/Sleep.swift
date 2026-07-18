import Foundation

/// The one seconds→nanoseconds conversion for Task.sleep, used by every poll loop
/// (RealCell inject probe/settle, HookGateway watchdog, PermWatcher/TurnWatcher ticks,
/// AutoNamer watch). One definition, pinned by test.
public enum SleepClock {
    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))`, spelled once.
    public static func sleep(seconds: TimeInterval) async throws {
        try await sleep(nanoseconds: SleepClock.nanoseconds(seconds))
    }
}
