import Foundation
import Sparkle

// Sparkle 2 auto-update integration. Two structural guards gate the WHOLE subsystem off —
// this is a hard product red line, not a preference: the machine building this feature is
// running a dev `swift run Vigil` process right now, and that must stay update-immune forever
// (no Sparkle instantiation, no network request, no UI) regardless of what else changes here.

/// Two independent guards, each unit-testable on its own (see UpdateAvailabilityTests).
public enum UpdateAvailability {
    /// Layer 1 — unit tests run in-process inside the XCTest host. Sparkle must never be
    /// instantiated there. Same guard idiom as `GhosttyViewBackend.startOnMain`
    /// (GhosttyBackend.swift): `XCTestConfigurationFilePath` is only ever set in the
    /// environment of a process XCTest itself launched.
    public static func isRunningUnderXCTest(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env["XCTestConfigurationFilePath"] != nil
    }

    /// Layer 2 — dev-immunity. `swift run Vigil` produces a BARE executable, no `.app` on
    /// disk; Package.swift links a partial Info.plist straight into the Mach-O
    /// `__TEXT,__info_plist` section purely so the App menu reads "Vigil" instead of the raw
    /// executable name, which means `Bundle.main.bundleIdentifier` reports "dev.vigil.Vigil"
    /// even under a bare dev run — identifier/name checks cannot distinguish dev from
    /// packaged. The one signal that's true ONLY for a real, double-clickable `.app` bundle
    /// is the bundle path's own extension.
    public static func isPackagedApp(bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension.lowercased() == "app"
    }

    /// Both layers must clear before the update subsystem may exist at all — called once,
    /// at AppModel construction, to decide which `UpdateChecking` implementation to build.
    public static func updatesEnabled(
        bundle: Bundle = .main,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !isRunningUnderXCTest(env: env) && isPackagedApp(bundle: bundle)
    }
}

/// Decouples AppModel from Sparkle the same way `CellHandle` decouples the orchestration core
/// from a real PTY (VigilCore §2.4) — production wires `SparkleUpdateController`, dev/test
/// builds wire `NullUpdateController`, and AppModel never has to know which.
@MainActor
public protocol UpdateChecking: AnyObject {
    /// Turns on Sparkle's own automatic scheduling (launch + periodic, default 24h interval)
    /// and starts the updater. A no-op until this is called — construction alone must never
    /// touch the network.
    func startPeriodicChecking()
    /// The single "run the standard Sparkle update UI flow" action shared by every user click
    /// (sidebar pill, Settings "Check for Updates", Settings "Update Now") — Sparkle shows its
    /// native progress/found-update/install UI once initiated this way, which the product
    /// decision accepts as the click-through experience.
    func checkForUpdates()
}

/// Dev/test stand-in: every call is inert, no Sparkle type is ever touched.
@MainActor
public final class NullUpdateController: UpdateChecking {
    public init() {}
    public func startPeriodicChecking() {}
    public func checkForUpdates() {}
}

/// Real Sparkle 2 wiring. Background/periodic checks stay silent (no alert, no user-facing
/// UI) — `SPUStandardUserDriverDelegate`'s "gentle reminders" hook
/// (`standardUserDriverShouldHandleShowingScheduledUpdate`) suppresses the standard driver's
/// own popup for scheduled checks; `onUpdateAvailable` is how the app learns a new version
/// exists so it can render its own sidebar pill / Settings row instead. That suppression does
/// NOT apply to a user-initiated `checkForUpdates()` call — Sparkle always shows its standard
/// progress/install UI for those, per product decision.
@MainActor
public final class SparkleUpdateController: NSObject, UpdateChecking {
    private var controller: SPUStandardUpdaterController!
    private let onUpdateAvailable: (String) -> Void
    private let onNoUpdateAvailable: () -> Void

    public init(onUpdateAvailable: @escaping (String) -> Void,
                onNoUpdateAvailable: @escaping () -> Void = {}) {
        self.onUpdateAvailable = onUpdateAvailable
        self.onNoUpdateAvailable = onNoUpdateAvailable
        super.init()
        // Not started here (startingUpdater: false) — construction must stay side-effect
        // free; startPeriodicChecking() is the explicit "go" called from bootstrap.
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                    updaterDelegate: self,
                                                    userDriverDelegate: self)
    }

    public func startPeriodicChecking() {
        controller.updater.automaticallyChecksForUpdates = true
        controller.startUpdater()
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
extension SparkleUpdateController: SPUUpdaterDelegate {
    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onUpdateAvailable(item.displayVersionString)
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onNoUpdateAvailable()
    }
}

extension SparkleUpdateController: SPUStandardUserDriverDelegate {
    // Both members are pure constants (no actor-isolated state touched), so `nonisolated`
    // satisfies the protocol's own nonisolated requirement without a hop.
    public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Product decision: background/periodic checks never pop Sparkle's own alert — only a
        // user click runs the standard UI flow (checkForUpdates() above).
        false
    }
}
