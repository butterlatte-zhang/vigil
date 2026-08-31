import Foundation

// Cross-app-instance session liveness coordination — the liveness-lock layer.
//
// Two Vigil app instances share ONE archive root
// (~/Library/Application Support/Vigil/sessions/). If instance B resumes a session that
// instance A already holds live, both would drive the SAME `claude --resume <sid>`
// conversation into the SAME orchestration.jsonl — two roots, interleaved forensic trail,
// split brain.
//
// The fix is a plain advisory lock file per session dir:
//   <session-dir>/live.lock  =  {"pid": <holder>, "heartbeat": <iso8601>}
// The holding app WRITES it when the orchestrator starts, REFRESHES the heartbeat on the
// existing 60s harvester tick, and REMOVES it on clean close / normal quit. A resume is
// refused while the lock is LIVE = the recorded pid is still alive (kill -0) AND the
// heartbeat is fresh (< staleness, default 5 min). A crashed instance leaves a stale lock
// that expires on its own — the heartbeat is the primary guard (pid-reuse-safe), so a
// session never wedges permanently. Read-only replay (TranscriptRender) is never gated.

/// The on-disk lock payload. iso8601 heartbeat so a human can read it and the freshness
/// check is a plain Date comparison.
public struct SessionLiveLock: Codable, Equatable, Sendable {
    public var pid: Int32
    public var heartbeat: Date

    public init(pid: Int32, heartbeat: Date) {
        self.pid = pid
        self.heartbeat = heartbeat
    }
}

public enum SessionLock {
    public static let fileName = "live.lock"

    /// Heartbeat older than this = the holder is gone/hung → the lock self-heals. Wide on
    /// purpose (the harvester refreshes every 60s), so a merely-busy app is never mistaken
    /// for dead.
    public static let defaultStaleness: TimeInterval = 300   // 5 min

    public static func path(dir: String) -> String {
        (dir as NSString).appendingPathComponent(fileName)
    }

    /// Write/refresh the lock for `dir` with the current process's pid and `now`. Both the
    /// initial claim (orchestrator start) and every heartbeat go through here — a refresh
    /// is just an overwrite. Best-effort: a failed write only shortens our own lease.
    @discardableResult
    public static func write(dir: String, pid: Int32 = getpid(), now: Date = Date()) -> Bool {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return FileIO.writeJSON(SessionLiveLock(pid: pid, heartbeat: now), to: path(dir: dir),
                                encoder: enc)
    }

    public static func read(dir: String) -> SessionLiveLock? {
        guard let data = FileManager.default.contents(atPath: path(dir: dir)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionLiveLock.self, from: data)
    }

    public static func remove(dir: String) {
        try? FileManager.default.removeItem(atPath: path(dir: dir))
    }

    /// Is `dir` held live by a running app instance? True iff the lock exists, its
    /// heartbeat is fresh (< `staleness`) AND the recorded pid is alive. `pidAlive` is
    /// injectable for deterministic tests; the default asks the OS via kill(pid, 0).
    /// The freshness gate runs FIRST so a stale lock whose pid was recycled by an
    /// unrelated process still reads as dead (pid-reuse safety).
    public static func isLive(dir: String, now: Date = Date(),
                              staleness: TimeInterval = defaultStaleness,
                              pidAlive: (Int32) -> Bool = SessionLock.pidAlive) -> Bool {
        guard let lock = read(dir: dir) else { return false }
        guard now.timeIntervalSince(lock.heartbeat) < staleness else { return false }
        return pidAlive(lock.pid)
    }

    /// kill(pid, 0): 0 = the process exists and we may signal it; EPERM = it exists but is
    /// owned by another uid (still alive); ESRCH = no such process. A non-positive pid is
    /// never a real holder (0/-1 broadcast to process groups — refuse to treat as alive).
    public static func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Scan every session dir directly under `root` and remove `live.lock` files whose
    /// recorded pid is PROVABLY dead. No heartbeat-age rule: `isLive` already gates the
    /// resume question on heartbeat freshness (stale = not live), so a stale-but-alive-pid
    /// lock never wedges anything on its own — this sweep is pure hygiene, not a correctness
    /// requirement. An age rule would risk deleting a genuinely LIVE instance's claim (e.g. a
    /// laptop lid closed for a couple of days with Vigil open, its heartbeat harvester timer
    /// paused) right as a second instance starts on wake — zero gain, nonzero split-brain
    /// window. An unparseable lock file is left alone (not our call to guess at). Returns the
    /// removed lock file paths.
    @discardableResult
    public static func sweepStale(root: String, now: Date = Date(),
                                  pidAlive: (Int32) -> Bool = SessionLock.pidAlive) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var removed: [String] = []
        for name in names {
            let dir = root + "/" + name
            guard let lock = read(dir: dir) else { continue }   // missing / unparseable: leave alone
            guard !pidAlive(lock.pid) else { continue }
            let lockPath = path(dir: dir)
            try? fm.removeItem(atPath: lockPath)
            removed.append(lockPath)
        }
        return removed
    }
}
