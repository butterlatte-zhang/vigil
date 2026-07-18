import XCTest
@testable import VigilGhosttyTerminal

/// Deterministic unit coverage for the attach GRID BARRIER
/// (`InMemoryTerminalSession.awaitCanonicalGrid`). The barrier is what makes the ring replay
/// wait until ghostty has actually APPLIED the canonical surface size, instead of racing
/// `seedAttachBaseline`'s async `setSize` and replaying onto the transient build-default grid
/// (~46 cols → wrap/overprint garble). The end-to-end proof is `vigil-winrepro`
/// (REPRO_ATTACH_GARBLE, RED with VIGIL_ATTACH_BARRIER_OFF=1 / GREEN without); this pins the
/// arm → match → fire / fail-open logic without a window-server surface.
///
/// `updateViewport(_:)` is the test seam: it funnels into the same private `dispatchResize`
/// ghostty's `receiveResizeCallback` uses, so feeding a `TerminalGridMetrics` here exercises the
/// exact barrier code path a real resize callback would.
final class AttachGridBarrierTests: XCTestCase {

    private func makeSession() -> InMemoryTerminalSession {
        InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    }

    private func metrics(cols: UInt16, rows: UInt16, wPx: UInt32, hPx: UInt32) -> TerminalGridMetrics {
        TerminalGridMetrics(columns: cols, rows: rows, widthPixels: wPx, heightPixels: hPx,
                            cellWidthPixels: 17, cellHeightPixels: 37)
    }

    /// The winrepro sequence: ghostty first reports its narrow build-default (46×16), THEN the
    /// canonical grid (139×39, px 2372×1472 ≈ the requested 2380×1480). The barrier must ignore
    /// the narrow transient and fire exactly once, on the canonical grid, handing back ghostty's
    /// ACTUAL reported grid (139×39, not the seed estimate).
    func testIgnoresNarrowBuildDefaultThenFiresOnCanonical() {
        let session = makeSession()
        var fireCount = 0
        var reported: InMemoryTerminalViewport?
        session.awaitCanonicalGrid(widthPx: 2380, heightPx: 1480, tolerancePx: 80, timeout: 5) {
            fireCount += 1; reported = $0
        }
        // Transient build-default — px far from canonical → must NOT fire.
        session.updateViewport(metrics(cols: 46, rows: 16, wPx: 782, hPx: 592))
        XCTAssertEqual(fireCount, 0, "narrow build-default must not fire the barrier")

        // Canonical grid lands (px within one cell of the requested 2380×1480) → fires once.
        session.updateViewport(metrics(cols: 139, rows: 39, wPx: 2372, hPx: 1472))
        XCTAssertEqual(fireCount, 1, "canonical grid must fire the barrier exactly once")
        XCTAssertEqual(reported?.columns, 139, "onReady carries ghostty's ACTUAL grid, not the seed")
        XCTAssertEqual(reported?.rows, 39)

        // Further resizes must not re-fire (one-shot).
        session.updateViewport(metrics(cols: 58, rows: 21, wPx: 992, hPx: 792))
        session.updateViewport(metrics(cols: 139, rows: 39, wPx: 2372, hPx: 1472))
        XCTAssertEqual(fireCount, 1, "barrier is one-shot")
    }

    /// If ghostty already reported the canonical grid BEFORE the barrier is armed (the callback
    /// beat `handleSurfaceAttach`), arming must fire immediately — never wait for the timeout.
    func testFiresImmediatelyIfAlreadyCanonical() {
        let session = makeSession()
        session.updateViewport(metrics(cols: 139, rows: 39, wPx: 2372, hPx: 1472))
        var fireCount = 0
        var reported: InMemoryTerminalViewport?
        session.awaitCanonicalGrid(widthPx: 2380, heightPx: 1480, tolerancePx: 80, timeout: 5) {
            fireCount += 1; reported = $0
        }
        XCTAssertEqual(fireCount, 1, "already-canonical grid must fire on arm, synchronously")
        XCTAssertEqual(reported?.columns, 139)
    }

    /// Bounded fail-open: if the canonical grid never arrives, the barrier fires after `timeout`
    /// so the attach can never hang. The fallback grid is whatever was last seen (nil if none).
    func testFailOpenTimeoutFires() {
        let session = makeSession()
        let fired = expectation(description: "barrier fires via timeout fail-open")
        session.awaitCanonicalGrid(widthPx: 2380, heightPx: 1480, tolerancePx: 80, timeout: 0.2) { vp in
            // Last-seen narrow grid is handed back; the caller converges to canonical anyway.
            XCTAssertEqual(vp?.columns, 46)
            fired.fulfill()
        }
        session.updateViewport(metrics(cols: 46, rows: 16, wPx: 782, hPx: 592))  // never matches
        wait(for: [fired], timeout: 2.0)
    }
}
