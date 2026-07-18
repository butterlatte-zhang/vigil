import Foundation
import VigilGhosttyTerminal   // TerminalDebugLog — geometry telemetry into the shared sink
#if canImport(Darwin)
import Darwin
#endif

/// A host-managed PTY driver.
///
/// Vigil forks the agent process itself (`forkpty`), owns the master fd, pumps its
/// bytes, and reaps its exit — instead of handing the command to ghostty's `.exec`
/// path via `login(1)`, which swallows the real exit code and couples birth to a
/// live Metal surface. This type is deliberately **headless**: zero surface,
/// zero AppKit, so `swift test` can drive it against real child processes and pin the
/// forkpty/exec/reap risk in a GUI-less CI. The exit code is decoded honestly
/// (WIFEXITED→code / WIFSIGNALED→nil) and `onExit` is guaranteed to fire exactly once.
public final class HostPTY: @unchecked Sendable {

    private let lock = NSLock()
    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var fdClosed = false
    private var exitFired = false
    private var onExitCb: ((Int32?) -> Void)?
    /// A size requested BEFORE the fork (masterFd < 0) is remembered here and used as the
    /// fork winsize, instead of being dropped. The GhosttyBackend resize event
    /// fires during startOnMain's controller-assign — strictly before `pty.start()` — so
    /// without this the child forks at the 80×24 default and (the surface caches lastResize,
    /// no second event follows) stays there, painting an 80×24 box in a larger surface's
    /// top-left after resume. nil = never resized pre-start → fall back to 24×80.
    private var pendingWinsize: winsize?

    /// Test seam (@testable): fired inside `start()`'s parent branch, right after
    /// forkpty returns and BEFORE masterFd is published. Lets a test inject a resize() into
    /// the fork window to exercise the post-fork re-assert. Always nil in production.
    var _afterForkForTest: (() -> Void)?

    /// Serial queue the read source fires on. onData is delivered from here.
    private let readQueue = DispatchQueue(label: "vigil.hostpty.read")

    public init() {}

    // MARK: Lifecycle

    /// Fork a child under a fresh pseudo-terminal and start pumping/reaping it.
    /// `args` follow the `TerminalBackend` convention — argv[0] is NOT included;
    /// HostPTY prepends `executable` as argv[0] itself.
    /// `env` fully replaces the child environment (passed straight to execve). TERM
    /// et al. are the caller's responsibility, exactly like `HeadlessBackend`.
    public func start(executable: String, args: [String], env: [String: String], cwd: String,
                      onData: @escaping (Data) -> Void,
                      onExit: @escaping (Int32?) -> Void) {
        lock.lock(); onExitCb = onExit; lock.unlock()

        let argv = [executable] + args
        let envArr = env.map { "\($0.key)=\($0.value)" }

        // Build every C string in the PARENT, before forkpty. The child branch below
        // may call ONLY async-signal-safe functions (chdir/execve/_exit) — no Swift
        // allocation, no ARC, no locks — so nothing here can be deferred into it.
        let cArgv = Self.makeCStringArray(argv)
        let cEnv = Self.makeCStringArray(envArr)
        let cExe = strdup(executable)
        let cCwd = strdup(cwd)
        defer {   // parent-only cleanup; execve/_exit means the child never reaches it
            Self.freeCStringArray(cArgv)
            Self.freeCStringArray(cEnv)
            free(cExe); free(cCwd)
        }

        // Honor a pre-start resize as the fork winsize; default 24×80 otherwise.
        lock.lock(); let pending = pendingWinsize; lock.unlock()
        var ws = pending ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &ws)

        if pid < 0 {
            // fork failed — surface as abnormal termination (nil = failed).
            fireExit(nil)
            return
        }
        if pid == 0 {
            // CHILD — async-signal-safe only. forkpty already ran login_tty (setsid +
            // TIOCSCTTY), so the slave pty is our controlling terminal. Just move to
            // cwd and exec; the child inherits its own session/pgroup (pgid == pid).
            _ = chdir(cCwd)
            _ = execve(cExe, cArgv.base, cEnv.base)
            _exit(127)   // execve returned → command not found / not executable
        }

        // PARENT
        // Test seam (@testable only): invoked after forkpty returns but BEFORE
        // masterFd is published, so a test can drive a resize() into the fork window — while
        // the fd is still < 0 that resize can only update pendingWinsize, never reaching the
        // already-forked child. Reproduces the real backend's race where the surface pushes
        // the authoritative grid around the fork. nil in production (zero overhead).
        _afterForkForTest?()

        // Re-assert the latest requested size to the freshly-valid fd. pendingWinsize holds
        // whatever the most recent resize() asked for; the fork seeds from the last
        // PRE-start resize, but a size that lands after that read (masterFd still < 0 →
        // resize only updates pendingWinsize, never reaches forkpty) would leave the child
        // at the stale fork size. One TIOCSWINSZ / SIGWINCH converges it; a no-op reshape
        // when nothing changed. This only ADDS a correcting SIGWINCH — it does not change
        // the pre-start winsize seeding semantics.
        lock.lock()
        masterFd = master; childPid = pid
        let reassert = pendingWinsize
        lock.unlock()
        // Record the winsize the child actually forked at and whether it came
        // from a pre-start resize or the 24×80 default — geometry only, logged off the lock.
        TerminalDebugLog.log(
            .metrics,
            "hostpty start fork winsize cols=\(ws.ws_col) rows=\(ws.ws_row) px=\(ws.ws_xpixel)x\(ws.ws_ypixel) seed=\(pending != nil ? "pending" : "default")"
        )
        if var rw = reassert {
            _ = ioctl(master, TIOCSWINSZ, &rw)
            // A size that landed in the fork window is converged here.
            TerminalDebugLog.log(
                .metrics,
                "hostpty start re-assert cols=\(rw.ws_col) rows=\(rw.ws_row) px=\(rw.ws_xpixel)x\(rw.ws_ypixel)"
            )
        }

        // Non-blocking master so the read source can drain fully without blocking.
        let fl = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, fl | O_NONBLOCK)

        startReadLoop(fd: master, onData: onData)
        startReaper(pid: pid)
    }

    /// Run `block` on the read queue — serialized with `onData` delivery. The attach
    /// sequence uses this so its synthesize+replay + gate-lift land in order with live PTY bytes
    /// (any byte delivered before this block is captured in the screen STATE it snapshots; any
    /// after flows live once the gate is lifted). The read queue is a plain serial queue, always alive, so the
    /// block runs even after the child has exited (no onData in flight → immediate).
    public func enqueueOnReadQueue(_ block: @escaping () -> Void) {
        readQueue.async(execute: block)
    }

    /// Write raw bytes into the PTY master (keystrokes / injected input).
    public func write(_ data: Data) {
        lock.lock(); let fd = masterFd; lock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard var p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n > 0 { p += n; remaining -= n }
                else if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { break }   // fd closed / broken pipe — drop the rest
            }
        }
    }

    /// Push a new window size to the PTY (TIOCSWINSZ → SIGWINCH to the child).
    public func resize(cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        func u16(_ v: Int) -> UInt16 { UInt16(min(Int(UInt16.max), max(0, v))) }
        var ws = winsize(ws_row: u16(rows), ws_col: u16(cols),
                         ws_xpixel: u16(widthPx), ws_ypixel: u16(heightPx))
        // Before the fork (fd < 0) remember the size so start() forks at it, instead of
        // dropping it (dropping it is what left resume stuck at 80×24). pendingWinsize is
        // ALSO kept up to date once fd ≥ 0 so start()'s post-fork re-assert (below) always
        // has the latest requested size to converge the child to.
        lock.lock()
        let fd = masterFd
        pendingWinsize = ws
        lock.unlock()
        // Geometry telemetry, logged OUTSIDE the lock (red line: never from a lock region).
        // Before the fork the size is only buffered into pendingWinsize; after, it hits the child.
        guard fd >= 0 else {
            TerminalDebugLog.log(
                .metrics,
                "hostpty resize cols=\(cols) rows=\(rows) px=\(widthPx)x\(heightPx) -> buffered (pre-start)"
            )
            return
        }
        _ = ioctl(fd, TIOCSWINSZ, &ws)
        TerminalDebugLog.log(
            .metrics,
            "hostpty resize cols=\(cols) rows=\(rows) px=\(widthPx)x\(heightPx) -> applied fd=\(fd)"
        )
    }

    /// Force the child to repaint its whole screen from ITS own truth — a surface-attach
    /// fallback that redraws from the session truth source.
    /// When a fresh ghostty surface attaches, the synthesized attach replay can leave it drifted
    /// (an alt-screen primary buffer it cannot reconstruct, raced live bytes); a full-screen TUI (claude/codex/
    /// opencode) will rebuild its entire screen on a SIGWINCH, so this makes it do exactly that.
    ///
    /// Darwin raises SIGWINCH ONLY when the winsize actually changes (`ttioctl` compares before
    /// signalling), so a same-size re-assert is a silent no-op. A +1 column round-trip raises two
    /// SIGWINCHes whose FINAL size is the real one — the child repaints, and because the child's
    /// handler reads the current (restored) winsize it renders at the true width, with no vertical
    /// scroll. No-op before the fork (fd < 0). Lock-guarded, never touches a surface.
    public func nudgeRedraw() {
        lock.lock()
        let fd = masterFd
        let current = pendingWinsize
        lock.unlock()
        guard fd >= 0, var ws = current else { return }
        var perturbed = ws
        // Widen by one column (shrink only in the degenerate max-width case) so nothing scrolls.
        perturbed.ws_col = ws.ws_col == UInt16.max ? ws.ws_col &- 1 : ws.ws_col &+ 1
        _ = ioctl(fd, TIOCSWINSZ, &perturbed)   // size changed → SIGWINCH
        _ = ioctl(fd, TIOCSWINSZ, &ws)          // restore → SIGWINCH, child ends at the real size
        TerminalDebugLog.log(.metrics,
            "hostpty nudge-redraw cols=\(ws.ws_col) rows=\(ws.ws_row) (attach repaint)")
    }

    /// Kill the child's process group and reap it. Idempotent: repeated calls (or a
    /// call after natural exit) neither crash nor double-fire onExit. The actual
    /// onExit + fd close happen on the reaper/read-source paths, both guarded once.
    public func terminate() {
        lock.lock(); let pid = childPid; lock.unlock()
        guard pid > 0 else { return }
        // forkpty child is its own session/pgroup leader → pgid == pid. killpg on an
        // already-dead pgroup returns ESRCH, harmless.
        killpg(pid, SIGKILL)
    }

    /// The forkpty child's OS pid, once forked (>0), used for orphan reaping. nil before
    /// `start()` forks or after it failed. The reaper records this at spawn so a
    /// hard-killed Vigil's stranded children can be terminated by their EXACT pid on the
    /// next launch.
    public func childProcessID() -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        return childPid > 0 ? childPid : nil
    }

    // MARK: Read loop

    private func startReadLoop(fd: Int32, onData: @escaping (Data) -> Void) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData(Data(buf[0..<n]))
            } else if n == 0 {
                src.cancel()                              // EOF: child closed the slave
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                src.cancel()                              // EIO etc.: slave gone
            }
        }
        src.setCancelHandler { [weak self] in
            self?.closeFdOnce()
            self?.clearReadSource()
        }
        lock.lock(); readSource = src; lock.unlock()
        src.resume()
    }

    private func clearReadSource() { lock.lock(); readSource = nil; lock.unlock() }

    private func closeFdOnce() {
        lock.lock()
        if fdClosed { lock.unlock(); return }
        fdClosed = true
        let fd = masterFd; masterFd = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: Reaper

    private func startReaper(pid: pid_t) {
        // A dedicated blocking waitpid is the single, race-free reap path (avoids the
        // kqueue "process already a zombie at register time" race a DispatchSourceProcess
        // would carry). terminate()'s SIGKILL simply unblocks this waitpid.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while true {
                let r = waitpid(pid, &status, 0)
                if r == -1 && errno == EINTR { continue }
                break
            }
            self?.fireExit(Self.decodeExit(status))
        }
    }

    /// WIFEXITED → exit code; WIFSIGNALED → nil (matches terminate()).
    static func decodeExit(_ status: Int32) -> Int32? {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }   // WIFEXITED → WEXITSTATUS
        return nil                                    // WIFSIGNALED (or stopped) → nil
    }

    private func fireExit(_ code: Int32?) {
        lock.lock()
        if exitFired { lock.unlock(); return }
        exitFired = true
        let cb = onExitCb
        lock.unlock()
        cb?(code)
    }

    // MARK: C string helpers (built in parent, freed in parent)

    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

    private static func makeCStringArray(_ strings: [String]) -> CStringArray {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() { base[i] = strdup(s) }
        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ a: CStringArray) {
        for i in 0..<a.count { free(a.base[i]) }
        a.base.deallocate()
    }
}
