import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Orphan-reap read-only OS process identity primitives (macOS/Darwin `sysctl`).
///
/// The orphan reaper needs two things about a candidate pid: is it the SAME process we
/// recorded at spawn (not a recycled pid), and may we signal it. Identity is pinned by the
/// pair **(exec path, start time)** — a recycled pid runs a different program and/or was born
/// at a different microsecond, so a match on both is proof it is our original child. These
/// are pure reads (no side effects), so they need no test seam themselves; the reaper injects
/// them as closures and unit-tests drive fakes.
public enum ProcessInspect {

    /// Process creation time as unix seconds (microsecond precision), from
    /// `kinfo_proc.kp_proc.p_un.__p_starttime`. nil = no such process / not permitted.
    public static func startTime(_ pid: pid_t) -> Double? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let r = sysctl(&mib, 4, &kp, &size, nil, 0)
        // size == 0 → the pid vanished between our mib build and the read.
        guard r == 0, size > 0 else { return nil }
        let tv = kp.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// The full argv of `pid`, index 0 = the exec path, via `KERN_PROCARGS2`. nil = gone /
    /// not permitted (EPERM for another uid's process — never our own children, so a nil here
    /// during reap means "can't confirm identity" → the reaper refuses to kill, fail-safe).
    public static func argv(_ pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: int argc; char exec_path[]; \0 padding; argv[0]\0 argv[1]\0 …; envp…
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<min(4, size)]) }
        var i = 4
        let execStart = i
        while i < size, buf[i] != 0 { i += 1 }
        let execPath = String(decoding: buf[execStart..<i], as: UTF8.self)
        while i < size, buf[i] == 0 { i += 1 }   // skip the padding run to argv[0]
        var args: [String] = []
        var n = 0
        while i < size, n < Int(argc) {
            let s = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1; n += 1
        }
        return [execPath] + args
    }

    /// argv[0] (the exec path) alone — the cheap half of the identity pair.
    public static func execPath(_ pid: pid_t) -> String? { argv(pid)?.first }

    /// kill(pid, 0): 0 = exists & signalable, EPERM = exists (other uid), ESRCH = gone.
    /// Same rule as `SessionLock.pidAlive`; duplicated here so the reaper's default deps read
    /// as one cohesive unit. A non-positive pid is never a real target.
    public static func alive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Send `sig` to exactly `pid` (never a pgroup — the reaper only ever targets the exact
    /// recorded pid, DOCTRINE process-hygiene red line). Best-effort; ESRCH is fine.
    @discardableResult
    public static func signal(_ pid: pid_t, _ sig: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, sig) == 0
    }
}
