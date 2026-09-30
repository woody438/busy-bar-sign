import AppKit

/// A transparent layer over the bar that takes its clicks. A double-click
/// toggles Do Not Disturb; on the floating window, a drag moves the window.
///
/// Both windows are non-activating panels, so clicking here never takes
/// focus from the app you're in — a call included.
final class BarSurface: NSView {
    var draggable = false
    var onDoubleClick: (@MainActor () -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if draggable {
            window?.performDrag(with: event)
        }
    }

    /// The first click on an inactive window counts too, rather than just
    /// bringing it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
