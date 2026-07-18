import XCTest
@testable import VigilRuntime

/// The injection-window gate + replay (InjectGate).
final class InjectGateTests: XCTestCase {

    /// Thread-safe recorder of the bytes that reached the PTY, in write order (each toPTY call
    /// is one entry, decoded UTF-8 for readable assertions).
    private final class PTYRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
        func record(_ d: Data) { lock.lock(); _writes.append(String(decoding: d, as: UTF8.self)); lock.unlock() }
    }
    private func d(_ s: String) -> Data { Data(s.utf8) }

    func testIngestPassesThroughWhenWindowClosed() {
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.ingest(d("a"))
        gate.ingest(d("b"))
        XCTAssertEqual(rec.writes, ["a", "b"], "with the gate closed, user bytes go straight to the PTY")
    }

    func testInjectDirectAlwaysImmediateEvenInsideWindow() {
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.begin()
        gate.injectDirect(d("INJ"))
        XCTAssertEqual(rec.writes, ["INJ"], "injected bytes always reach the PTY immediately, bypassing the gate")
    }

    func testUserBytesBufferedDuringWindowThenReplayedAfterInjection() {
        // The core invariant: window open → injected bytes go straight to PTY, user bytes
        // are held; end() replays them AFTER the injection, in arrival order.
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.begin()
        gate.injectDirect(d("body"))     // Vigil injection: immediate
        gate.ingest(d("u1"))             // user typing mid-window: buffered
        gate.ingest(d("u2"))             // more typing: buffered, in order
        gate.injectDirect(d("\r"))       // injected CR: immediate
        XCTAssertEqual(rec.writes, ["body", "\r"], "inside the window only injected bytes reach the PTY; user bytes are not mixed in")
        gate.end()
        XCTAssertEqual(rec.writes, ["body", "\r", "u1", "u2"],
                       "after end() user bytes reach the PTY in order, landing after the injection")
    }

    func testMultipleUserSegmentsPreserveOrder() {
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.begin()
        for s in ["h", "e", "l", "l", "o"] { gate.ingest(d(s)) }
        gate.end()
        XCTAssertEqual(rec.writes, ["h", "e", "l", "l", "o"], "multiple segments of user bytes stay in order")
    }

    func testBeginIdempotent() {
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.begin()
        gate.begin()                     // second begin is harmless
        gate.ingest(d("x"))
        XCTAssertEqual(rec.writes, [], "a repeated begin is harmless, the window stays open")
        gate.end()
        XCTAssertEqual(rec.writes, ["x"])
    }

    func testEndWithoutBeginIsHarmless() {
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.end()                       // no window ever opened
        gate.ingest(d("y"))              // still closed → straight through
        XCTAssertEqual(rec.writes, ["y"], "an end with no begin is harmless, the gate stays closed")
    }

    func testWindowReopensAfterEnd() {
        // A second inject window works the same as the first (begin/end are reusable).
        let rec = PTYRecorder()
        let gate = InjectGate(toPTY: rec.record)
        gate.begin(); gate.injectDirect(d("A")); gate.ingest(d("1")); gate.end()
        gate.begin(); gate.injectDirect(d("B")); gate.ingest(d("2")); gate.end()
        XCTAssertEqual(rec.writes, ["A", "1", "B", "2"], "a second window is structurally identical to the first")
    }
}
