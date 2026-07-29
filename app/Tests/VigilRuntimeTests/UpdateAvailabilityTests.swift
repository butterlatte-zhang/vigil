import XCTest
import Foundation
@testable import VigilRuntime

// Dev-immunity is a hard product red line: the machine developing this feature runs a dev
// `swift run Vigil` process, and the whole Sparkle subsystem must stay inert there forever.
// Two INDEPENDENT guards compose it — each pinned on its own so a future refactor can't
// silently drop one half while the combinator still looks green.
final class UpdateAvailabilityTests: XCTestCase {

    // MARK: layer 1 — XCTest host process

    func testIsRunningUnderXCTestTrueWhenEnvKeySet() {
        XCTAssertTrue(UpdateAvailability.isRunningUnderXCTest(
            env: ["XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"]))
    }

    func testIsRunningUnderXCTestFalseWhenEnvKeyAbsent() {
        XCTAssertFalse(UpdateAvailability.isRunningUnderXCTest(env: [:]))
    }

    // MARK: layer 2 — packaged .app vs bare `swift run` executable

    func testIsPackagedAppTrueForDotAppBundlePath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateAvailabilityTests-\(UUID().uuidString)")
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertTrue(UpdateAvailability.isPackagedApp(bundle: bundle))
    }

    func testIsPackagedAppFalseForBareExecutableDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateAvailabilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertFalse(UpdateAvailability.isPackagedApp(bundle: bundle))
    }

    // The real Bundle.main during `swift test` is never a `.app` — pins the default argument
    // against the same "identifier lies, path doesn't" trap the doc comment describes.
    func testDefaultBundleIsNotPackagedUnderSwiftTest() {
        XCTAssertFalse(UpdateAvailability.isPackagedApp())
    }

    // MARK: combinator — both layers must clear

    func testUpdatesEnabledFalseUnderXCTestEvenIfPackaged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateAvailabilityTests-\(UUID().uuidString)")
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertFalse(UpdateAvailability.updatesEnabled(
            bundle: bundle, env: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    func testUpdatesEnabledFalseWhenNotPackagedEvenOutsideXCTest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateAvailabilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertFalse(UpdateAvailability.updatesEnabled(bundle: bundle, env: [:]))
    }

    func testUpdatesEnabledTrueOnlyWhenBothLayersClear() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateAvailabilityTests-\(UUID().uuidString)")
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertTrue(UpdateAvailability.updatesEnabled(bundle: bundle, env: [:]))
    }
}

// MARK: - NullUpdateController: every call must be inert (dev/test stand-in)

@MainActor
final class NullUpdateControllerTests: XCTestCase {
    func testCallsAreInertAndDoNotCrash() {
        let controller = NullUpdateController()
        controller.startPeriodicChecking()
        controller.checkForUpdates()
        // No assertion beyond "did not crash / touch Sparkle" — the whole point of this type
        // is that it does nothing observable.
    }
}
