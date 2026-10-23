import AppKit
import SwiftUI

// A hosting view owns SwiftUI's hit-testing policy. Its drawing-only native
// siblings cannot be independently interpreted as interactive overlays.
private protocol SwiftUIHitTestOwner {}
extension NSHostingView: SwiftUIHitTestOwner {}

/// Row content is display-only; the row owns selection, paste and inspector actions.
/// Keep wheel events on the normal responder chain so the enclosing scroll view still scrolls.
class ClipboardRowHitView: NSView {
    private var hasBelongedToWindow = false
    var interactionEnabled = true {
        didSet {
            if oldValue && !interactionEnabled { rowInteractionWasDisabled() }
        }
    }
    func rowInteractionWasDisabled() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { hasBelongedToWindow = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hosted content may extend beyond the row; never claim a neighbouring row.
        guard bounds.contains(convert(point, from: superview)),
              super.hitTest(point) != nil else { return nil }
        return self
    }
    /// Validate the re-hit-test against visible native geometry before forwarding.
    /// A hosting tree can briefly report an old row during layout/scroll updates.
    func redirectLeftClickIfNeeded(_ event: NSEvent) -> Bool {
        // The first event after reopening can retain an old view. Its window is
        // not authoritative: use the event's actual window for coordinates.
        guard let eventWindow = event.window ?? window,
              let root = eventWindow.contentView else { return hasBelongedToWindow || !interactionEnabled }
        root.layoutSubtreeIfNeeded()
        let point = root.superview.map { $0.convert(event.locationInWindow, from: nil) }
            ?? event.locationInWindow
        var hit = root.hitTest(point)
        while let view = hit, !(view is ClipboardRowHitView) { hit = view.superview }
        // A control, inspector or blank surface must not click through to a row.
        guard let candidate = hit as? ClipboardRowHitView else { return true }

        let target: ClipboardRowHitView?
        if candidate.containsVisibleLocation(of: event) {
            target = candidate
        } else if containsVisibleLocation(of: event) {
            // Native delivery was correct but the hosting re-hit-test was stale.
            target = self
        } else {
            // Both retained recipients are stale. Resolve only within this list,
            // using visible row rectangles rather than retrying the same hit test.
            let scope: NSView
            if let list = enclosingScrollView, list.window === eventWindow {
                scope = list
            } else if let list = candidate.enclosingScrollView, list.window === eventWindow {
                scope = list
            } else {
                scope = root
            }
            target = Self.visibleRow(in: scope, for: event)
        }
        guard let target, !target.isCoveredByForegroundSibling(in: root, event: event) else { return true }
        guard target !== self else { return false }
        target.mouseDown(with: event)
        return true
    }

    /// Bypassing a stale hosting hit-test must not bypass a real foreground view.
    /// Walk each native branch above the row without dispatching another click.
    private func isCoveredByForegroundSibling(in root: NSView, event: NSEvent) -> Bool {
        if root is SwiftUIHitTestOwner { return false }
        var branch: NSView = self
        while branch !== root, let parent = branch.superview {
            guard let index = parent.subviews.firstIndex(where: { $0 === branch }) else { return true }
            let point = parent.convert(event.locationInWindow, from: nil)
            for sibling in parent.subviews.dropFirst(index + 1).reversed() {
                guard !sibling.isHiddenOrHasHiddenAncestor, sibling.alphaValue > 0,
                      let hit = sibling.hitTest(point),
                      hit === sibling || hit.isDescendant(of: sibling),
                      hit.window === window, !hit.isHiddenOrHasHiddenAncestor, hit.alphaValue > 0 else { continue }
                let location = hit.convert(event.locationInWindow, from: nil)
                if hit.bounds.contains(location), hit.visibleRect.contains(location) { return true }
            }
            branch = parent
        }
        // A detached/reparented target is no longer a valid recovery destination.
        return branch !== root
    }

    private func containsVisibleLocation(of event: NSEvent) -> Bool {
        guard let window, event.windowNumber == window.windowNumber,
              interactionEnabled, !isHiddenOrHasHiddenAncestor, alphaValue > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), visibleRect.contains(point) else { return false }
        if let clip = enclosingScrollView?.contentView {
            // Prepared/overdraw views may still report a nonempty visibleRect.
            // Reject the portion physically clipped by the scrolling viewport.
            return clip.bounds.contains(clip.convert(event.locationInWindow, from: nil))
        }
        return true
    }

    private static func visibleRow(in view: NSView, for event: NSEvent) -> ClipboardRowHitView? {
        guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return nil }
        if let row = view as? ClipboardRowHitView {
            return row.containsVisibleLocation(of: event) ? row : nil
        }
        for child in view.subviews.reversed() {
            if let row = visibleRow(in: child, for: event) { return row }
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
