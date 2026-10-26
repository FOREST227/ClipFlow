import AppKit
import SwiftUI

/// A local, window-scoped monitor also receives Escape when WebKit owns focus.
struct InspectorEscapeHandler: NSViewRepresentable {
    let onEscape: () -> Bool
    var onWindowInactive: () -> Void = {}
    @Environment(\.isEnabled) private var scopeEnabled
    func makeNSView(context: Context) -> InspectorEscapeView {
        let view = InspectorEscapeView()
        view.onEscape = onEscape
        view.onWindowInactive = onWindowInactive
        view.scopeEnabled = scopeEnabled
        return view
    }
    func updateNSView(_ view: InspectorEscapeView, context: Context) {
        view.onEscape = onEscape
        view.onWindowInactive = onWindowInactive
        view.scopeEnabled = scopeEnabled
    }
    static func dismantleNSView(_ view: InspectorEscapeView, coordinator: ()) { view.stop() }
}

final class InspectorEscapeView: NSView {
    var onEscape: () -> Bool = { false }
    var onWindowInactive: () -> Void = {}
    var scopeEnabled = true
    private var monitor: Any?
    private var lifecycleObservers: [NSObjectProtocol] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.window === window else { return }
                        self.onWindowInactive()
                    }
                })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEscape(event) == true ? nil : event
        }
    }
    @discardableResult
    func handleEscape(_ event: NSEvent) -> Bool {
        guard scopeEnabled, !isHiddenOrHasHiddenAncestor,
              event.type == .keyDown, event.keyCode == 53,
              let window, window.isVisible, event.windowNumber == window.windowNumber else { return false }
        return onEscape()
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
    }
}
