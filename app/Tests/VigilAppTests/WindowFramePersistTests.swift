import XCTest
import AppKit
@testable import VigilApp

// The save/restore round-trip through UserDefaults + NSStringFromRect is plain AppKit
// (resize → quit → relaunch reopens at the saved frame), but the *reachability* guard is
// pure and must never strand the window off-screen when a display goes away, so it is
// pinned here.
final class WindowFramePersistTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1800, height: 1130)

    /// A frame still on a live screen is returned untouched (position preserved).
    func testOnScreenFrameKeptAsIs() {
        let desired = NSRect(x: 200, y: 160, width: 1240, height: 780)
        XCTAssertEqual(WindowConfigurator.clampedFrame(desired, visibles: [screen], fallback: screen),
                       desired)
    }

    /// A frame on a now-unplugged external display is clamped back onto the fallback
    /// screen — fully contained, so the user can still grab it.
    func testFullyOffScreenClampedBack() {
        let desired = NSRect(x: 5000, y: 4000, width: 1240, height: 780)
        let out = WindowConfigurator.clampedFrame(desired, visibles: [screen], fallback: screen)
        XCTAssertGreaterThanOrEqual(out.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(out.minY, screen.minY)
        XCTAssertLessThanOrEqual(out.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(out.maxY, screen.maxY)
    }

    /// An off-screen frame *larger* than the fallback screen is both capped to fit and
    /// pulled fully on-screen (the rescue path caps size before clamping origin). An
    /// oversized frame that's still on-screen is deliberately left alone — a window
    /// bigger than its display is valid and the user's / AppKit's business, not a
    /// stranding case.
    func testOversizedOffScreenCappedToFallback() {
        let desired = NSRect(x: 5000, y: 4000, width: 3000, height: 2000)
        let out = WindowConfigurator.clampedFrame(desired, visibles: [screen], fallback: screen)
        XCTAssertLessThanOrEqual(out.width, screen.width)
        XCTAssertLessThanOrEqual(out.height, screen.height)
        XCTAssertGreaterThanOrEqual(out.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(out.minY, screen.minY)
        XCTAssertLessThanOrEqual(out.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(out.maxY, screen.maxY)
    }

    /// A frame on a still-connected second display is left where it is (multi-monitor
    /// users keep their placement).
    func testSecondDisplayFrameKept() {
        let ext = NSRect(x: 1800, y: 0, width: 2560, height: 1440)
        let desired = NSRect(x: 2000, y: 200, width: 1200, height: 800)
        XCTAssertEqual(WindowConfigurator.clampedFrame(desired, visibles: [screen, ext], fallback: screen),
                       desired)
    }
}
