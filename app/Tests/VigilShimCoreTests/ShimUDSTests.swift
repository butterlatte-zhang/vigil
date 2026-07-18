import Foundation
import XCTest
@testable import VigilShimCore
#if canImport(Darwin)
import Darwin
#endif

// The shims' arg/connectUDS/writeAll implementation is shared across two executables.
// These tests pin the shared implementation — wire bytes, SO_NOSIGPIPE, fail-open nils —
// so the next change happens ONCE and under test.

final class ShimUDSTests: XCTestCase {

    // MARK: arg

    func testArgParsesNameValuePairs() {
        let argv = ["shim", "--node", "n1", "--sock", "/tmp/x.sock", "--flag"]
        XCTAssertEqual(arg("--node", in: argv), "n1")
        XCTAssertEqual(arg("--sock", in: argv), "/tmp/x.sock")
        XCTAssertNil(arg("--missing", in: argv))
        XCTAssertNil(arg("--flag", in: argv))       // name in last slot: no value to take
    }

    // MARK: writeAll

    func testWriteAllDeliversExactBytes() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        // A shim-shaped envelope plus non-UTF8 bytes: delivery must be byte-exact.
        let payload = Array(#"{"node":"n1","event":"stop"}"#.utf8) + [0x0A, 0x00, 0xFF]
        writeAll(fds[0], payload[...])
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fds[1], &buf, buf.count)
        XCTAssertEqual(Array(buf[0..<max(n, 0)]), payload)
    }

    func testWriteAllEmptyBufferIsANoOp() {
        // An empty buffer must not crash (guard, not force-unwrap): empty in = nothing out, no crash.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        writeAll(fds[0], ([] as [UInt8])[...])
    }

    // MARK: connectUDS

    func testConnectUDSReachesAListenerAndSetsNoSigpipe() {
        let path = "/tmp/vigil_shim_test_\(getpid())_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(lfd, 0)
        defer { close(lfd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, size) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(lfd, 4), 0)

        guard let cfd = connectUDS(path) else { return XCTFail("connectUDS failed") }
        defer { close(cfd) }

        // SO_NOSIGPIPE must be set on the client fd.
        var v: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &v, &len), 0)
        XCTAssertEqual(v, 1)

        let afd = accept(lfd, nil, nil)
        XCTAssertGreaterThanOrEqual(afd, 0)
        defer { close(afd) }
        writeAll(cfd, Array("ping\n".utf8)[...])
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(afd, &buf, buf.count)
        XCTAssertEqual(String(bytes: buf[0..<max(n, 0)], encoding: .utf8), "ping\n")
    }

    func testConnectUDSFailsCleanToNil() {
        XCTAssertNil(connectUDS("/nonexistent/definitely/missing.sock"))   // refused
        XCTAssertNil(connectUDS(String(repeating: "x", count: 300)))       // > sun_path cap
    }
}
