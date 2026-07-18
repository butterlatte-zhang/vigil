import Foundation
#if canImport(Darwin)
import Darwin
#endif

// UDS transport for the two gateways (DOCTRINE §5.4). A connected socket fd becomes a
// LineChannel; a listener binds a per-session socket and hands each accepted connection
// to a handler. Currently local-trusted, plaintext `--node` (no fd-binding/peer-uid yet,
// §10.0). Newline-delimited framing matches the shims and MCP's stdio transport.

/// One connected UDS fd as a newline-delimited LineChannel. All fd/buffer state is
/// serialized on the per-channel `readQ`; readLine() is awaited serially by the handler.
///
/// The read side is DRIVEN by a DispatchSourceRead over a NON-BLOCKING fd, not a thread
/// parked in a blocking read() (DOCTRINE §8). A thread blocked in read() for a connection's
/// whole idle life — one per live cell's MCP link — would make the ~64-thread GCD pool a
/// hidden active-cell ceiling. The source parks no thread while idle: it wakes a handler
/// only when bytes actually arrive.
public final class SocketLineChannel: LineChannel, @unchecked Sendable {
    private let fd: Int32
    private let readQ: DispatchQueue
    private let writeQ: DispatchQueue
    private var buffer = Data()
    private var eof = false
    /// The read source (created lazily on first readLine, torn down on EOF/close). All
    /// source + buffer + waiter + eof mutation happens on `readQ` — no extra locking.
    private var source: DispatchSourceRead?
    private var sourceResumed = false
    /// At most one in-flight readLine continuation (the gateway awaits serially).
    private var waiter: CheckedContinuation<String?, Never>?
    /// Close guard. A second close() must NOT re-issue Darwin.close(fd) — the fd
    /// number may already be reused by another cell's socket/PTY, and double-close would
    /// tear down that innocent fd (a classic hard-to-find cross-cell race).
    private var closed = false
    private let closeLock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        silenceSIGPIPE(fd)     // writing a dead peer must EPIPE, not signal-kill
        #endif
        // Non-blocking so neither the source handler's read() nor a full-buffer write()
        // ever parks a GCD thread indefinitely. write() re-blocks only transiently via poll
        // under backpressure (below); the read handler drains until EAGAIN and returns.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        self.readQ = DispatchQueue(label: "vigil.sock.read.\(fd)")
        self.writeQ = DispatchQueue(label: "vigil.sock.write.\(fd)")
    }

    public func readLine() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            readQ.async {
                if let line = self.popLine() { cont.resume(returning: line); return }
                if self.eof { cont.resume(returning: nil); return }
                self.waiter = cont
                self.ensureSource()          // wake the source; it delivers on the next bytes
            }
        }
    }

    // MARK: read source (all on readQ)

    /// Create the source once and resume it. Resumed exactly once for the channel's life;
    /// torn down (cancelled) only on EOF or close.
    private func ensureSource() {
        if source == nil {
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQ)
            s.setEventHandler { [weak self] in self?.onReadable() }
            source = s
        }
        if !sourceResumed { sourceResumed = true; source?.resume() }
    }

    /// The fd is readable — drain all available bytes (non-blocking) into the buffer, then
    /// hand the waiter its line if one completed.
    private func onReadable() {
        var tmp = [UInt8](repeating: 0, count: 8192)
        drain: while true {
            let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { buffer.append(contentsOf: tmp[0..<n]); continue }
            if n == 0 { eof = true; break }              // peer closed
            switch errno {
            case EINTR: continue                          // interrupted — retry
            case EAGAIN: break drain                       // socket drained; await the next fire
            default: eof = true; break drain              // real error → treat as EOF
            }
        }
        if eof { cancelSource() }                         // stop the level-triggered EOF re-fire
        deliver()
    }

    /// Resume the pending readLine when a full line is available, or nil at EOF.
    private func deliver() {
        guard let cont = waiter else { return }
        if let line = popLine() { waiter = nil; cont.resume(returning: line) }
        else if eof { waiter = nil; cont.resume(returning: nil) }
        // else: partial line — keep the source armed for more bytes.
    }

    /// Cancel + drop the source (on readQ). A suspended source must be resumed before
    /// release, or libdispatch traps.
    private func cancelSource() {
        guard let s = source else { return }
        if !sourceResumed { sourceResumed = true; s.resume() }
        s.cancel()
        source = nil
    }

    /// Pop one complete line (without the trailing \n) from the buffer, or nil.
    private func popLine() -> String? {
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
        buffer.removeSubrange(buffer.startIndex...nl)
        return String(data: lineData, encoding: .utf8) ?? ""
    }

    public func write(_ line: String) async {
        let bytes = Array((line + "\n").utf8)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQ.async {
                var off = 0
                bytes.withUnsafeBytes { raw in
                    let base = raw.baseAddress!
                    while off < bytes.count {
                        let n = Darwin.write(self.fd, base + off, bytes.count - off)
                        if n > 0 { off += n; continue }
                        if n < 0 && errno == EINTR { continue }
                        // The fd is non-blocking now — a full send buffer returns EAGAIN
                        // where a blocking fd used to sleep. Wait for writability (transient,
                        // only under backpressure) and retry, so bytes are never dropped.
                        if n < 0 && (errno == EAGAIN) {
                            var pfd = pollfd(fd: self.fd, events: Int16(POLLOUT), revents: 0)
                            if poll(&pfd, 1, -1) < 0 && errno == EINTR { continue }
                            if pfd.revents & Int16(POLLOUT) != 0 { continue }
                            break                          // POLLHUP/POLLERR: peer gone
                        }
                        break                              // peer gone; reader will surface EOF
                    }
                }
                cont.resume()
            }
        }
    }

    /// Synchronous claim of the close (keeps NSLock off the async body — the v6 warning
    /// RealCell.withLock also sidesteps). Returns true for the FIRST caller only.
    private func claimClose() -> Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        if closed { return false }
        closed = true
        return true
    }

    public func close() async {
        guard claimClose() else { return }    // idempotent — close the fd exactly once
        // Tear down on readQ so source teardown + fd close + waiter resume are serialized
        // with the handler (no concurrent touch of source/buffer/waiter). Awaited, so the
        // fd is really closed by the time close() returns.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readQ.async {
                self.cancelSource()
                Darwin.close(self.fd)
                self.eof = true
                if let w = self.waiter { self.waiter = nil; w.resume(returning: nil) }
                cont.resume()
            }
        }
    }
}

/// Binds a Unix-domain socket and serves each accepted connection via `handler`.
public final class UDSListener: @unchecked Sendable {
    public let path: String
    /// -1 = not started / stopped. private(set) so idempotency tests can observe
    /// the fd-reset after stop() (the visible half of "don't double-close a reused fd").
    private(set) var listenFd: Int32 = -1
    private let acceptQ: DispatchQueue

    public init(path: String) {
        self.path = path
        self.acceptQ = DispatchQueue(label: "vigil.uds.accept")
    }

    public func start(_ handler: @escaping @Sendable (SocketLineChannel) -> Void) throws {
        unlink(path)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw UDSError.socket(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw UDSError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFd, $0, size) }
        }
        guard bindResult == 0 else { Darwin.close(listenFd); throw UDSError.bind(errno) }
        guard listen(listenFd, 32) == 0 else { Darwin.close(listenFd); throw UDSError.listen(errno) }
        chmod(path, 0o600)

        acceptQ.async { [listenFd] in
            while true {
                let conn = accept(listenFd, nil, nil)
                if conn < 0 {
                    if errno == EINTR { continue }
                    break                       // listener closed
                }
                handler(SocketLineChannel(fd: conn))
            }
        }
    }

    public func stop() {
        // Idempotent — reset listenFd to -1 after closing so a second stop() can't
        // double-close a number the system may have handed to another socket. The accept
        // loop captured listenFd by value, so this reset never disturbs an in-flight accept.
        guard listenFd >= 0 else { return }
        Darwin.close(listenFd)
        listenFd = -1
        unlink(path)
    }
}

public enum UDSError: Error, CustomStringConvertible {
    case socket(Int32), bind(Int32), listen(Int32), pathTooLong(String)
    public var description: String {
        switch self {
        case .socket(let e): return "socket() failed errno=\(e)"
        case .bind(let e): return "bind() failed errno=\(e)"
        case .listen(let e): return "listen() failed errno=\(e)"
        case .pathTooLong(let p): return "UDS path too long: \(p)"
        }
    }
}
