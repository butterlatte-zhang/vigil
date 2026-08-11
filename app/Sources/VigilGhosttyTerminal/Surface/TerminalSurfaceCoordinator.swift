//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit
import MSDisplayLink

#if canImport(AppKit)
    import AppKit
#endif

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via scheduled wakeups.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    let bridge = TerminalCallbackBridge()

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    /// Called after every display-link render (`tick`).
    ///
    /// When `synchronizeMetrics` sends a new pixel size to ghostty via
    /// `setSize`, the underlying IOSurface is not rebuilt synchronously.
    /// Until the next full render pass ghostty still uses the **old**
    /// IOSurface, so it derives an incorrect `contentsScale` for the
    /// IOSurfaceLayer (e.g. old-pixel-height / new-point-height → 4.62
    /// instead of the expected 3.0). This causes a visible "jump" on
    /// every layout change (keyboard show/hide, rotation, color-scheme
    /// toggle, etc.).
    ///
    /// Platform views use this hook to silently enforce the correct
    /// `contentsScale` and `frame` on sublayers after each render,
    /// correcting any drift introduced by ghostty within a single frame.
    var onPostRender: (() -> Void)?

    /// ticket 7: the per-surface settle gate — the SOLE writer of `surface.setSize`. Built in
    /// `rebuildIfReady`, torn down with the surface. See `TerminalSizePipeline`.
    private var sizePipeline: TerminalSizePipeline?
    /// ticket 7: last grid handed to the resize DELEGATE (UI `surfaceSize` only, lag-tolerant —
    /// NOT the PTY authority). Dedup so a jittering read-back doesn't spam the delegate.
    private var lastUIGrid: TerminalGridMetrics?
    private var isDisplayVisible = true
    private var isApplicationActive = true
    private var isSurfaceFocused = false
    private var pendingImmediateTick = true
    private var lastTickTimestamp: TimeInterval = 0
    private var tickScheduled = false

    /// Count of repaint nudges requested via `requestImmediateTick`. No production reader; it
    /// exists so unit tests can observe that a committed-size change nudged a repaint without a
    /// real display link (which never spins up in an XCTest process).
    private(set) var immediateTickRequestCount = 0

    // MARK: - Wake retry (upstream ghostty discussion #13248 mitigation)

    // VIGIL: while the display is asleep / the login session is locked, the WindowServer
    // denies CVDisplayLink creation and `ghostty_surface_new` fails wholesale (tolerated
    // upstream only since ghostty PR #13639 — merge 71c2d68e, in no packaged libghostty
    // release yet). Vigil's surface is display-only (HOST_MANAGED: the agent process is
    // HostPTY-owned), so the damage is a blank pane — but the only other retry is the next
    // layout pulse (`fitToSize`), which may never come on an idle pane. A failed surface
    // build therefore arms a ONE-SHOT retry on screens-wake / session-unlock; success or
    // teardown disarms it. Remove once the pinned libghostty contains the upstream fix.

    /// Injection seams for tests. Real defaults: the NSWorkspace center (screens-wake)
    /// and the distributed center (`com.apple.screenIsUnlocked`).
    #if canImport(AppKit)
        var wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        var unlockNotificationCenter: NotificationCenter = DistributedNotificationCenter.default()
    #else
        var wakeNotificationCenter = NotificationCenter()
        var unlockNotificationCenter = NotificationCenter()
    #endif
    /// Count of `rebuildIfReady` entries. No production reader; unit tests observe that a
    /// wake signal drove a retry (same rationale as `immediateTickRequestCount`).
    private(set) var rebuildAttemptCount = 0
    /// Live (center, token) subscriptions; non-empty exactly while a retry is armed.
    private var wakeRetryObservers: [(NotificationCenter, NSObjectProtocol)] = []
    var wakeRetryArmed: Bool { !wakeRetryObservers.isEmpty }

    private func armWakeRetry() {
        guard wakeRetryObservers.isEmpty else { return }
        #if canImport(AppKit)
            let signals: [(NotificationCenter, Notification.Name)] = [
                (wakeNotificationCenter, NSWorkspace.screensDidWakeNotification),
                (unlockNotificationCenter, Notification.Name("com.apple.screenIsUnlocked")),
            ]
        #else
            let signals: [(NotificationCenter, Notification.Name)] = []
        #endif
        for (center, name) in signals {
            // queue nil = synchronous on the posting thread. Both real sources post on
            // main (NSWorkspace + distributed default), which keeps the retry — and the
            // tests — deterministic; a hypothetical off-main post hops instead of trapping.
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.wakeRetryFired() }
                } else {
                    Task { @MainActor [weak self] in self?.wakeRetryFired() }
                }
            }
            wakeRetryObservers.append((center, token))
        }
        TerminalDebugLog.log(.lifecycle, "surface build failed with display unavailable — wake retry armed")
    }

    private func disarmWakeRetry() {
        guard !wakeRetryObservers.isEmpty else { return }
        for (center, token) in wakeRetryObservers { center.removeObserver(token) }
        wakeRetryObservers.removeAll()
    }

    private func wakeRetryFired() {
        TerminalDebugLog.log(.lifecycle, "wake/unlock signal — retrying surface build")
        disarmWakeRetry() // one-shot; a retry that fails again re-arms in rebuildIfReady
        rebuildIfReady()
    }

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
        bridge.onRenderRequest = { [weak self] in
            self?.requestImmediateTick()
        }
    }

    func requestImmediateTick() {
        immediateTickRequestCount += 1
        pendingImmediateTick = true
        scheduleTickIfNeeded()
    }

    func startDisplayLink() {
        scheduleTickIfNeeded()
    }

    func stopDisplayLink() {
        tickScheduled = false
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        rebuildAttemptCount += 1
        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }
        guard hasValidViewSize else {
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface rebuild skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let scale = scaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)"
        )
        // ticket 7: open the attach converge window BEFORE the surface is created. From the moment
        // the session binds to the surface (inside createSurface) live bytes are held and
        // ghostty's transient build-time resize callback (the default narrow grid) is
        // suppressed — neither reaches the PTY/display until we have converged to canonical.
        let hostSession = configuration.inMemorySession
        hostSession?.beginAttachGate()
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            }
        )
        guard let rawSurface else {
            hostSession?.endAttachGate()
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            armWakeRetry() // ghostty #13248: locked/asleep display — retry on wake/unlock
            return
        }

        bridge.rawSurface = rawSurface
        let newSurface = TerminalSurface(rawSurface)
        surface = newSurface
        newSurface.setOcclusion(effectiveSurfaceVisible)
        // VIGIL: register (not overwrite) the wakeup render nudge — see
        // TerminalController.wakeupSubscribers. Render gating stays local
        // (scheduleTickIfNeeded checks canRenderFrame).
        controller.wakeupSubscribers[ObjectIdentifier(self)] = { [weak self] in
            self?.requestImmediateTick()
        }
        // ticket 7: the settle gate for THIS surface — the sole writer of surface.setSize. Bootstrap
        // it straight to the canonical grid so the surface is at the right width from the first
        // frame (INV2: the surface is in place first), and the baseline is seeded so the first real layout frame
        // (possibly a transient narrow burst) is judged a shrink and held, never reflowing.
        let pipeline = TerminalSizePipeline(
            canonical: configuration.canonicalPaneSize ?? CanonicalPaneSize(),
            applySurfaceSize: { [weak self] w, h in
                guard let self, let s = self.surface else { return }
                let sc = self.scaleFactor()
                s.setContentScale(x: sc, y: sc)
                s.setSize(width: w, height: h)
            })
        sizePipeline = pipeline
        pipeline.seedAttachBaseline()
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        // Deliver attach AFTER the surface is at canonical: the backend's attach closure now
        // converges the PTY/parser to canonical, replays the parser's synthesized snapshot into a
        // correctly sized surface, lifts the attach gate, and nudges a full repaint — serialized on the PTY
        // read queue so live bytes never interleave with the replay (INV2/INV3). The gate is
        // lifted by that closure; the coordinator does not touch it in the success path.
        (delegate as? any TerminalSurfaceLifecycleDelegate)?
            .terminalDidAttachSurface(newSurface)
        synchronizeMetrics()
        requestImmediateTick()
    }

    // MARK: - Metrics

    func synchronizeMetrics() {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return
        }

        let scale = scaleFactor()
        let size = viewSize()
        // VIGIL: reject sub-cell view sizes. During a SwiftUI/AppKit view-hierarchy
        // diff, setFrameSize/layout can fire fitToSize on a ~1pt intermediate frame
        // before the real bounds settle. Feeding that to ghostty's setSize collapses
        // the grid to 1 column; worse, the collapse is NOT propagated to the PTY,
        // because the surface.size() dedup gate below reads a stale grid and returns
        // early (screen shows 1 col while the PTY stays at the real width). Skipping
        // here is safe: a stable layout() re-syncs at the real bounds a tick later.
        guard Self.isUsableViewSize(width: size.width, height: size.height, scale: scale) else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: unusable view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale))"
            )
            return
        }

        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)"
            )
            return
        }

        TerminalDebugLog.log(
            .metrics,
            "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)"
        )

        // ticket 7: scale is immediate + unconditional; only the pixel SIZE goes through the
        // settle gate (grow-immediate / shrink-debounce). The gate is the ONLY writer of
        // surface.setSize, so a transient layout-burst narrow frame is never fed to ghostty
        // and never reflows the child — form ②/④ prevented at the source. The PTY is NOT
        // driven from here: it follows ghostty's OWN true grid via the session resize callback
        // (accurate, no read-back lag), so the display grid and the PTY grid cannot decouple.
        surface.setContentScale(x: scale, y: scale)
        sizePipeline?.offerLayout(pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        // UI-only surfaceSize: drive the resize DELEGATE from the read-back grid. This is
        // lag-tolerant (a stale read only lags a cursor metric by a frame) and NOT the PTY
        // authority. Deduped so a jittering read-back does not spam the delegate.
        updateDelegateGrid()
        onMetricsUpdate?()
        requestImmediateTick()
    }

    /// ticket 7: publish the surface's read-back grid to the resize delegate for UI `surfaceSize`
    /// only. Never touches the PTY (that follows ghostty's true grid via the io-side callback).
    private func updateDelegateGrid() {
        guard let surface, let grid = surface.size(),
              grid.columns > 0, grid.rows > 0, grid != lastUIGrid
        else { return }
        lastUIGrid = grid
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(grid)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(columns: Int(grid.columns), rows: Int(grid.rows))
        }
    }

    func fitToSize() {
        if surface == nil {
            rebuildIfReady()
        } else {
            synchronizeMetrics()
        }
        if surface != nil {
            requestImmediateTick()
        }
    }

    func setDisplayVisible(_ visible: Bool) {
        guard isDisplayVisible != visible else {
            surface?.setOcclusion(effectiveSurfaceVisible)
            return
        }

        isDisplayVisible = visible
        surface?.setOcclusion(effectiveSurfaceVisible)

        if canRenderFrame {
            requestImmediateTick()
        } else {
            stopDisplayLink()
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else {
            if active {
                renderImmediately()
            } else {
                stopDisplayLink()
            }
            return
        }

        isApplicationActive = active
        surface?.setOcclusion(effectiveSurfaceVisible)

        if active {
            synchronizeMetrics()
            renderImmediately()
        } else {
            stopDisplayLink()
        }
    }

    // MARK: - Frame Rendering

    func tick(context: DisplayLinkCallbackContext) {
        guard shouldRenderFrame(at: context.timestamp) else {
            return
        }
        pendingImmediateTick = false
        lastTickTimestamp = context.timestamp
        TerminalDebugLog.log(.render, "tick")
        controller?.tick()
        surface?.refresh()
        surface?.draw()
        onPostRender?()
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        isSurfaceFocused = focused
        requestImmediateTick()
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        // `@MainActor` classes have a nonisolated deinit by default, but
        // `tearDownSurface` calls methods on other main-actor types (surface,
        // bridge, controller). We rely on deinit running synchronously with
        // exclusive access; assume main-actor isolation so teardown can run
        // inline without crossing isolation.
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller)
        }
    }

    /// VIGIL: explicit cell termination (TerminalBackend.terminate() path).
    func vigilTearDown() {
        tearDownSurface(removingBridgeFrom: controller)
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        tickScheduled = false
        disarmWakeRetry() // a fresh rebuild pass re-arms on failure; a dead pane must not
        // keep retrying on every wake (rebuildIfReady's early-return guards never re-arm)
        if let session = configuration.inMemorySession {
            session.clearSurface(ifMatches: surface?.rawValue)
        }
        controller?.wakeupSubscribers[ObjectIdentifier(self)] = nil  // VIGIL: unsubscribe
        bridge.rawSurface = nil
        let hadSurface = surface != nil
        surface?.setFocus(false)
        surface?.free()
        surface = nil
        sizePipeline?.invalidate()   // ticket 7: drop any pending shrink for the gone surface
        sizePipeline = nil
        lastUIGrid = nil
        pendingImmediateTick = true
        lastTickTimestamp = 0
        controller?.remove(bridge)
        if hadSurface {
            (delegate as? any TerminalSurfaceLifecycleDelegate)?
                .terminalDidDetachSurface()
        }
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        requestImmediateTick()
        onCellSizeDidChange?()
    }

    private func shouldRenderFrame(at _: TimeInterval) -> Bool {
        guard canRenderFrame else {
            return false
        }
        return pendingImmediateTick || lastTickTimestamp == 0
    }

    private func scheduleTickIfNeeded() {
        guard canRenderFrame else {
            tickScheduled = false
            return
        }
        guard !tickScheduled else {
            return
        }
        tickScheduled = true
        TerminalDebugLog.log(.lifecycle, "tick scheduled")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tickScheduled = false
            let timestamp = Self.monotonicTimestamp()
            tick(
                context: .init(
                    duration: 0,
                    timestamp: timestamp,
                    targetTimestamp: timestamp
                )
            )
        }
    }

    private static func monotonicTimestamp() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private var effectiveSurfaceVisible: Bool {
        isDisplayVisible && isApplicationActive
    }

    private var canRenderFrame: Bool {
        effectiveSurfaceVisible && isAttached()
    }

    var hasValidViewSize: Bool {
        let size = viewSize()
        return Self.isUsableViewSize(width: size.width, height: size.height, scale: scaleFactor())
    }

    /// Smallest pixel edge (columns *or* rows) we will hand to ghostty's `setSize`.
    ///
    /// `assumedMaxCellPixels` is a deliberately generous upper bound on a single
    /// ghostty cell edge in device pixels — real cells at 2x are ~14-18px wide and
    /// ~30-40px tall, so 40px comfortably exceeds any real font. Requiring room for
    /// at least two cells (`minUsableCells`) yields an 80px floor per dimension. A
    /// view that pixel-small is never a real Vigil pane (~1pt layout-diff transient),
    /// while any genuine terminal clears it by an order of magnitude — so this rejects
    /// the collapse without ever false-rejecting a usable surface.
    static let assumedMaxCellPixels: Double = 40
    static let minUsableCells: Double = 2

    /// Pure, view-free predicate: is this point size (at `scale`) large enough to hold
    /// a minimal usable grid? Extracted so the floor is unit-testable without a surface.
    static func isUsableViewSize(width: Double, height: Double, scale: Double) -> Bool {
        guard width > 0, height > 0, scale > 0,
              width.isFinite, height.isFinite, scale.isFinite
        else { return false }
        let floorPixels = assumedMaxCellPixels * minUsableCells
        return (width * scale) >= floorPixels && (height * scale) >= floorPixels
    }

    private func renderImmediately() {
        guard canRenderFrame else {
            tickScheduled = false
            return
        }

        pendingImmediateTick = true
        tickScheduled = false
        let timestamp = Self.monotonicTimestamp()
        tick(
            context: .init(
                duration: 0,
                timestamp: timestamp,
                targetTimestamp: timestamp
            )
        )
    }
}
