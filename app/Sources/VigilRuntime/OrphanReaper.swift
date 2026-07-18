import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Orphan-reap — reclaim agent child processes stranded by a hard-killed Vigil.
///
/// `SIGKILL Vigil` (the app process) leaves each cell's `claude`
/// child alive. An interactive claude ignores the SIGHUP it gets when Vigil's PTY master
/// closes, so it reparents to launchd and lives on — AND registers itself as a claude
/// background agent (`claude agents`) that still holds its session id. When a fresh Vigil
/// later resumes that dead row (`claude --resume <sid>`), claude refuses:
///   "Session <sid> is currently running as a background agent (bg). Use `claude agents`…"
/// until a human kills the stray by hand. codex/opencode orphans leak the same way (a live
/// child pinning a per-node CODEX_HOME / session), even though only claude has the resume
/// guard — so the reap is process-generic, keyed on the recorded pid, not the CLI family.
///
/// The fix runs ONCE at startup, before any resume: scan every session dir; for a session
/// whose liveness lock owner is dead but whose recorded cell pid is still alive AND
/// still the same process we spawned, terminate exactly that pid. Three independent guards
/// (the DOCTRINE process-hygiene red line, productized) gate every kill:
///   ① only the EXACT pid recorded at spawn — never a pattern, pgroup, or by-name match;
///   ② that pid's CURRENT identity still matches what we recorded — same exec path AND same
///      microsecond start time — so a recycled pid (now some unrelated process) is spared;
///   ③ the session's live.lock owner is confirmed dead — a session still held by a LIVE Vigil
///      instance (this one, or another running app) is never touched.
/// SIGTERM first, a short grace, then SIGKILL only if it ignored the term. Best-effort and
/// idempotent: a normally-exited pid reads dead (skip), a second run finds nothing to do.
public enum OrphanReaper {

    /// One recorded cell process, parsed from a `cell_pid` orchestration event.
    public struct CellRecord: Equatable, Sendable {
        public var node: String
        public var pid: Int32
        public var startTime: Double   // unix seconds (µs precision) captured at spawn
        public var exe: String         // argv[0] / exec path captured at spawn
        public init(node: String, pid: Int32, startTime: Double, exe: String) {
            self.node = node; self.pid = pid; self.startTime = startTime; self.exe = exe
        }
    }

    /// What happened to one candidate — returned for logging and asserted in tests.
    public struct Outcome: Equatable, Sendable {
        public enum Action: String, Sendable {
            case reapedTERM      // died to our SIGTERM within the grace
            case reapedKILL      // ignored SIGTERM, died to SIGKILL
            case skippedHeld     // session still held by a live instance
            case skippedDead     // pid already gone (normal exit / earlier reap)
            case skippedIdentity // pid alive but no longer our process (recycled) — SPARED
        }
        public var dir: String
        public var node: String
        public var pid: Int32
        public var action: Action
    }

    /// Injectable OS/IO seams — production wires the real ones (`.live`), tests drive fakes so
    /// no real process is ever signalled. All reads are side-effect-free; only `signal` mutates.
    public struct Deps {
        public var sessionDirs: () -> [String]
        public var sessionHeld: (_ dir: String) -> Bool
        public var records: (_ dir: String) -> [CellRecord]
        public var pidAlive: (Int32) -> Bool
        public var startTime: (Int32) -> Double?
        public var execPath: (Int32) -> String?
        public var signal: (_ pid: Int32, _ sig: Int32) -> Void
        public var sleep: (TimeInterval) -> Void
        public var log: (_ dir: String, _ node: String, _ pid: Int32, _ action: Outcome.Action) -> Void

        public init(sessionDirs: @escaping () -> [String],
                    sessionHeld: @escaping (String) -> Bool,
                    records: @escaping (String) -> [CellRecord],
                    pidAlive: @escaping (Int32) -> Bool,
                    startTime: @escaping (Int32) -> Double?,
                    execPath: @escaping (Int32) -> String?,
                    signal: @escaping (Int32, Int32) -> Void,
                    sleep: @escaping (TimeInterval) -> Void,
                    log: @escaping (String, String, Int32, Outcome.Action) -> Void) {
            self.sessionDirs = sessionDirs; self.sessionHeld = sessionHeld
            self.records = records; self.pidAlive = pidAlive
            self.startTime = startTime; self.execPath = execPath
            self.signal = signal; self.sleep = sleep; self.log = log
        }
    }

    /// Two start times are the "same" iff they agree to the microsecond — both come from the
    /// same `p_starttime` timeval ints, so a true match is exact; a recycled pid born even one
    /// tick apart fails. Rounded compare avoids Double representation noise.
    static func sameStart(_ a: Double, _ b: Double) -> Bool {
        Int64((a * 1_000_000).rounded()) == Int64((b * 1_000_000).rounded())
    }

    /// The pure core: walk every session, apply the three guards, signal the survivors.
    /// Returns one Outcome per candidate examined (drives tests + the forensic log).
    @discardableResult
    public static func reap(deps: Deps, graceSeconds: TimeInterval = 2.0) -> [Outcome] {
        var outcomes: [Outcome] = []
        for dir in deps.sessionDirs() {
            // Guard ③ (session level): a session still held by a live instance — this app's
            // freshly-claimed current session, or another running Vigil — is off limits.
            if deps.sessionHeld(dir) { continue }

            for rec in deps.records(dir) {
                let pid = rec.pid
                func emit(_ a: Outcome.Action) {
                    outcomes.append(Outcome(dir: dir, node: rec.node, pid: pid, action: a))
                    if a != .skippedDead { deps.log(dir, rec.node, pid, a) }
                }
                // Guard ①/liveness: a non-positive or already-dead pid = nothing to reap
                // (normal exit, or reaped on an earlier launch).
                guard pid > 0, deps.pidAlive(pid) else { emit(.skippedDead); continue }

                // Guard ②: the pid must STILL be the process we recorded — same exec path and
                // same microsecond birth. Any mismatch (or an unreadable argv/start time =
                // can't confirm) means the pid was recycled → spare it. Fail-safe.
                guard let st = deps.startTime(pid), sameStart(st, rec.startTime),
                      let exe = deps.execPath(pid), exe == rec.exe else {
                    emit(.skippedIdentity); continue
                }

                // All three guards passed → this is our orphan. SIGTERM, brief grace, then
                // SIGKILL only if it clung on (claude ignores SIGHUP but honors SIGTERM).
                deps.signal(pid, SIGTERM)
                deps.sleep(graceSeconds)
                if deps.pidAlive(pid) {
                    deps.signal(pid, SIGKILL)
                    emit(.reapedKILL)
                } else {
                    emit(.reapedTERM)
                }
            }
        }
        return outcomes
    }

    // MARK: production wiring

    /// Parse the latest `cell_pid` record per node from a session's orchestration.jsonl.
    /// A node can relaunch (resume) and log several — newest wins, mirroring replay's
    /// last-write rules. Malformed / partial records are skipped.
    public static func recordsFromLog(dir: String) -> [CellRecord] {
        guard let raw = try? String(contentsOfFile: dir + "/orchestration.jsonl",
                                    encoding: .utf8) else { return [] }
        var latest: [String: CellRecord] = [:]
        var order: [String] = []
        for line in raw.split(separator: "\n") {
            guard let obj = JSONLine.parse(String(line)),
                  obj["event"] as? String == "cell_pid",
                  let node = obj["node"] as? String,
                  let pidNum = obj["pid"] as? Int, pidNum > 0,
                  let st = obj["startTime"] as? Double,
                  let exe = obj["exe"] as? String
            else { continue }
            if latest[node] == nil { order.append(node) }
            latest[node] = CellRecord(node: node, pid: Int32(pidNum), startTime: st, exe: exe)
        }
        return order.compactMap { latest[$0] }
    }

    /// Real deps: sessions on disk, `SessionLock`/`ProcessInspect` for the OS reads, a
    /// blocking `usleep` for the grace, and a `cell_reaped` line appended to the reaped
    /// session's forensic trail. Signalling targets ONLY the exact recorded pid.
    public static func liveDeps(root: String, now: @escaping () -> Date = Date.init) -> Deps {
        Deps(
            sessionDirs: {
                let fm = FileManager.default
                guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
                return names.map { root + "/" + $0 }
                    .filter { fm.fileExists(atPath: $0 + "/orchestration.jsonl") }
            },
            sessionHeld: { SessionLock.isLive(dir: $0, now: now()) },
            records: recordsFromLog(dir:),
            pidAlive: ProcessInspect.alive,
            startTime: ProcessInspect.startTime,
            execPath: ProcessInspect.execPath,
            signal: { pid, sig in _ = ProcessInspect.signal(pid, sig) },
            sleep: { s in if s > 0 { usleep(useconds_t(min(s, 10) * 1_000_000)) } },
            log: { dir, node, pid, action in
                FileIO.appendJSONLine(
                    ["event": "cell_reaped", "node": node, "pid": Int(pid),
                     "action": action.rawValue,
                     "ts": OrchClock.format(now())],
                    to: dir + "/orchestration.jsonl")
            }
        )
    }

    /// Startup entry point: reap every orphan under `root`. Best-effort, safe to call once
    /// per launch on a background queue before any resume. Returns the outcomes (for logging).
    @discardableResult
    public static func reapAll(root: String, now: @escaping () -> Date = Date.init,
                              graceSeconds: TimeInterval = 2.0) -> [Outcome] {
        reap(deps: liveDeps(root: root, now: now), graceSeconds: graceSeconds)
    }
}
