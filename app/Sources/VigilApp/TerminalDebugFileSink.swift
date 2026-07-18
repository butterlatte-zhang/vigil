import Foundation

/// Terminal-observability file sink. Installed as `TerminalDebugLog.sink` when
/// `runtime.json terminalDebugLog` is on; writes geometry/lifecycle lines to
/// `<sessionDir>/terminal-debug.log` (append), routed to whichever session is currently
/// focused — a repro is worked in one session, so the active session's dir is the target.
///
/// Own lock only. It is deliberately NOT reachable from the ghostty/surface lock (a red line):
/// the sink acquires exactly this `lock` and the OS write; it never touches a surface. Callers on
/// the metrics/HostPTY paths log *outside* their own locks, so no lock is held across `write`.
///
/// Bounded by a simple size cap: when a line would push the file past `capBytes` the file is
/// truncated to empty and the run continues — old lines are dropped, disk stays bounded. Debug
/// telemetry, not an audit trail, so wrap-on-cap is the right trade.
final class TerminalDebugFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let capBytes: Int
    private var targetPath: String?
    private var handle: FileHandle?
    private var written: Int = 0

    init(capBytes: Int = 10 * 1024 * 1024) {
        self.capBytes = capBytes
    }

    /// Point the sink at a session dir (nil = nowhere, writes drop). Reopening a different file
    /// closes the previous handle. Idempotent for an unchanged path.
    func setTarget(sessionDir: String?) {
        let newPath = sessionDir.map { ($0 as NSString).appendingPathComponent("terminal-debug.log") }
        lock.lock()
        defer { lock.unlock() }
        guard newPath != targetPath else { return }
        closeLocked()
        targetPath = newPath
    }

    /// Stop writing and release the handle (mode → off).
    func close() {
        lock.lock()
        closeLocked()
        targetPath = nil
        lock.unlock()
    }

    /// The `@Sendable` closure to install as `TerminalDebugLog.sink`.
    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let path = targetPath else { return }
        if handle == nil { openLocked(path) }
        guard let h = handle else { return }
        let data = Data((line + "\n").utf8)
        if written + data.count > capBytes {
            // Wrap: truncate to empty and start over — bounds disk without a rotation scheme.
            try? h.truncate(atOffset: 0)
            try? h.seek(toOffset: 0)
            written = 0
        }
        do {
            try h.write(contentsOf: data)
            written += data.count
        } catch {
            // The file went away underneath us (session dir deleted) — drop the handle and let the
            // next write re-open. Never throw into the terminal hot path.
            closeLocked()
        }
    }

    // MARK: - locked helpers (caller holds `lock`)

    private func openLocked(_ path: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            _ = fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        // Append: seek to end and count existing bytes toward the cap.
        written = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func closeLocked() {
        try? handle?.close()
        handle = nil
        written = 0
    }
}
