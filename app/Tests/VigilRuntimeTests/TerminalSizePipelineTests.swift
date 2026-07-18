import XCTest
@testable import VigilGhosttyTerminal

/// The settle gate's decision table (INV1/INV4). Pure and surface-free: the pipeline's
/// only side effect is `applySurfaceSize`, captured here into a spy, so grow-immediate /
/// shrink-debounce / supersede / no-pin can be pinned without a ghostty surface or a window
/// server. The end-to-end convergence (surface==PTY, transient suppressed) is covered by the
/// `vigil-winrepro` scenario matrix (Tier-2, manual).
@MainActor
final class TerminalSizePipelineTests: XCTestCase {

    private final class Spy { var applied: [(w: UInt32, h: UInt32)] = [] }

    private func makePipeline(canonical: CanonicalPaneSize = CanonicalPaneSize(),
                              debounce: TimeInterval = 0.05) -> (TerminalSizePipeline, Spy) {
        let spy = Spy()
        let p = TerminalSizePipeline(canonical: canonical, debounceSeconds: debounce,
                                     applySurfaceSize: { w, h in spy.applied.append((w, h)) })
        return (p, spy)
    }

    /// First offer with no baseline bootstraps immediately (the manager cold-start: canonical
    /// empty, so the very first real view size becomes the surface size at once).
    func testFirstOfferBootstrapsImmediately() {
        let (p, spy) = makePipeline()
        p.offerLayout(pixelWidth: 1000, pixelHeight: 800)
        XCTAssertEqual(spy.applied.count, 1)
        XCTAssertEqual(spy.applied.first?.w, 1000)
        XCTAssertEqual(spy.applied.first?.h, 800)
    }

    /// seedAttachBaseline forces the freshly-built surface straight to canonical and seeds the
    /// baseline (INV2: the surface lands at the right size first).
    func testSeedAttachBaselineForcesCanonical() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 164, rows: 48, widthPx: 2788, heightPx: 1776)
        let (p, spy) = makePipeline(canonical: canonical)
        p.seedAttachBaseline()
        XCTAssertEqual(spy.applied.map { $0.w }, [2788])
        XCTAssertEqual(spy.applied.first?.h, 1776)
    }

    /// A grow-or-equal in both dims commits immediately (widen / open sidebar never lags, INV4).
    func testGrowCommitsImmediately() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 100, rows: 40, widthPx: 1000, heightPx: 800)
        let (p, spy) = makePipeline(canonical: canonical)
        p.seedAttachBaseline()                       // baseline 1000×800
        p.offerLayout(pixelWidth: 1400, pixelHeight: 900)
        XCTAssertEqual(spy.applied.last?.w, 1400, "grow applies at once")
        XCTAssertEqual(spy.applied.last?.h, 900)
    }

    /// A shrink in either dim is HELD — not applied synchronously (kills the transient attach /
    /// layout-burst narrow frame at the source, form ②/④).
    func testShrinkIsHeldNotImmediate() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 140, rows: 40, widthPx: 2800, heightPx: 1800)
        let (p, spy) = makePipeline(canonical: canonical)
        p.seedAttachBaseline()                       // baseline 2800×1800 (1 apply)
        let beforeCount = spy.applied.count
        p.offerLayout(pixelWidth: 1000, pixelHeight: 700)   // shrink
        XCTAssertEqual(spy.applied.count, beforeCount, "a shrink must not reach the surface synchronously")
    }

    /// A held shrink that is not superseded commits after the debounce — a genuine user
    /// drag-narrow lands one beat late (INV4), it is NOT pinned forever.
    func testStableShrinkCommitsOnceAfterDebounce() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 140, rows: 40, widthPx: 2800, heightPx: 1800)
        let (p, spy) = makePipeline(canonical: canonical, debounce: 0.05)
        p.seedAttachBaseline()
        let base = spy.applied.count
        p.offerLayout(pixelWidth: 1000, pixelHeight: 700)   // shrink
        p.offerLayout(pixelWidth: 1000, pixelHeight: 700)   // SAME shrink re-offered — must NOT reset timer
        let exp = expectation(description: "debounce fires once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(spy.applied.count, base + 1, "a stable narrow commits exactly once, not pinned, not spammed")
        XCTAssertEqual(spy.applied.last?.w, 1000)
    }

    /// Prevents form-④: a transient narrow frame (attach layout burst) held,
    /// then the settle frame returns to canonical. The held shrink is cancelled and the settle
    /// frame — being equal to the current size — is correctly deduped, so the surface NEVER
    /// leaves canonical: no reflow, ever. The narrow 1000×700 must never be applied.
    func testTransientShrinkSupersededBySettleNeverReflows() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 140, rows: 40, widthPx: 2800, heightPx: 1800)
        let (p, spy) = makePipeline(canonical: canonical, debounce: 0.05)
        p.seedAttachBaseline()                              // applies 2800×1800 (base = 1)
        let base = spy.applied.count
        p.offerLayout(pixelWidth: 1000, pixelHeight: 700)   // transient shrink (held)
        p.offerLayout(pixelWidth: 2800, pixelHeight: 1800)  // settle frame == canonical → dedup + cancel
        XCTAssertEqual(spy.applied.count, base, "settle equals canonical → deduped, surface unmoved")
        let exp = expectation(description: "held shrink was cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(spy.applied.count, base, "the superseded shrink must NEVER fire (no reflow)")
        XCTAssertFalse(spy.applied.contains { $0.w == 1000 }, "the transient narrow width was never applied")
    }

    /// A genuine grow ABOVE the current size within the shrink window supersedes the held shrink
    /// and applies immediately (widen never lags), and the shrink never fires.
    func testGrowAboveSupersedesHeldShrink() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 100, rows: 40, widthPx: 1600, heightPx: 1000)
        let (p, spy) = makePipeline(canonical: canonical, debounce: 0.05)
        p.seedAttachBaseline()                              // 1600×1000 (base = 1)
        let base = spy.applied.count
        p.offerLayout(pixelWidth: 1000, pixelHeight: 700)   // shrink (held)
        p.offerLayout(pixelWidth: 2800, pixelHeight: 1800)  // grow above → immediate
        XCTAssertEqual(spy.applied.count, base + 1)
        XCTAssertEqual(spy.applied.last?.w, 2800, "the larger settle frame applies at once")
        let exp = expectation(description: "held shrink cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(spy.applied.count, base + 1, "the superseded shrink must never fire")
        XCTAssertFalse(spy.applied.contains { $0.w == 1000 })
    }

    /// invalidate() drops a pending shrink (surface torn down before the timer fires).
    func testInvalidateCancelsPendingShrink() {
        let canonical = CanonicalPaneSize()
        canonical.update(cols: 140, rows: 40, widthPx: 2800, heightPx: 1800)
        let (p, spy) = makePipeline(canonical: canonical, debounce: 0.05)
        p.seedAttachBaseline()
        let base = spy.applied.count
        p.offerLayout(pixelWidth: 1000, pixelHeight: 700)
        p.invalidate()
        let exp = expectation(description: "no fire after invalidate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(spy.applied.count, base, "invalidate must cancel the held shrink")
    }
}
