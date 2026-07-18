import XCTest
@testable import VigilApp
@testable import VigilGhosttyTerminal

/// Terminal-observability sink: append behavior, the 10 MB wrap-on-cap bound, target routing,
/// and the "off = zero write" guard that keeps the hot path free when the mode is off.
final class TerminalDebugFileSinkTests: XCTestCase {

    private func freshDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vigil_termdbg_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func logPath(_ dir: String) -> String {
        (dir as NSString).appendingPathComponent("terminal-debug.log")
    }

    func testWritesAppendNewlineTerminatedLines() throws {
        let dir = freshDir()
        let sink = TerminalDebugFileSink()
        sink.setTarget(sessionDir: dir)
        sink.write("first line")
        sink.write("second line")

        let contents = try String(contentsOfFile: logPath(dir), encoding: .utf8)
        XCTAssertEqual(contents, "first line\nsecond line\n")
    }

    func testWrapsAtSizeCap() throws {
        let dir = freshDir()
        // Tiny cap so a couple of lines trip the wrap. Each line is ~20 bytes.
        let sink = TerminalDebugFileSink(capBytes: 40)
        sink.setTarget(sessionDir: dir)
        for i in 0..<20 { sink.write("line-\(i)-padding-xxxxx") }

        let size = (try FileManager.default.attributesOfItem(atPath: logPath(dir))[.size] as? Int) ?? -1
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThanOrEqual(size, 40 + 32, "file stays bounded near the cap (wraps, does not grow unbounded)")
        // The most recent line survives the wrap.
        let contents = try String(contentsOfFile: logPath(dir), encoding: .utf8)
        XCTAssertTrue(contents.contains("line-19"), "latest line present after wrap; got: \(contents)")
    }

    func testNoTargetAndAfterCloseDropWrites() {
        let dir = freshDir()
        let sink = TerminalDebugFileSink()

        // No target set → nothing on disk.
        sink.write("dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath(dir)))

        // Target then close → subsequent writes drop, file frozen.
        sink.setTarget(sessionDir: dir)
        sink.write("kept")
        sink.close()
        sink.write("dropped-after-close")
        let contents = (try? String(contentsOfFile: logPath(dir), encoding: .utf8)) ?? ""
        XCTAssertEqual(contents, "kept\n")
    }

    /// The red line: when the mode is off (isEnabled false) the sink is never touched — the
    /// early-exit in TerminalDebugLog.log guards the hot path.
    func testDisabledModeIsZeroWrite() {
        let priorSink = TerminalDebugLog.sink
        let priorEnabled = TerminalDebugLog.isEnabled
        defer {
            TerminalDebugLog.sink = priorSink
            TerminalDebugLog.isEnabled = priorEnabled
        }

        let counter = Counter()
        TerminalDebugLog.sink = { _ in counter.bump() }

        TerminalDebugLog.disable()
        for _ in 0..<100 { TerminalDebugLog.log(.metrics, "should not reach the sink") }
        XCTAssertEqual(counter.value, 0, "off = no sink calls")

        TerminalDebugLog.enable(.metrics)
        TerminalDebugLog.log(.metrics, "now it flows")
        XCTAssertEqual(counter.value, 1, "enabled metrics line reaches the sink")

        // A category outside the enabled set is still filtered out.
        TerminalDebugLog.log(.input, "input content must not flow under metrics-only")
        XCTAssertEqual(counter.value, 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
