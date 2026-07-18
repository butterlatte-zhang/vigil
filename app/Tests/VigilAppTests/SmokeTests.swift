import XCTest
import SwiftUI
import ViewInspector      // T1b dependency resolves & links
import SnapshotTesting    // T1c dependency resolves & links
@testable import VigilApp
@testable import VigilCore

// Smoke test: proves the VigilAppTests target can @testable-import the VigilApp
// executable target, instantiate real views, and drive ViewInspector over them.
// T1b wiring tests and T1c snapshots live in their own test files.

@MainActor
final class VigilAppSmokeTests: XCTestCase {

    /// @testable import VigilApp works and a view over real app state instantiates.
    func testInstantiateRootView() {
        let app = AppModel()
        let root = RootView(app: app)
        XCTAssertNotNil(root.body)
    }

    /// ViewInspector traverses a VigilApp view and finds real content by identifier.
    func testViewInspectorFindsAccessibilityIdentifier() throws {
        let app = AppModel()
        let empty = NoProjectView(app: app)
        let button = try empty.inspect()
            .find(viewWithAccessibilityIdentifier: "center.empty.addProject")
        XCTAssertNoThrow(try button.button())
    }
}
