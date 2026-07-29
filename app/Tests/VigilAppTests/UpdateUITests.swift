import XCTest
import SwiftUI
import ViewInspector
@testable import VigilApp
@testable import VigilCore
@testable import VigilRuntime

// Sparkle integration, app-level slice: AppModel's plain @Observable update state (mirrors
// `toast`), the sidebar pill (Search-row-adjacent, zero footprint with no known update), and
// the Settings "About & Update" panel (AppBody.center, settingsProject.id branch). The
// dev-immunity / XCTest guards themselves are VigilRuntimeTests (UpdateAvailabilityTests) —
// this file only covers what AppModel/SwiftUI do with an already-decided UpdateChecking.

@MainActor
final class FakeUpdateController: UpdateChecking {
    private(set) var startPeriodicCheckingCallCount = 0
    private(set) var checkForUpdatesCallCount = 0
    func startPeriodicChecking() { startPeriodicCheckingCallCount += 1 }
    func checkForUpdates() { checkForUpdatesCallCount += 1 }
}

@MainActor
final class UpdateUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("VIGIL_UITEST", "1", 1)
        setenv("VIGIL_FAKE_AGENT_CMD", WiringTests.stubScript, 1)
    }

    private var apps: [AppModel] = []

    override func tearDown() {
        for app in apps { for s in app.allSessions { s.shutdown() } }
        apps.removeAll()
        super.tearDown()
    }

    private func makeApp(updateController: UpdateChecking? = nil) -> (AppModel, FakeUpdateController) {
        let fake = FakeUpdateController()
        let app = AppModel(updateController: updateController ?? fake)
        apps.append(app)
        return (app, fake)
    }

    private func assertPresent(_ view: some View, _ id: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: id),
                         "expected view with id \(id)", file: file, line: line)
    }

    private func assertAbsent(_ view: some View, _ id: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try view.inspect().find(viewWithAccessibilityIdentifier: id),
                             "expected NO view with id \(id)", file: file, line: line)
    }

    private func tapButton(_ view: some View, _ id: String) throws {
        try view.inspect()
            .find(ViewType.Button.self, where: { (try? $0.accessibilityIdentifier()) == id })
            .tap()
    }

    // MARK: - AppModel.appVersion

    func testAppVersionStringFallsBackToDevWhenKeyMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateUITests-\(UUID().uuidString)").appendingPathExtension("app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        XCTAssertEqual(AppModel.appVersionString(bundle: bundle), "dev")
    }

    // MARK: - AppModel.checkForUpdates()

    func testCheckForUpdatesDelegatesToController() {
        let (app, fake) = makeApp()
        XCTAssertEqual(fake.checkForUpdatesCallCount, 0)
        app.checkForUpdates()
        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
        app.checkForUpdates()
        XCTAssertEqual(fake.checkForUpdatesCallCount, 2)
    }

    // MARK: - bootstrapIfNeeded must not fire real checks under the UITest seam

    func testBootstrapDoesNotStartPeriodicCheckingUnderUITestSeam() {
        let (app, fake) = makeApp()
        app.bootstrapIfNeeded()
        XCTAssertEqual(fake.startPeriodicCheckingCallCount, 0,
                       "T2 XCUITest drives a real packaged .app under VIGIL_UITEST=1 — " +
                       "periodic update checks must stay off there too")
    }

    // MARK: - sidebar pill: zero footprint with no update, pill + label + click with one

    func testSidebarHasNoUpdatePillByDefault() {
        let (app, _) = makeApp()
        assertAbsent(SidebarView(app: app), "side.updateAvailable")
    }

    func testSidebarShowsUpdatePillWhenVersionKnown() {
        let (app, _) = makeApp()
        app.updateAvailableVersion = "9.9.9"
        assertPresent(SidebarView(app: app), "side.updateAvailable")
    }

    func testSidebarUpdatePillClickRunsCheckForUpdates() throws {
        let (app, fake) = makeApp()
        app.updateAvailableVersion = "9.9.9"
        // Generic ViewType.Button traversal (tapButton's usual path) aborts on SidebarView's
        // NSViewRepresentable siblings (PaneResizeHandle/TitlebarDragSurface); the identifier
        // search reaches the button fine and taps directly.
        try SidebarView(app: app).inspect().find(viewWithAccessibilityIdentifier: "side.updateAvailable")
            .button().tap()
        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
    }

    // MARK: - Settings About & Update panel

    func testAboutPanelShowsVersionAndCheckForUpdatesWhenNoUpdateKnown() {
        let (app, _) = makeApp()
        let panel = AboutUpdatePanel(app: app)
        assertPresent(panel, "settings.about.version")
        assertPresent(panel, "settings.about.checkForUpdates")
        assertAbsent(panel, "settings.about.updateNow")
    }

    func testAboutPanelSwapsToUpdateNowWhenVersionKnown() {
        let (app, _) = makeApp()
        app.updateAvailableVersion = "9.9.9"
        let panel = AboutUpdatePanel(app: app)
        assertPresent(panel, "settings.about.updateNow")
        assertAbsent(panel, "settings.about.checkForUpdates")
    }

    func testAboutPanelButtonsRunCheckForUpdates() throws {
        let (app, fake) = makeApp()
        try tapButton(AboutUpdatePanel(app: app), "settings.about.checkForUpdates")
        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)

        app.updateAvailableVersion = "9.9.9"
        try tapButton(AboutUpdatePanel(app: app), "settings.about.updateNow")
        XCTAssertEqual(fake.checkForUpdatesCallCount, 2)
    }

    // MARK: - AppBody mounts the panel only for the Settings project

    func testAppBodyMountsAboutPanelOnlyForSettingsProject() {
        let (app, _) = makeApp()
        app.openLauncher(in: app.settingsProject.id)
        assertPresent(AppBody(app: app), "settings.about.panel")
    }

    func testAppBodyDoesNotMountAboutPanelForAnOrdinaryProject() {
        let (app, _) = makeApp()
        let dir = NSTemporaryDirectory() + "vigil-about-proj-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = ProjectVM(id: UUID().uuidString, name: "Demo", cwd: dir)
        app.projects.append(p)
        app.openLauncher(in: p.id)
        assertAbsent(AppBody(app: app), "settings.about.panel")
    }
}
