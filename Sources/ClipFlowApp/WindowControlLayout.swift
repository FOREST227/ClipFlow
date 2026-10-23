import AppKit

extension MainWindowController {
    func windowDidResize(_ notification: Notification) { scheduleWindowControlLayout() }
    func windowDidExitFullScreen(_ notification: Notification) { scheduleWindowControlLayout() }
    func windowDidBecomeKey(_ notification: Notification) { scheduleWindowControlLayout() }

    private func scheduleWindowControlLayout() {
        positionWindowControls()
        DispatchQueue.main.async { [weak self] in self?.positionWindowControls() }
    }

    /// Keep native actions and hover behavior while positioning the traffic lights in the sidebar.
    func positionWindowControls() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let height: CGFloat = 48
        let oldTop = container.frame.maxY
        container.frame = NSRect(x: container.frame.minX, y: oldTop - height,
                                 width: container.frame.width, height: height)
        titlebar.frame = NSRect(x: titlebar.frame.minX, y: 0,
                                width: titlebar.frame.width, height: height)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 26 + CGFloat(index) * 20 - button.frame.width / 2,
                y: height - 26 - button.frame.height / 2))
        }
    }
}
