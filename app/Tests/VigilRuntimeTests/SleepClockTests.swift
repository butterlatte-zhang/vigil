import XCTest
import VigilRuntime

/// Pin the seconds→ns conversion so every former inline
/// `UInt64(x * 1_000_000_000)` keeps its exact duration through the helper.
final class SleepClockTests: XCTestCase {
    func testNanosecondConversionMatchesFormerInlineMath() {
        XCTAssertEqual(SleepClock.nanoseconds(0.15), 150_000_000)   // RealCell settle-before-CR
        XCTAssertEqual(SleepClock.nanoseconds(0.5), 500_000_000)    // RealCell inject poll default
        XCTAssertEqual(SleepClock.nanoseconds(1.0), 1_000_000_000)  // watcher tick default
        XCTAssertEqual(SleepClock.nanoseconds(110), 110_000_000_000) // review watchdog default
    }
}
