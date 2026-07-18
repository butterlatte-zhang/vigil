import XCTest
@testable import VigilGhosttyTerminal

/// A semi-deterministic guard for an invariant adjacent to a main↔io AB-BA deadlock class
/// of bug. The real deadlock can't be unit-tested (it needs a real ghostty surface +
/// `ghostty_surface_write_buffer` blocking). This pins down a deterministically
/// reproducible adjacent regression shape instead:
/// **dispatchResize (the resize-callback-reachable path) must not hold its lock across
/// the resizeHandler callback** — i.e. the class of change where lastResize gets moved
/// back from the standalone `resizeLock` into the surface `lock` and held across the
/// callback. NSLock is non-reentrant, so if resize dispatch still holds the lock while
/// the resizeHandler callback is running, a reentrant call into updateViewport from
/// inside resizeHandler self-deadlocks immediately; under the current structure
/// (standalone resizeLock, unlocked before invoking resizeHandler) it returns instantly.
/// Runs on a background thread; a 2s timeout is treated as a hang.
///
/// Honesty boundary: this test covers the "lock held
/// across the callback" sub-shape only — it does not reproduce the full AB-BA between a
/// blocked receive and the io thread's resize (that one needs a real surface). It is not
/// flaky and not a false green — reintroducing "lock held across the callback" turns it red.
final class InMemoryResizeReentrancyTests: XCTestCase {

    private func metrics(_ c: UInt16, _ r: UInt16) -> TerminalGridMetrics {
        TerminalGridMetrics(columns: c, rows: r,
                            widthPixels: UInt32(c) * 10, heightPixels: UInt32(r) * 10,
                            cellWidthPixels: 10, cellHeightPixels: 10)
    }

    func testResizeCallbackReentrancyDoesNotDeadlock() {
        let finished = expectation(description: "reentrant resize completes")
        final class Box { var s: InMemoryTerminalSession?; var reentered = false }
        let box = Box()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in
                // resizeHandler is invoked from inside dispatchResize — simulating one
                // reentrant nested layout pass. Reenter only once (with a different
                // geometry, to avoid being short-circuited by the merged==last early
                // return), to avoid infinite recursion.
                guard !box.reentered else { return }
                box.reentered = true
                box.s?.updateViewport(self.metrics(100, 40))
            })
        box.s = session
        DispatchQueue.global().async {
            session.updateViewport(self.metrics(80, 24))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2.0)
        XCTAssertTrue(box.reentered, "resizeHandler must call back at least once (the reentrancy path really was exercised)")
    }

    /// Under concurrency, resize dispatch and the surface-lock methods
    /// (currentSurface/setSurface) must not deadlock against each other. If lastResize
    /// were moved back onto the same `lock`, this particular test would NOT deadlock (no
    /// lock held across a call) — it's a liveness net for regressions, complementary to
    /// the "lock held across the callback" sub-shape in the test above. Everything must
    /// finish within 2s.
    func testConcurrentResizeAndSurfaceAccessStayLive() {
        let done = expectation(description: "concurrent churn completes")
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let group = DispatchGroup()
        for i in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for j in 0..<200 {
                    session.updateViewport(self.metrics(UInt16(80 + (i + j) % 40),
                                                        UInt16(24 + (i + j) % 20)))
                    _ = session.currentSurface
                    session.setSurface(nil)
                }
            }
        }
        group.notify(queue: .global()) { done.fulfill() }
        wait(for: [done], timeout: 2.0)
    }
}
