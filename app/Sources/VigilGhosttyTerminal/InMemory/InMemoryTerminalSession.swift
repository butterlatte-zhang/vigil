//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    /// `lastResize` has its OWN lock, never `lock`. The termio io thread re-enters
    /// this class via `receiveResizeCallback` while a host-side caller can be parked
    /// INSIDE `ghostty_surface_write_buffer` under `lock` (termio mailbox full — it waits
    /// for that very io thread to drain). A single shared lock here can produce a main↔io
    /// AB-BA deadlock that freezes the whole app. The resize path touches
    /// only `lastResize` + `resizeHandler` and never the surface, so the split is the
    /// correct ownership, not just a workaround. RED LINE: nothing reachable from a
    /// ghostty callback (receiveBufferCallback / receiveResizeCallback) may take `lock`.
    private let resizeLock = NSLock()
    private var surface: ghostty_surface_t?
    /// Monotonic identity for the currently attached surface. OSC queries can span multiple PTY
    /// reads; returning this token with each actual write proves that every chunk reached the
    /// same surface, not merely that some surface happened to exist for each chunk.
    private var surfaceGeneration: UInt64 = 0
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    /// Attach gate. Its own tiny lock (never the surface `lock`, never `resizeLock`) so
    /// it is safe to read from any thread including a ghostty callback (the RED LINE above). While
    /// `_attaching` is set the coordinator is converging a freshly-built surface to the
    /// canonical size and replaying the synthesized snapshot: LIVE bytes (`receive`) are dropped —
    /// they are captured in the host parser's screen STATE and re-enter via `replay` — and
    /// ghostty's own transient surface-creation resize callbacks (`dispatchResize`) are suppressed
    /// so the default narrow build frame never reaches the PTY. `replay` bypasses the byte gate.
    /// The deterministic converge/replay/lift sequence lives in the backend's attach closure.
    private let gateLock = NSLock()
    private var _attaching = false

    /// The attach GRID BARRIER. The attach replay must not run until
    /// ghostty has ACTUALLY applied the surface's canonical size — proven by a
    /// `receiveResizeCallback` reporting a pixel size within one cell of the requested canonical
    /// px. Without it, replay races `seedAttachBaseline`'s async `setSize`: the surface consumes
    /// the replayed absolute-CUP frame on ghostty's transient build-default grid (~46 cols),
    /// wrapping+overprinting every line into scatter (proven by `vigil-winrepro`; independent of
    /// replay size, so short-lived cells garble too). Event-driven, NO surface readback (surface
    /// state is async — "we called setSize" ≠ "the grid is canonical").
    /// Its OWN lock (never `lock`, never `resizeLock`, never `gateLock`) so it is safe to test
    /// from a ghostty callback (the RED LINE above). Armed disarmed (`barrierFired = true`) by default.
    private let barrierLock = NSLock()
    private var barrierTargetPx: (w: Int, h: Int, tol: Int)?
    private var barrierOnReady: ((InMemoryTerminalViewport?) -> Void)?
    private var barrierFired = true
    private var lastSeenViewport: InMemoryTerminalViewport?

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }
        if self.surface != surface { surfaceGeneration &+= 1 }
        self.surface = surface
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }

        guard surface == expectedSurface else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surface == nil ? "nil" : "set")"
            )
            return
        }

        if surface != nil { surfaceGeneration &+= 1 }
        surface = nil
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    /// Public surface-lifecycle fact used by diagnostics/reentrancy tests. OSC reply ownership
    /// deliberately does not infer from this pointer: during the attach gate a surface exists
    /// but has not received the held live bytes.
    public var currentSurface: ghostty_surface_t? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached. Lines are separated by `\n`. The `ghostty_text_s`
    /// lifecycle (allocate via `ghostty_surface_read_text`, free via
    /// `ghostty_surface_free_text`) is fully encapsulated — callers never
    /// touch the C buffer.
    ///
    /// Selection grammar: `(VIEWPORT, TOP_LEFT)` to `(VIEWPORT, BOTTOM_RIGHT)`
    /// with `rectangle: false` (linear flow). This reads exactly the visible
    /// rows and ignores scrollback. Empty viewports return an empty string.
    ///
    /// Thread-safe: acquires the same `NSLock` as `receive(_:)` and
    /// `setSurface(_:)`, preventing reads against a surface mid-replacement.
    public func readViewportText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            return ""
        }
        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    ///
    /// `ghostty_surface_write_buffer` can BLOCK (termio mailbox full) until
    /// the surface's io thread drains it — so this holds `lock` across a potentially
    /// long wait. That is safe only because no ghostty-callback path takes `lock`
    /// (see `resizeLock`). Keep it that way.
    @discardableResult
    public func receive(_ data: Data) -> UInt64? {
        // During the attach converge/replay window LIVE bytes are dropped here — they
        // are captured in the host parser's screen STATE and re-enter the surface, in order, via
        // `replay` (the synthesized snapshot) once the surface has converged to the canonical
        // size. Suppressing live during the window is what makes the attach replay the single
        // ordered source (INV3: no interleave, no double-write). Gate read under its own tiny
        // lock, never `lock`.
        gateLock.lock(); let gated = _attaching; gateLock.unlock()
        if gated {
            TerminalDebugLog.log(.output, "terminal <- host held(attaching) \(TerminalDebugLog.describe(data))")
            return nil
        }
        return writeToSurface(data)
    }

    /// Attach-replay path — writes to the surface bypassing the attach byte gate. The
    /// backend's attach closure (VigilRuntime) calls this once, after the surface has converged
    /// to canonical, with the parser's synthesized snapshot; then it lifts the gate so live bytes
    /// flow.
    public func replay(_ data: Data) {
        _ = writeToSurface(data)
    }

    private func writeToSurface(_ data: Data) -> UInt64? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let surface else {
            TerminalDebugLog.log(
                .output,
                "terminal <- host dropped \(TerminalDebugLog.describe(data))"
            )
            return nil
        }

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        return data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
            return surfaceGeneration
        }
    }

    // MARK: - Attach gate

    /// Begin the attach converge window: drop live bytes + suppress ghostty's transient
    /// build-time resize callbacks. Set BEFORE the surface is created so the default narrow
    /// build frame is caught. Idempotent.
    func beginAttachGate() {
        gateLock.lock(); _attaching = true; gateLock.unlock()
    }

    /// End the attach window: resume live bytes + accept resize callbacks. Called by the
    /// backend's attach closure (VigilRuntime) after the attach replay, serialized on the PTY
    /// read queue so it lands strictly after replay (INV3).
    public func endAttachGate() {
        gateLock.lock(); _attaching = false; gateLock.unlock()
    }

    var isAttaching: Bool {
        gateLock.lock(); defer { gateLock.unlock() }; return _attaching
    }

    // MARK: - Attach grid barrier

    /// Arm the one-shot grid barrier. `onReady` fires with ghostty's ACTUAL reported grid on the
    /// FIRST of: a `receiveResizeCallback` whose pixel size is within `tolerancePx` of
    /// (widthPx, heightPx) — i.e. the surface reached canonical — or `timeout` (bounded
    /// fail-open: fires with the last-seen grid, or nil, and the caller converges to canonical
    /// anyway; `nudgeRedraw` still recovers a well-behaved TUI). If a matching grid was already
    /// reported before arming, fires immediately. Fires exactly once.
    public func awaitCanonicalGrid(widthPx: Int, heightPx: Int, tolerancePx: Int,
                                   timeout: TimeInterval,
                                   onReady: @escaping (InMemoryTerminalViewport?) -> Void) {
        barrierLock.lock()
        if let last = lastSeenViewport,
           abs(Int(last.widthPixels) - widthPx) <= tolerancePx,
           abs(Int(last.heightPixels) - heightPx) <= tolerancePx {
            barrierFired = true
            barrierOnReady = nil
            barrierTargetPx = nil
            barrierLock.unlock()
            TerminalDebugLog.log(.metrics,
                "attach grid barrier fired (already-canonical \(last.columns)x\(last.rows))")
            onReady(last)
            return
        }
        barrierTargetPx = (widthPx, heightPx, tolerancePx)
        barrierOnReady = onReady
        barrierFired = false
        barrierLock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.barrierLock.lock()
            guard !self.barrierFired, let cb = self.barrierOnReady else {
                self.barrierLock.unlock(); return
            }
            self.barrierFired = true
            self.barrierOnReady = nil
            self.barrierTargetPx = nil
            let fallback = self.lastSeenViewport
            self.barrierLock.unlock()
            TerminalDebugLog.log(.metrics, "attach grid barrier fired (TIMEOUT fail-open)")
            cb(fallback)
        }
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    @discardableResult
    public func receive(_ string: String) -> UInt64? {
        guard let data = string.data(using: .utf8) else { return nil }
        return receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        // Record EVERY reported grid (even while the attach gate
        // suppresses forwarding) and test the grid barrier, so the replay can wait for ghostty's
        // canonical grid to actually land. Own lock only (never the surface `lock`). The
        // fired `onReady` just enqueues onto the PTY read queue (in the backend) — no surface
        // write happens inline on this io thread.
        barrierLock.lock()
        lastSeenViewport = resize
        var fire: ((InMemoryTerminalViewport?) -> Void)?
        if !barrierFired, let t = barrierTargetPx,
           abs(Int(resize.widthPixels) - t.w) <= t.tol,
           abs(Int(resize.heightPixels) - t.h) <= t.tol {
            barrierFired = true
            fire = barrierOnReady
            barrierOnReady = nil
            barrierTargetPx = nil
        }
        barrierLock.unlock()
        if let fire {
            TerminalDebugLog.log(.metrics,
                "attach grid barrier fired (grid confirmed \(resize.columns)x\(resize.rows) px=\(resize.widthPixels)x\(resize.heightPixels))")
            fire(resize)
        }

        // Suppress ghostty's transient surface-build resize callbacks during the attach
        // converge window. Without this, ghostty emits a default narrow grid (e.g. 46 cols)
        // the instant the surface is created — BEFORE the coordinator converges it to
        // canonical — and that transient would ride straight to the PTY (child SIGWINCH →
        // hard-wrap). The attach closure pushes the PTY to canonical explicitly instead.
        gateLock.lock(); let gated = _attaching; gateLock.unlock()
        if gated {
            TerminalDebugLog.log(
                .metrics,
                "resize suppressed(attaching) cols=\(resize.columns) rows=\(resize.rows) pixels=\(resize.widthPixels)x\(resize.heightPixels)"
            )
            return
        }
        resizeLock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        resizeLock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
