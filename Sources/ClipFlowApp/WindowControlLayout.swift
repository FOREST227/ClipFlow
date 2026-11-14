import AppKit
import SwiftUI

/// Traffic lights sit in the band above the sidebar card, lined up with its padding.
enum WindowChrome {
    static let cardLeading: CGFloat = 12
    static let cardTop: CGFloat = 40
    static let cardBottom: CGFloat = 8
    static let cardPadding: CGFloat = 8
    static let buttonSpacing: CGFloat = 20
    /// Halfway down the clear band, so the buttons are not on the window edge or the card stroke.
    static var buttonCenterFromTop: CGFloat { cardTop / 2 }
    /// The close button's center lines up with the card's inner leading padding.
    static var firstButtonCenterX: CGFloat { cardLeading + cardPadding + 7 }
}

extension MainWindowController {
    func windowDidResize(_ notification: Notification) { scheduleWindowControlLayout() }
    func windowDidEnterFullScreen(_ notification: Notification) { controlsFollowSystem = true }
    func windowWillEnterFullScreen(_ notification: Notification) { controlsFollowSystem = true }
    func windowWillExitFullScreen(_ notification: Notification) { controlsFollowSystem = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        controlsFollowSystem = false
        scheduleWindowControlLayout()
        // The frame is still the fullscreen size when this fires. Place the buttons again after it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.positionWindowControls()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { scheduleWindowControlLayout() }

    func scheduleWindowControlLayout() {
        positionWindowControls()
        DispatchQueue.main.async { [weak self] in self?.positionWindowControls() }
    }

    /// Keep native actions and hover behavior while placing the traffic lights in the band above the sidebar.
    func positionWindowControls() {
        guard !isPositioningControls else { return }
        guard let window, !controlsFollowSystem, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, titlebar.superview != nil else { return }
        isPositioningControls = true
        defer { isPositioningControls = false }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            let center = NSPoint(
                x: WindowChrome.firstButtonCenterX + CGFloat(index) * WindowChrome.buttonSpacing,
                y: window.frame.height - WindowChrome.buttonCenterFromTop)
            let local = titlebar.convert(center, from: nil)
            let origin = NSPoint(x: local.x - button.frame.width / 2, y: local.y - button.frame.height / 2)
            guard titlebar.bounds.insetBy(dx: -2, dy: -2).contains(NSRect(origin: origin, size: button.frame.size)) else { continue }
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// Reapplies traffic-light placement whenever AppKit lays the window out again.
struct WindowChromeAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeLayout { WindowChromeLayout() }
    func updateNSView(_ view: WindowChromeLayout, context: Context) { view.needsLayout = true }
}

final class WindowChromeLayout: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        (window?.delegate as? MainWindowController)?.positionWindowControls()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window?.delegate as? MainWindowController)?.positionWindowControls()
    }
}
