import AppKit
import SwiftUI

/// A local, window-scoped monitor also receives Escape when WebKit owns focus.
struct InspectorEscapeHandler: NSViewRepresentable {
    let onEscape: () -> Bool
    func makeNSView(context: Context) -> InspectorEscapeView {
        let view = InspectorEscapeView()
        view.onEscape = onEscape
        return view
    }
    func updateNSView(_ view: InspectorEscapeView, context: Context) { view.onEscape = onEscape }
    static func dismantleNSView(_ view: InspectorEscapeView, coordinator: ()) { view.stop() }
}

final class InspectorEscapeView: NSView {
    var onEscape: () -> Bool = { false }
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEscape(event) == true ? nil : event
        }
    }
    @discardableResult
    func handleEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              let window, window.isVisible, event.windowNumber == window.windowNumber else { return false }
        return onEscape()
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
