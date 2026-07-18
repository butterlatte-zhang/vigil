import XCTest
@testable import VigilApp

// T1 logic test for titlebar double-click handling: the app window is
// .hiddenTitleBar + .fullSizeContentView, so the native title bar that would
// normally receive double-click-to-zoom is gone. TitlebarDragSurface restores
// it, but the *action* must respect the user's System Settings choice
// (NSGlobalDomain "AppleActionOnDoubleClick") rather than hard-coding zoom.
// This test pins the preference-string → action mapping.
final class TitlebarDoubleClickTests: XCTestCase {

    func testMaximizeMapsToZoom() {
        XCTAssertEqual(titlebarDoubleClickAction(preference: "Maximize"), .zoom)
    }

    func testMinimizeMapsToMinimize() {
        XCTAssertEqual(titlebarDoubleClickAction(preference: "Minimize"), .minimize)
    }

    func testFillMapsToFill() {
        XCTAssertEqual(titlebarDoubleClickAction(preference: "Fill"), .fill)
    }

    func testNoneMapsToNone() {
        XCTAssertEqual(titlebarDoubleClickAction(preference: "None"), .none)
    }

    /// Key unset / unreadable → platform default is zoom.
    func testNilFallsBackToZoom() {
        XCTAssertEqual(titlebarDoubleClickAction(preference: nil), .zoom)
    }

    /// An unknown/future string must degrade to the default rather than crash
    /// or do nothing surprising.
    func testUnknownFallsBackToZoom() {
        XCTAssertEqual(titlebarDoubleClickAction(preference: "SomethingElse"), .zoom)
        XCTAssertEqual(titlebarDoubleClickAction(preference: ""), .zoom)
    }
}
