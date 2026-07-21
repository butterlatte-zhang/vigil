import XCTest
import AppKit
@testable import VigilApp

// T1 for the window chrome policy. The app window is .hiddenTitleBar +
// .fullSizeContentView, so AppKit's "movable by window background" flag would turn
// every blank SwiftUI region into a window-drag surface — stealing drags from the
// sidebar / bottom-terminal resize handles and making random panes move the whole
// window. Window dragging is provided explicitly by TitlebarDragSurface on the
// top-bar rows, so the window itself must refuse background drags.
@MainActor
final class WindowChromeTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                 backing: .buffered, defer: true)
    }

    /// The regression this file exists for: background drags must be off.
    func testWindowNotMovableByBackground() {
        let w = makeWindow()
        WindowConfigurator.configureChrome(w)
        XCTAssertFalse(w.isMovableByWindowBackground)
    }

    /// The rest of the chrome policy, pinned so extracting configureChrome can't
    /// silently drop a piece of it.
    func testChromeHidesNativeTitlebar() {
        let w = makeWindow()
        WindowConfigurator.configureChrome(w)
        XCTAssertEqual(w.titleVisibility, .hidden)
        XCTAssertTrue(w.titlebarAppearsTransparent)
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(w.standardWindowButton(.closeButton)?.isHidden, true)
        XCTAssertEqual(w.standardWindowButton(.miniaturizeButton)?.isHidden, true)
        XCTAssertEqual(w.standardWindowButton(.zoomButton)?.isHidden, true)
    }
}
