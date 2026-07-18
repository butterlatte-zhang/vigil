//
//  TerminalSizePipeline.swift
//  VigilGhosttyTerminal
//
//  The single terminal-size authority and its settle gate. Every resize source (fork seed,
//  ghostty receiveResizeCallback, commitMetrics read-back, commitMetrics setSize) must
//  route through it — multiple uncoordinated size sources let the PTY grid and display
//  grid decouple and produce transient narrow reflow.
//

import Foundation

/// The canonical terminal grid — the SETTLED size of the current center pane.
///
/// Every cell renders into the same one center pane, so at any moment they should all be
/// the same grid. This carries that single authoritative size (INV1). It is:
///   • the fork seed for a newly-spawned off-screen worker (born full-width, no 24×80 wrap),
///   • the attach bootstrap a freshly-selected cell converges its surface/PTY/parser to,
///   • written ONLY from a settled (non-transient) resize — a layout-burst transient frame
///     is held by `TerminalSizePipeline` and never reaches here.
///
/// Thread-safety: `update` runs from the ghostty io thread (receiveResizeCallback → the
/// session resize closure) — it takes only this class's own lock, never the surface lock.
/// Hard red line: code reachable from a ghostty callback must never take the surface lock.
public struct CanonicalGrid: Equatable, Sendable {
    public var cols: Int
    public var rows: Int
    public var widthPx: Int
    public var heightPx: Int
    public init(cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        self.cols = cols; self.rows = rows; self.widthPx = widthPx; self.heightPx = heightPx
    }
}

public final class CanonicalPaneSize: @unchecked Sendable {
    private let lock = NSLock()
    private var _grid: CanonicalGrid?

    /// Smallest grid we accept as canonical. A sub-2-cell size is a degenerate layout-diff
    /// transient; it must never become the size a future cell is born at (mirrors
    /// `TerminalSurfaceCoordinator.isUsableViewSize`'s intent).
    static let minCols = 2
    static let minRows = 2

    public init(seed: CanonicalGrid? = nil) { _grid = seed }

    /// Record the latest SETTLED grid. Degenerate sizes are ignored (kept prior / kept nil).
    public func update(cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        guard cols >= Self.minCols, rows >= Self.minRows else { return }
        let g = CanonicalGrid(cols: cols, rows: rows, widthPx: widthPx, heightPx: heightPx)
        lock.lock(); _grid = g; lock.unlock()
    }

    /// The grid a newly-spawned cell should fork at / a selected cell converges to, or nil if
    /// none is known yet (the very first cell — the manager — falls back to the default-fork
    /// path and is corrected by its own on-screen surface build).
    public var current: CanonicalGrid? {
        lock.lock(); defer { lock.unlock() }; return _grid
    }
}

/// Per-surface size settle gate + attach bootstrap (INV1/INV2/INV4). Owned by the
/// `TerminalSurfaceCoordinator`, one per surface lifecycle, main-actor confined (it drives
/// `surface.setSize`, a main-actor op).
///
/// It is the SOLE writer of the surface's pixel size. By gating the SOURCE (the px we feed
/// the surface) rather than the OUTPUT (the PTY), the
/// display grid and the PTY grid can never decouple: the PTY follows ghostty's true grid,
/// and ghostty only ever computes grids for the SETTLED px this gate lets through. A
/// transient narrow attach/layout frame is therefore never rendered and never wrapped
/// (form ②/④ prevented, not repaired — matches the "burnt hard-wraps are unrecoverable"
/// red line: prevention is the only path).
///
/// Policy (grow-immediate / shrink-debounce, INV4):
///   • grow-or-equal in BOTH dims → commit immediately, cancel any held shrink (widen / open
///     sidebar never lags);
///   • shrink in EITHER dim → hold `debounceSeconds`; commit only if not superseded by a
///     larger/equal frame (a genuine user drag-narrow commits one beat late — ~100s of ms;
///     a transient attach frame is erased by the settle frame that follows within the window).
/// Re-offering the SAME shrink size does NOT reset the timer, so a stable narrow pane commits
/// after one debounce instead of being pinned forever.
@MainActor
final class TerminalSizePipeline {
    private let canonical: CanonicalPaneSize
    private let debounce: TimeInterval
    /// Feed a pixel size to the surface (`ghostty_surface_set_size`). Scale is handled
    /// separately (setContentScale is unconditional and immediate — not size-debounced).
    private let applySurfaceSize: (UInt32, UInt32) -> Void

    private var lastFedPixels: (w: UInt32, h: UInt32)?
    private var pendingShrink: DispatchWorkItem?
    private var pendingShrinkTarget: (w: UInt32, h: UInt32)?

    init(canonical: CanonicalPaneSize,
         debounceSeconds: TimeInterval = 0.30,
         applySurfaceSize: @escaping (UInt32, UInt32) -> Void) {
        self.canonical = canonical
        self.debounce = debounceSeconds
        self.applySurfaceSize = applySurfaceSize
    }

    /// Attach bootstrap: force the freshly-built surface straight to the canonical size and
    /// seed the grow/shrink baseline from it, so the FIRST real layout frame (which may be a
    /// transient narrow burst) is judged a shrink and held — never reflowing the just-attached
    /// child. No-op baseline when canonical is empty (first cell): the immediate first
    /// `offerLayout` then bootstraps from the real view size (pre-existing manager path).
    func seedAttachBaseline() {
        cancelPendingShrink()
        guard let g = canonical.current, g.widthPx >= 1, g.heightPx >= 1 else {
            lastFedPixels = nil
            return
        }
        let w = UInt32(g.widthPx), h = UInt32(g.heightPx)
        applySurfaceSize(w, h)
        lastFedPixels = (w, h)
    }

    /// commitMetrics feeds raw view pixels here. Applies the grow-immediate / shrink-debounce
    /// policy and is the only path that ever calls `applySurfaceSize`.
    func offerLayout(pixelWidth w: UInt32, pixelHeight h: UInt32) {
        guard w > 0, h > 0 else { return }
        guard let base = lastFedPixels else { commit(w, h); return }   // bootstrap
        if w >= base.w && h >= base.h {
            cancelPendingShrink()
            if w != base.w || h != base.h { commit(w, h) }
            return
        }
        // Shrink in at least one dim: hold. Re-offering the same target must NOT reset the
        // timer, else a steady narrow pane never commits (pin-forever).
        if let t = pendingShrinkTarget, t.w == w, t.h == h { return }
        scheduleShrink(w, h)
    }

    /// Drop any pending work (surface torn down). Called from the coordinator's teardown.
    func invalidate() { cancelPendingShrink() }

    // MARK: - internals

    private func commit(_ w: UInt32, _ h: UInt32) {
        applySurfaceSize(w, h)
        lastFedPixels = (w, h)
    }

    private func scheduleShrink(_ w: UInt32, _ h: UInt32) {
        cancelPendingShrink()
        pendingShrinkTarget = (w, h)
        let item = DispatchWorkItem { [weak self] in
            guard let self, let t = self.pendingShrinkTarget, t.w == w, t.h == h else { return }
            self.pendingShrink = nil
            self.pendingShrinkTarget = nil
            self.commit(w, h)
        }
        pendingShrink = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func cancelPendingShrink() {
        pendingShrink?.cancel()
        pendingShrink = nil
        pendingShrinkTarget = nil
    }
}
