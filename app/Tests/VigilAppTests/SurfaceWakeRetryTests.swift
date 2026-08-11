import AppKit
import XCTest
@testable import VigilGhosttyTerminal

// Wake-retry mitigation for upstream ghostty discussion #13248: while the display is
// asleep / the login session is locked, the WindowServer denies CVDisplayLink creation
// and `ghostty_surface_new` fails wholesale (tolerated upstream only since ghostty
// PR #13639, which no packaged libghostty release contains yet). Vigil's surface is
// display-only (the agent process is HostPTY-owned), so the damage is a blank pane —
// but the ONLY retry used to be the next layout pulse (`fitToSize`), which may never
// come on an idle pane. A failed surface build must therefore arm a one-shot retry on
// screens-wake / session-unlock, disarmed by success or teardown.
//
// XCTest boundary (same as SurfaceViewSizeFloorTests): no ghostty app exists in a
// unit-test process, so an app-less TerminalController makes `createSurface` return nil
// — the exact observable shape of the locked-session failure — driving the SAME
// `rebuildIfReady` failure path the mitigation hooks into. Notification centers are
// injected so no real NSWorkspace/distributed traffic reaches the test.
@MainActor
final class SurfaceWakeRetryTests: XCTestCase {
    private var attached = true

    private func makeFailingCoordinator(
        wake: NotificationCenter, unlock: NotificationCenter
    ) -> TerminalSurfaceCoordinator {
        let c = TerminalSurfaceCoordinator()
        c.wakeNotificationCenter = wake
        c.unlockNotificationCenter = unlock
        c.scaleFactor = { 2.0 }
        c.viewSize = { (800, 600) }
        c.isAttached = { [weak self] in self?.attached ?? false }
        // App-less controller: createSurface fails like a locked session. Setting the
        // controller fires the first rebuild attempt via its didSet.
        c.controller = TerminalController()
        return c
    }

    func testFailedSurfaceBuildArmsWakeRetry() {
        let c = makeFailingCoordinator(wake: .init(), unlock: .init())
        XCTAssertEqual(c.rebuildAttemptCount, 1, "controller didSet drives the first attempt")
        XCTAssertNil(c.surface)
        XCTAssertTrue(c.wakeRetryArmed, "a failed surface build must arm the wake retry")
    }

    func testScreensWakeRetriesAndRearmsWhileStillFailing() {
        let wake = NotificationCenter()
        let c = makeFailingCoordinator(wake: wake, unlock: .init())

        wake.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertEqual(c.rebuildAttemptCount, 2, "screens-wake must drive exactly one retry")
        XCTAssertTrue(c.wakeRetryArmed, "a retry that fails again must re-arm, not give up")
    }

    func testSessionUnlockAlsoRetries() {
        let unlock = NotificationCenter()
        let c = makeFailingCoordinator(wake: .init(), unlock: unlock)

        unlock.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        XCTAssertEqual(c.rebuildAttemptCount, 2, "session unlock must drive exactly one retry")
        XCTAssertTrue(c.wakeRetryArmed)
    }

    func testDetachedTeardownDisarmsAndLateWakeIsInert() {
        let wake = NotificationCenter()
        let c = makeFailingCoordinator(wake: wake, unlock: .init())
        XCTAssertTrue(c.wakeRetryArmed)

        // The view leaves the hierarchy: the rebuild pass tears down and must NOT
        // stay subscribed — a dead pane retrying on every wake forever is a leak.
        attached = false
        c.rebuildIfReady()
        XCTAssertEqual(c.rebuildAttemptCount, 2)
        XCTAssertFalse(c.wakeRetryArmed, "teardown while detached must disarm the retry")

        wake.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(c.rebuildAttemptCount, 2, "a disarmed coordinator must ignore late wakes")
    }
}
