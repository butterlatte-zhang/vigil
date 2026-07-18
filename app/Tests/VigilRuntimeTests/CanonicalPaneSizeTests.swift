import XCTest
@testable import VigilGhosttyTerminal

/// The canonical size authority's contract (latest-wins, degenerate-rejected, seed) and
/// the session's attach-gate resize SUPPRESSION (the fix that keeps ghostty's transient
/// build-time narrow grid from riding to the PTY during attach). The end-to-end fork
/// behavior is pinned by HostPTYTests.testResizeBeforeStartSeedsForkSize + the winrepro matrix.
final class CanonicalPaneSizeTests: XCTestCase {

    // MARK: CanonicalPaneSize contract

    func testEmptyHasNoSeed() {
        XCTAssertNil(CanonicalPaneSize().current,
                     "no commit yet → nil → cell forks at the 24×80 default (manager's own path)")
    }

    func testSeedInitializerIsReadable() {
        let c = CanonicalPaneSize(seed: CanonicalGrid(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100))
        XCTAssertEqual(c.current, CanonicalGrid(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100))
    }

    func testUpdateStoresLatestGrid() {
        let c = CanonicalPaneSize()
        c.update(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100)
        XCTAssertEqual(c.current?.cols, 196)
        XCTAssertEqual(c.current?.rows, 70)
        XCTAssertEqual(c.current?.widthPx, 1600)
        XCTAssertEqual(c.current?.heightPx, 1100)
    }

    func testLatestWins() {
        let c = CanonicalPaneSize()
        c.update(cols: 80, rows: 24, widthPx: 640, heightPx: 380)
        c.update(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100)
        XCTAssertEqual(c.current?.cols, 196, "a later settled commit supersedes an earlier one")
    }

    /// A sub-2-cell size is a degenerate layout-diff transient — it must never become the size a
    /// future cell is born at. It is dropped and a prior good value is kept.
    func testDegenerateSizeRejected() {
        let c = CanonicalPaneSize()
        c.update(cols: 196, rows: 70, widthPx: 1600, heightPx: 1100)
        c.update(cols: 1, rows: 70, widthPx: 8, heightPx: 1100)      // collapsed width
        c.update(cols: 196, rows: 1, widthPx: 1600, heightPx: 16)    // collapsed height
        XCTAssertEqual(c.current?.cols, 196, "degenerate updates must not poison the seed")
        XCTAssertEqual(c.current?.rows, 70)
    }

    func testDegenerateFirstUpdateLeavesEmpty() {
        let c = CanonicalPaneSize()
        c.update(cols: 0, rows: 0, widthPx: 0, heightPx: 0)
        XCTAssertNil(c.current, "a degenerate first commit is not a usable seed")
    }

    // MARK: Session attach-gate resize suppression (INV2)

    /// While the attach gate is open, ghostty's transient build-time resize callback must NOT
    /// reach the resize handler (→ PTY) — that transient narrow grid is exactly what would
    /// hard-wrap the child. Once the gate lifts, resizes flow normally.
    func testResizeSuppressedWhileAttaching() {
        final class Box { var grids: [(Int, Int)] = [] }
        let box = Box()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { vp in box.grids.append((Int(vp.columns), Int(vp.rows))) })

        session.beginAttachGate()
        XCTAssertTrue(session.isAttaching)
        session.updateViewport(TerminalGridMetrics(columns: 46, rows: 16,
                                                   widthPixels: 460, heightPixels: 160,
                                                   cellWidthPixels: 10, cellHeightPixels: 10))
        XCTAssertTrue(box.grids.isEmpty, "ghostty's transient build frame must be suppressed during attach")

        session.endAttachGate()
        XCTAssertFalse(session.isAttaching)
        session.updateViewport(TerminalGridMetrics(columns: 164, rows: 48,
                                                   widthPixels: 1640, heightPixels: 480,
                                                   cellWidthPixels: 10, cellHeightPixels: 10))
        XCTAssertEqual(box.grids.map { $0.0 }, [164], "after the gate lifts, the true grid reaches the PTY")
    }

    func testReceiveWithoutSurfaceOrDuringAttachHasNoDeliveryGeneration() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        XCTAssertNil(session.receive(Data("x".utf8)))
        XCTAssertNil(session.receive(Data()))

        session.beginAttachGate()
        XCTAssertNil(session.receive(Data("query".utf8)))
        session.endAttachGate()
    }
}
