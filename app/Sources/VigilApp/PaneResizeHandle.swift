import SwiftUI
import AppKit

/// Shared AppKit-backed resize grab strip for edge-anchored panes: the sidebar's trailing
/// edge (drives width) and the bottom terminal panel's top edge (drives height). AppKit
/// rather than a SwiftUI DragGesture for two reasons: an NSView can refuse to be a
/// window-drag surface (`mouseDownCanMoveWindow = false`), so resizing keeps working no
/// matter the window's drag policy — a SwiftUI clear shape can lose the drag to a window
/// move — and cursor rects give the proper resize cursor without hover bookkeeping.
///
/// Drag math is absolute: the value at mouseDown is captured once and the new value tracks
/// the pointer exactly (start + pointer delta), so there is no accumulated rounding. The
/// sign convention assumes the pane is anchored at the window's left (horizontal) or
/// bottom (vertical) edge: dragging right / up grows the pane.
struct PaneResizeHandle: NSViewRepresentable {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let valueAtStart: () -> CGFloat
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.configure(axis: axis, valueAtStart: valueAtStart, onChange: onChange, onEnd: onEnd)
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) {
        v.configure(axis: axis, valueAtStart: valueAtStart, onChange: onChange, onEnd: onEnd)
    }

    final class HandleView: NSView {
        private var axis: Axis = .horizontal
        private var valueAtStart: (() -> CGFloat)?
        private var onChange: ((CGFloat) -> Void)?
        private var onEnd: (() -> Void)?
        private var startValue: CGFloat = 0
        private var startPos: CGFloat = 0

        func configure(axis: Axis,
                       valueAtStart: @escaping () -> CGFloat,
                       onChange: @escaping (CGFloat) -> Void,
                       onEnd: @escaping () -> Void) {
            self.axis = axis
            self.valueAtStart = valueAtStart; self.onChange = onChange; self.onEnd = onEnd
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }

        /// Pointer position along the drag axis, in window coordinates (y-up).
        private func position(_ event: NSEvent) -> CGFloat {
            axis == .horizontal ? event.locationInWindow.x : event.locationInWindow.y
        }

        override func mouseDown(with event: NSEvent) {
            startValue = valueAtStart?() ?? 0
            startPos = position(event)
        }
        override func mouseDragged(with event: NSEvent) {
            onChange?(startValue + (position(event) - startPos))
        }
        override func mouseUp(with event: NSEvent) {
            onEnd?()
        }
    }
}
