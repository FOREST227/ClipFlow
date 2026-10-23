import AppKit

/// Row content is display-only; the row owns selection, paste and inspector actions.
/// Keep wheel events on the normal responder chain so the enclosing scroll view still scrolls.
class ClipboardRowHitView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hosted content may extend beyond the row; never claim a neighbouring row.
        guard bounds.contains(convert(point, from: superview)),
              super.hitTest(point) != nil else { return nil }
        return self
    }
    /// AppKit can retain the original recipient during a multi-click sequence.
    /// Resolve the current pointer target rather than trusting that recipient.
    func redirectLeftClickIfNeeded(_ event: NSEvent) -> Bool {
        guard let root = window?.contentView else { return false }
        let point = root.superview.map { $0.convert(event.locationInWindow, from: nil) }
            ?? event.locationInWindow
        var target = root.hitTest(point)
        while let view = target, !(view is ClipboardRowHitView) {
            target = view.superview
        }
        guard target !== self else { return false }
        (target as? ClipboardRowHitView)?.mouseDown(with: event)
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
