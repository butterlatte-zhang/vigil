import XCTest
import AppKit
@testable import VigilApp

// T1 for the shared AppKit pane-resize handle (sidebar trailing edge = width,
// bottom terminal top edge = height). It must be AppKit-backed: a SwiftUI
// DragGesture on a clear shape can be treated as window background by AppKit and
// lose the drag to a window move (the exact bug that froze the bottom terminal's
// resize bar). The drag math is absolute — value tracks the pointer from the
// mouseDown anchor, no accumulated deltas.
@MainActor
final class PaneResizeHandleTests: XCTestCase {

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func makeHandle(axis: PaneResizeHandle.Axis,
                            startValue: CGFloat,
                            changes: @escaping (CGFloat) -> Void,
                            ended: @escaping () -> Void = {}) -> PaneResizeHandle.HandleView {
        let v = PaneResizeHandle.HandleView()
        v.configure(axis: axis, valueAtStart: { startValue },
                    onChange: changes, onEnd: ended)
        return v
    }

    /// The handle must never be a window-drag surface, regardless of the window's
    /// background-drag policy.
    func testRefusesWindowDrag() {
        XCTAssertFalse(PaneResizeHandle.HandleView().mouseDownCanMoveWindow)
    }

    /// Horizontal (sidebar, pane anchored left): dragging right grows the width,
    /// tracking the pointer exactly from the mouseDown anchor.
    func testHorizontalDragTracksPointer() {
        var seen: [CGFloat] = []
        let v = makeHandle(axis: .horizontal, startValue: 300) { seen.append($0) }
        v.mouseDown(with: mouse(.leftMouseDown, x: 500, y: 100))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 540, y: 100))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 480, y: 100))
        XCTAssertEqual(seen, [340, 280])
    }

    /// Vertical (bottom terminal, pane anchored bottom): window coords are y-up, so
    /// dragging the top-edge handle up grows the height.
    func testVerticalDragUpGrowsHeight() {
        var seen: [CGFloat] = []
        let v = makeHandle(axis: .vertical, startValue: 200) { seen.append($0) }
        v.mouseDown(with: mouse(.leftMouseDown, x: 100, y: 400))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 100, y: 460))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 100, y: 350))
        XCTAssertEqual(seen, [260, 150])
    }

    /// mouseUp fires onEnd (the persist hook) exactly once per drag.
    func testMouseUpFiresOnEnd() {
        var ends = 0
        let v = makeHandle(axis: .vertical, startValue: 200, changes: { _ in }) { ends += 1 }
        v.mouseDown(with: mouse(.leftMouseDown, x: 100, y: 400))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 100, y: 420))
        v.mouseUp(with: mouse(.leftMouseUp, x: 100, y: 420))
        XCTAssertEqual(ends, 1)
    }

    /// A fresh mouseDown re-anchors: the second drag's values are relative to the
    /// value at its own start, not the first drag's.
    func testSecondDragReanchors() {
        var current: CGFloat = 300
        var seen: [CGFloat] = []
        let v = PaneResizeHandle.HandleView()
        v.configure(axis: .horizontal, valueAtStart: { current },
                    onChange: { seen.append($0); current = $0 }, onEnd: {})
        v.mouseDown(with: mouse(.leftMouseDown, x: 500, y: 0))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 520, y: 0))
        v.mouseUp(with: mouse(.leftMouseUp, x: 520, y: 0))
        v.mouseDown(with: mouse(.leftMouseDown, x: 520, y: 0))
        v.mouseDragged(with: mouse(.leftMouseDragged, x: 510, y: 0))
        XCTAssertEqual(seen, [320, 310])
    }
}
