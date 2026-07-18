import XCTest
import Foundation
@testable import VigilRuntime
#if canImport(Darwin)
import Darwin
#endif

/// SocketLineChannel / UDSListener robustness: close idempotency (after fd reuse, a
/// non-idempotent double-close would close an unrelated fd). Non-blocking read is covered
/// in SocketLineChannelReadTests.
final class SocketLineChannelTests: XCTestCase {

    // MARK: close idempotency

    func testChannelCloseIsIdempotentAndDoesNotCloseAReusedFd() async {
        // socketpair → wrap one end. close() closes it; a later fd allocation may hand
        // back the SAME number. A non-idempotent second close() would then close that
        // innocent fd. dup2 installs a known-good fd at the exact freed number so the
        // hazard is deterministic (not left to luck about which number gets reused).
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let target = fds[0]
        let ch = SocketLineChannel(fd: target)
        await ch.close()                                   // closes `target`
        XCTAssertEqual(fcntl(target, F_GETFD), -1, "close() must actually close the fd")

        let innocent = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(innocent, 0)
        XCTAssertEqual(dup2(innocent, target), target)     // `target` now = a live /dev/null fd

        await ch.close()                                   // second close: must be a no-op
        XCTAssertNotEqual(fcntl(target, F_GETFD), -1,
                          "a second close shut an unrelated recycled fd (double-close is not idempotent)")

        close(target)
        if innocent != target { close(innocent) }
        close(fds[1])
    }

    // MARK: UDSListener.stop idempotency

    func testListenerStopIsIdempotentAndResetsFdAndDoesNotCloseAReusedFd() throws {
        let path = "/tmp/vigil_uds_\(getpid())_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let l = UDSListener(path: path)
        try l.start { _ in }
        let target = l.listenFd
        XCTAssertGreaterThanOrEqual(target, 0)

        l.stop()                                           // closes listenFd
        XCTAssertEqual(l.listenFd, -1, "after stop, listenFd must be set to -1")

        let innocent = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(innocent, 0)
        XCTAssertEqual(dup2(innocent, target), target)     // reuse the freed listener number

        l.stop()                                           // second stop: no-op, no double-close
        XCTAssertNotEqual(fcntl(target, F_GETFD), -1,
                          "a second stop on the listener shut an unrelated recycled fd")

        close(target)
        if innocent != target { close(innocent) }
    }
}
