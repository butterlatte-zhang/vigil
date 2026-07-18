import XCTest
import Foundation
@testable import VigilApp

/// The three duration/relative-time formatters live in one namespace, but each keeps
/// its own intentional output format. These pins are the byte-level contract: relative
/// (sidebar/notif cards), runtime (tree panel, zero-padded), wall (transcript stats,
/// matching claude /status's unpadded style).
final class VGDurationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func testRelativePinsAllFourTiers() {
        func rel(_ s: TimeInterval) -> String {
            VGDuration.relative(t0, now: t0.addingTimeInterval(s))
        }
        XCTAssertEqual(rel(0), "just now")
        XCTAssertEqual(rel(59), "just now")
        XCTAssertEqual(rel(60), "1 min")
        XCTAssertEqual(rel(3599), "59 min")
        XCTAssertEqual(rel(3600), "1 hr")
        XCTAssertEqual(rel(86399), "23 hr")
        XCTAssertEqual(rel(86400), "1 days")
        XCTAssertEqual(rel(-5), "just now", "clock skew clamps to zero, never negative")
    }

    func testRuntimePinsZeroPaddedMinutesAndSeconds() {
        XCTAssertEqual(VGDuration.runtime(seconds: 0), "0s")
        XCTAssertEqual(VGDuration.runtime(seconds: 59), "59s")
        XCTAssertEqual(VGDuration.runtime(seconds: 61), "1m 01s", "seconds zero-pad")
        XCTAssertEqual(VGDuration.runtime(seconds: 3599), "59m 59s")
        XCTAssertEqual(VGDuration.runtime(seconds: 3600 + 300), "1h 05m", "minutes zero-pad")
    }

    func testWallPinsUnpaddedClaudeStatusStyle() {
        XCTAssertEqual(VGDuration.wall(seconds: 45), "45s")
        XCTAssertEqual(VGDuration.wall(seconds: 19 * 60 + 24), "19m 24s", "NO zero-pad — same as claude")
        XCTAssertEqual(VGDuration.wall(seconds: 61), "1m 1s")
        XCTAssertEqual(VGDuration.wall(seconds: 2 * 3600 + 300), "2h 5m")
    }
}
