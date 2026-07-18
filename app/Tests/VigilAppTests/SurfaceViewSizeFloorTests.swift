import XCTest
@testable import VigilGhosttyTerminal

// Guards the node terminal against rendering one column wide: during a SwiftUI/AppKit
// view-hierarchy diff, setFrameSize/layout can fire fitToSize → synchronizeMetrics on a
// ~1pt intermediate frame. ghostty's setSize collapses the grid to 1 column on that
// sub-cell size, and the stale surface.size() dedup gate then swallows the resize, so the
// PTY stays at the real width while the screen renders 1 col. TerminalSurfaceCoordinator.
// isUsableViewSize floors the view size: a sub-cell frame is rejected before it can reach
// setSize, and a stable layout() re-syncs at the real bounds a tick later.
//
// XCTest boundary (same as GhosttyBackendTests): no ghostty surface exists in a
// unit-test process, so we pin the pure predicate exhaustively and the coordinator's
// hasValidViewSize gate (which fronts both rebuildIfReady and the sync path) across a
// collapse→settle transition.
@MainActor
final class SurfaceViewSizeFloorTests: XCTestCase {

    // 80px floor per dimension (assumedMaxCellPixels 40 * minUsableCells 2).
    private let floorPixels = TerminalSurfaceCoordinator.assumedMaxCellPixels
        * TerminalSurfaceCoordinator.minUsableCells

    // MARK: - Pure predicate

    func testOneColumnWideTransientIsNotUsable() {
        // The pathological 1pt-wide layout-diff frame that collapses the grid.
        XCTAssertFalse(
            TerminalSurfaceCoordinator.isUsableViewSize(width: 1, height: 400, scale: 2)
        )
    }

    func testOneRowTallTransientIsNotUsable() {
        XCTAssertFalse(
            TerminalSurfaceCoordinator.isUsableViewSize(width: 800, height: 1, scale: 2)
        )
    }

    func testNormalTerminalSizeIsUsable() {
        XCTAssertTrue(
            TerminalSurfaceCoordinator.isUsableViewSize(width: 800, height: 600, scale: 2)
        )
    }

    func testBoundaryAtFloorIsUsable() {
        // Exactly the floor in points (floorPixels / scale) must pass.
        let edgePoints = floorPixels / 2
        XCTAssertTrue(
            TerminalSurfaceCoordinator.isUsableViewSize(
                width: edgePoints, height: edgePoints, scale: 2
            )
        )
    }

    func testJustBelowFloorIsNotUsable() {
        let edgePoints = floorPixels / 2
        XCTAssertFalse(
            TerminalSurfaceCoordinator.isUsableViewSize(
                width: edgePoints - 0.5, height: edgePoints, scale: 2
            )
        )
    }

    func testFloorScalesWithBackingScale() {
        // At 1x the same point size straddles the floor differently — the predicate
        // works in device pixels, not points, so a 60pt pane is usable at 2x but not 1x.
        XCTAssertTrue(TerminalSurfaceCoordinator.isUsableViewSize(width: 60, height: 60, scale: 2))
        XCTAssertFalse(TerminalSurfaceCoordinator.isUsableViewSize(width: 60, height: 60, scale: 1))
    }

    func testDegenerateInputsAreNotUsable() {
        XCTAssertFalse(TerminalSurfaceCoordinator.isUsableViewSize(width: 0, height: 600, scale: 2))
        XCTAssertFalse(TerminalSurfaceCoordinator.isUsableViewSize(width: 800, height: 0, scale: 2))
        XCTAssertFalse(TerminalSurfaceCoordinator.isUsableViewSize(width: 800, height: 600, scale: 0))
        XCTAssertFalse(TerminalSurfaceCoordinator.isUsableViewSize(width: -800, height: 600, scale: 2))
        XCTAssertFalse(
            TerminalSurfaceCoordinator.isUsableViewSize(width: .nan, height: 600, scale: 2)
        )
        XCTAssertFalse(
            TerminalSurfaceCoordinator.isUsableViewSize(width: .infinity, height: 600, scale: 2)
        )
    }

    // MARK: - Coordinator gate (collapse → settle, no seesaw)

    func testCoordinatorRejectsThenAcceptsAcrossLayoutSettle() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.scaleFactor = { 2.0 }

        // Frame 1: the transient collapse mid-diff — the gate that fronts
        // rebuildIfReady/synchronizeMetrics must reject it.
        var size: (width: Double, height: Double) = (1, 400)
        coordinator.viewSize = { size }
        XCTAssertFalse(
            coordinator.hasValidViewSize,
            "sub-cell transient view size must not pass the metrics gate"
        )

        // Frame 2: layout settles at the real bounds — the same coordinator now accepts.
        size = (800, 600)
        XCTAssertTrue(
            coordinator.hasValidViewSize,
            "settled real bounds must re-open the metrics gate"
        )
    }

    func testSynchronizeMetricsOnTransientDoesNotResize() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.scaleFactor = { 2.0 }
        coordinator.viewSize = { (1, 400) }
        let spy = ResizeSpy()
        coordinator.delegate = spy

        // Must be a safe no-op: neither the resize delegate nor lastMetrics moves.
        coordinator.synchronizeMetrics()

        XCTAssertEqual(spy.gridResizeCount, 0)
        XCTAssertEqual(spy.legacyResizeCount, 0)
    }
}

@MainActor
private final class ResizeSpy: TerminalSurfaceGridResizeDelegate, TerminalSurfaceResizeDelegate {
    var gridResizeCount = 0
    var legacyResizeCount = 0

    func terminalDidResize(_: TerminalGridMetrics) { gridResizeCount += 1 }
    func terminalDidResize(columns _: Int, rows _: Int) { legacyResizeCount += 1 }
}
