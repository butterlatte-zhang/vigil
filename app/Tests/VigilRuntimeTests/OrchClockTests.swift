import Foundation
import XCTest
import VigilCore
@testable import VigilRuntime

// orchestration.jsonl's "ts" write side (Orchestrator) and read side
// (SessionArchive.replay) must share one formatter with one contract on the format —
// a mismatch between them silently turns the entire replay timeline into nil.
// OrchClock is the single format/parse pair; these tests pin the wire format down
// to the byte level.

final class OrchClockTests: XCTestCase {

    /// Wire-format pin: ISO8601 UTC, second precision, trailing Z — byte-for-byte what
    /// the pre-extraction write end (a default ISO8601DateFormatter) produced.
    func testFormatPinsWireBytes() {
        XCTAssertEqual(OrchClock.format(Date(timeIntervalSince1970: 0)),
                       "1970-01-01T00:00:00Z")
        XCTAssertEqual(OrchClock.format(Date(timeIntervalSince1970: 1_782_211_200)),
                       "2026-06-23T10:40:00Z")
    }

    /// The extraction must be byte-identical to BOTH former implementations, which were
    /// plain `ISO8601DateFormatter()`s (default options) on each end.
    func testMatchesLegacyDefaultISO8601FormatterBytes() {
        let legacy = ISO8601DateFormatter()
        for t: TimeInterval in [0, 951_827_696, 1_782_211_200, 4_102_444_800] {
            let d = Date(timeIntervalSince1970: t)
            XCTAssertEqual(OrchClock.format(d), legacy.string(from: d))
            XCTAssertEqual(OrchClock.parse(legacy.string(from: d)), d)
        }
    }

    /// format→parse round-trip is lossless at the schema's own precision (whole seconds).
    func testRoundTrip() {
        let d = Date(timeIntervalSince1970: 1_752_500_000)
        XCTAssertEqual(OrchClock.parse(OrchClock.format(d)), d)
    }

    /// End-to-end contract: a ts stamped exactly as the write path stamps it parses on
    /// the replay path into the archive's timeline.
    func testReplayParsesWrittenTimestamp() {
        let ts = OrchClock.format(Date(timeIntervalSince1970: 1_782_211_200))
        let line = #"{"event":"cell_launch","node":"root","root":true,"role":"manager","task":"t","ts":"\#(ts)"}"#
        let s = SessionArchive.replay(lines: [line])
        XCTAssertEqual(s.firstEventAt, Date(timeIntervalSince1970: 1_782_211_200))
        XCTAssertEqual(s.lastEventAt, Date(timeIntervalSince1970: 1_782_211_200))
    }
}
