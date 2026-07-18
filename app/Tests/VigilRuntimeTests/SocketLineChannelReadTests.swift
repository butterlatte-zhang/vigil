import XCTest
import Foundation
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// SocketLineChannel's read path uses a DispatchSourceRead over a non-blocking fd rather
/// than a per-connection blocking read() (which would park one GCD thread per live
/// connection, capping concurrent connections at roughly the thread pool size). These
/// tests pin the read/write semantics this design must satisfy, plus a many-connections
/// scale check that it serves concurrently with no thread parked while idle.
final class SocketLineChannelReadTests: XCTestCase {

    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }
    @discardableResult
    private func writeRaw(_ fd: Int32, _ s: String) -> Int {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBytes { Int(Darwin.write(fd, $0.baseAddress, $0.count)) }
    }
    private func waitUntil(_ deadline: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let t0 = Date()
        while !cond() && Date().timeIntervalSince(t0) < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: read-path parity

    func testReadLineDeliversASingleLine() async {
        let (a, b) = pair()
        let ch = SocketLineChannel(fd: a)
        writeRaw(b, "hello\n")
        let line = await ch.readLine()
        XCTAssertEqual(line, "hello")
        await ch.close(); close(b)
    }

    func testReadLineSplitsMultipleLinesFromOneWrite() async {
        let (a, b) = pair()
        let ch = SocketLineChannel(fd: a)
        writeRaw(b, "one\ntwo\nthree\n")
        let l1 = await ch.readLine()
        let l2 = await ch.readLine()
        let l3 = await ch.readLine()
        XCTAssertEqual([l1, l2, l3], ["one", "two", "three"])
        await ch.close(); close(b)
    }

    func testReadLineReassemblesALineSplitAcrossWrites() async {
        // The heart of the async design: the source must re-fire and ACCUMULATE partial
        // bytes across separate arrivals, delivering only once the newline lands.
        let (a, b) = pair()
        let ch = SocketLineChannel(fd: a)
        let got = Box<String?>()
        let t = Task { got.set(await ch.readLine()) }
        writeRaw(b, "hel")                                 // no newline yet
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(got.isSet, "no newline must not release early")
        writeRaw(b, "lo\n")                                // completes the line
        await waitUntil { got.isSet }
        _ = await t.value
        XCTAssertEqual(got.value ?? nil, "hello")
        await ch.close(); close(b)
    }

    func testReadLineReturnsNilOnEOFAndStaysNil() async {
        let (a, b) = pair()
        let ch = SocketLineChannel(fd: a)
        close(b)                                           // peer closes → EOF
        let first = await ch.readLine()
        let second = await ch.readLine()
        XCTAssertNil(first)
        XCTAssertNil(second)                               // EOF is sticky
        await ch.close()
    }

    func testReadLineDeliversBufferedLineThenNilAtEOF() async {
        // A complete line already in the buffer is delivered; the trailing unterminated
        // remainder is dropped at EOF.
        let (a, b) = pair()
        let ch = SocketLineChannel(fd: a)
        writeRaw(b, "done\npartial")                       // one full line + a fragment
        close(b)
        let l1 = await ch.readLine()
        let l2 = await ch.readLine()
        XCTAssertEqual(l1, "done")
        XCTAssertNil(l2, "an unterminated trailing segment is dropped at EOF (matching the original popLine behavior)")
        await ch.close()
    }

    func testWriteThenReadRoundTripsOverThePair() async {
        // write() must survive the non-blocking fd (a full send buffer returns EAGAIN
        // rather than blocking) — the bytes still arrive whole, in order.
        let (a, b) = pair()
        let ch1 = SocketLineChannel(fd: a)
        let ch2 = SocketLineChannel(fd: b)
        await ch1.write("ping")
        let got = await ch2.readLine()
        XCTAssertEqual(got, "ping")
        await ch1.close(); await ch2.close()
    }

    func testCloseUnblocksAPendingReadLine() async {
        // close() while a readLine is waiting must resume it with nil, never hang.
        let (a, b) = pair()
        let ch = SocketLineChannel(fd: a)
        let got = Box<String?>()
        let t = Task { got.set(await ch.readLine()) }      // waits: no data yet
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(got.isSet)
        await ch.close()
        await waitUntil(3) { got.isSet }
        _ = await t.value
        XCTAssertTrue(got.isSet, "close must wake a pending readLine, never hang")
        XCTAssertNil(got.value ?? nil)
        close(b)
    }

    // MARK: scale — the source design serves many connections concurrently

    func testManyConcurrentConnectionsEachDeliver() async {
        // 128 connections all awaiting at once, then each peer writes its own line. A
        // thread-per-connection blocking design would park one GCD thread per awaiting
        // connection, capping concurrency; this design parks none and every line still arrives.
        let n = 128
        let pairs = (0..<n).map { _ in pair() }
        let chans = pairs.map { SocketLineChannel(fd: $0.0) }
        let got = Box<[Int: String]>(); got.set([:])

        for (i, ch) in chans.enumerated() {
            Task { if let line = await ch.readLine() { got.merge(i, line) } }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)    // let all reads register
        for (i, p) in pairs.enumerated() { writeRaw(p.1, "line\(i)\n") }

        await waitUntil(8) { got.count == n }
        XCTAssertEqual(got.count, n, "all 128 connections must be delivered (no thread-ceiling starvation)")
        for i in 0..<n { XCTAssertEqual(got.lookup(i), "line\(i)") }

        for (i, ch) in chans.enumerated() { await ch.close(); close(pairs[i].1) }
    }
}

/// Minimal thread-safe box for values produced on a detached read Task.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T?
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _v != nil }
    var value: T? { lock.lock(); defer { lock.unlock() }; return _v }
    func set(_ v: T) { lock.lock(); _v = v; lock.unlock() }
}
extension Box where T == [Int: String] {
    func merge(_ k: Int, _ v: String) { lock2 { $0[k] = v } }
    var count: Int { var c = 0; lock2 { c = $0.count }; return c }
    func lookup(_ k: Int) -> String? { var r: String?; lock2 { r = $0[k] }; return r }
    private func lock2(_ body: (inout [Int: String]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var d = _v ?? [:]; body(&d); _v = d
    }
}
