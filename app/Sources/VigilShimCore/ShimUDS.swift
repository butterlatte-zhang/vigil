// VigilShimCore — the UDS client boilerplate shared by the two tiny shims
// (vigil-hook: fire-and-forget hook client · vigil-mcp: stdio↔UDS pipe). `writeAll` guards
// baseAddress rather than force-unwrapping it (behavior-equivalent: baseAddress is nil only
// for an empty buffer, which neither shim ever writes; the guard makes that edge a no-op
// instead of a crash). Keep this module ZERO-dependency (Foundation/Darwin only): the
// shims are spawned per hook firing and must stay tiny and instant to launch.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `--name value` lookup. `arguments` is injectable for tests; the default is the
/// process's own argv — exactly what both shims read.
public func arg(_ name: String, in arguments: [String] = CommandLine.arguments) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

/// Connect to a UDS path; nil on any failure (socket / overlong path / refused) — the
/// callers fail open. SO_NOSIGPIPE rides every fd: writing to a dead peer must surface
/// as EPIPE, never signal-kill the shim.
public func connectUDS(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var noSigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[bytes.count] = 0
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    if r != 0 { close(fd); return nil }
    return fd
}

/// Write the whole buffer, retrying short writes; an error/EOF abandons the rest —
/// the shims' fail-open posture (they never report write failures, they just exit).
public func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>) {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var done = 0
        while done < raw.count {
            let n = write(fd, base + done, raw.count - done)
            if n <= 0 { break }
            done += n
        }
    }
}
