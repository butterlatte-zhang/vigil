import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// POSIX shell quoting for values Vigil writes into shell command strings — the hook
/// commands baked into claude's settings.json and the launch.sh wrapper. Single-quoting
/// is the only form that is safe for EVERY byte a filesystem path can carry ($, backtick,
/// quotes, spaces, parens, glob metacharacters): inside '…' the shell treats everything
/// literally, and an embedded ' is closed / backslash-escaped / reopened.
///
/// Naive quoting that only quotes when a space is present breaks on paths containing
/// `$`/`` ` ``/`(`, producing a command the shell mis-parses — and because these hooks
/// are fire-and-forget, the failure is SILENT (notifications/naming/status vanish).
public func posixShellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

#if canImport(Darwin)
/// Suppress SIGPIPE on a socket fd: writing to a peer that already closed must surface as
/// EPIPE on the return value, not kill the whole process with a signal — e.g. a killed
/// worker's shim closes while a gateway is still writing back a verdict.
@discardableResult
func silenceSIGPIPE(_ fd: Int32) -> Bool {
    var on: Int32 = 1
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                      socklen_t(MemoryLayout<Int32>.size)) == 0
}
#endif
