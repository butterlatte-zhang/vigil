import XCTest
import AppKit
import VigilGhosttyTerminal

// The app window is .hiddenTitleBar, so AppKit lets any view with mouseDownCanMoveWindow
// == true drag the whole window. NSView derives the default from isOpaque, and the ghostty
// terminal view is a non-opaque CAMetalLayer view — without an explicit override, selection
// drags on the terminal body move the window instead. TerminalHost.Container only shields
// the padding around the terminal; hits on the body resolve against AppTerminalView itself,
// so the override must live on the vendored view.
@MainActor
final class TerminalDragTests: XCTestCase {

    /// Safe to instantiate directly: commonInit is lazy — no ghostty surface exists
    /// until the view is attached to a window.
    func testTerminalBodyDoesNotDragWindow() {
        let view = AppTerminalView(frame: .zero)
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "non-opaque terminal view must opt out of window dragging (issue #2)"
        )
    }
}
