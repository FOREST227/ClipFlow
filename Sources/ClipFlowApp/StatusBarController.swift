import AppKit
import Combine
import SwiftUI

@MainActor
final class AppNavigationCenter {
    static let shared = AppNavigationCenter()

    var openLibraryWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var dismissMenuBarPopover: (() -> Void)?

    private init() {}

    func openLibrary() {
        dismissMenuBarPopover?()
        ClipFlowRuntime.shared.openLibrary()
    }

    func openSettings() {
        dismissMenuBarPopover?()
        openSettingsWindow?()
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: ClipFlowStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var pendingPopoverPresentation: Task<Void, Never>?

    init(store: ClipFlowStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
        AppNavigationCenter.shared.dismissMenuBarPopover = { [weak self] in
            self?.dismissPopover()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.appearsDisabled = false
        button.toolTip = "ClipFlow 剪流"
        button.setAccessibilityLabel("打开剪流菜单")
        updateButtonImage()
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: ClipFlowLayout.menuWidth, height: ClipFlowLayout.menuHeight)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(store: store)
        )
    }

    private func bindStore() {
        // Popovers have their own appearance default. Track the resolved app
        // appearance so both manual choices and system changes reach this host.
        NSApp.publisher(for: \.effectiveAppearance, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance in
                self?.popover.appearance = appearance
            }
            .store(in: &cancellables)

        store.$capturePaused
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateButtonImage()
            }
            .store(in: &cancellables)
    }

    private func updateButtonImage() {
        guard let button = statusItem.button else { return }

        button.image = ClipFlowStatusBarIcon.make(paused: store.capturePaused)
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        pendingPopoverPresentation?.cancel()
        pendingPopoverPresentation = nil
        if popover.isShown {
            dismissPopover()
        } else {
            showPopover()
        }
    }

    func showPopover(waitForMenuBarLayout: Bool = false) {
        pendingPopoverPresentation?.cancel()
        pendingPopoverPresentation = nil
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard waitForMenuBarLayout, !popover.isShown else {
            presentPopover(at: button)
            return
        }

        // A newly created status item may still have an initial or moving frame.
        // Wait for a real, stable menu-bar anchor rather than positioning from it.
        pendingPopoverPresentation = Task { [weak self] in
            var previousRect: NSRect?
            for _ in 0..<20 {
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                guard let button = self.statusItem.button,
                      let window = button.window, let screen = window.screen else { continue }
                window.contentView?.layoutSubtreeIfNeeded()
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                let menuBarHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
                guard rect.width > 0, rect.height > 0,
                      rect.intersects(screen.frame),
                      rect.midY >= screen.frame.maxY - menuBarHeight - 8 else {
                    previousRect = nil
                    continue
                }
                if rect == previousRect {
                    self.pendingPopoverPresentation = nil
                    self.presentPopover(at: button)
                    return
                }
                previousRect = rect
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingPopoverPresentation = nil
            // An auto-hidden menu bar can keep its anchor outside the visible
            // screen. Let AppKit resolve that real status-button anchor rather
            // than silently dropping the launch request or guessing coordinates.
            if let button = self.statusItem.button, button.window != nil {
                self.presentPopover(at: button)
            }
        }
    }

    private func presentPopover(at button: NSStatusBarButton) {
        popover.appearance = NSApp.effectiveAppearance
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startPopoverEventMonitors()
        }
        popover.positioningRect = button.bounds
        popover.contentViewController?.view.window?.makeKey()
    }

    private func dismissPopover() {
        pendingPopoverPresentation?.cancel()
        pendingPopoverPresentation = nil
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverEventMonitors()
    }

    private func startPopoverEventMonitors() {
        stopPopoverEventMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.popover.isShown else { return event }

            if self.eventTargetsPopoverOrStatusButton(event) {
                return event
            }

            self.popover.performClose(nil)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            guard self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func stopPopoverEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func eventTargetsPopoverOrStatusButton(_ event: NSEvent) -> Bool {
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return true
        }

        if let button = statusItem.button,
           let buttonWindow = button.window,
           event.window === buttonWindow {
            let pointInButton = button.convert(event.locationInWindow, from: nil)
            return button.bounds.contains(pointInButton)
        }

        return false
    }
}

private enum ClipFlowStatusBarIcon {
    static func make(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAllowsAntialiasing(true)
            context.setFillColor(NSColor.black.cgColor)
            context.saveGState()
            // SVG coordinates are top-down; AppKit drawing coordinates are bottom-up.
            context.translateBy(x: -2.4, y: 21.16)
            context.scaleBy(x: 0.095, y: -0.095)
            context.addPath(flowPath())
            context.fillPath()
            context.restoreGState()
            if paused {
                for x: CGFloat in [13.3, 15.7] {
                    context.addPath(CGPath(roundedRect: CGRect(x: x, y: 2, width: 1.4, height: 4.5),
                        cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
                }
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "剪流：监听已暂停" : "剪流：正在监听"
        return image
    }

    /// Same filled outlines as assets/icon/ClipFlow-icon.svg, scaled for the menu bar.
    private static func flowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 64, y: 176))
        path.addCurve(to: CGPoint(x: 56, y: 168), control1: CGPoint(x: 59.5817, y: 176.0000), control2: CGPoint(x: 56.0000, y: 172.4183))
        path.addLine(to: CGPoint(x: 56, y: 104))
        path.addCurve(to: CGPoint(x: 104, y: 56), control1: CGPoint(x: 56.0000, y: 77.4903), control2: CGPoint(x: 77.4903, y: 56.0000))
        path.addLine(to: CGPoint(x: 176, y: 56))
        path.addCurve(to: CGPoint(x: 184, y: 64), control1: CGPoint(x: 180.4183, y: 56.0000), control2: CGPoint(x: 184.0000, y: 59.5817))
        path.addLine(to: CGPoint(x: 184, y: 72))
        path.addCurve(to: CGPoint(x: 176, y: 80), control1: CGPoint(x: 184.0000, y: 76.4183), control2: CGPoint(x: 180.4183, y: 80.0000))
        path.addLine(to: CGPoint(x: 104, y: 80))
        path.addCurve(to: CGPoint(x: 80, y: 104), control1: CGPoint(x: 90.7452, y: 80.0000), control2: CGPoint(x: 80.0000, y: 90.7452))
        path.addLine(to: CGPoint(x: 80, y: 168))
        path.addCurve(to: CGPoint(x: 72, y: 176), control1: CGPoint(x: 80.0000, y: 172.4183), control2: CGPoint(x: 76.4183, y: 176.0000))
        path.closeSubpath()
        path.move(to: CGPoint(x: 112, y: 200))
        path.addCurve(to: CGPoint(x: 104, y: 192), control1: CGPoint(x: 107.5817, y: 200.0000), control2: CGPoint(x: 104.0000, y: 196.4183))
        path.addLine(to: CGPoint(x: 104, y: 144))
        path.addCurve(to: CGPoint(x: 144, y: 104), control1: CGPoint(x: 104.0000, y: 121.9086), control2: CGPoint(x: 121.9086, y: 104.0000))
        path.addLine(to: CGPoint(x: 176, y: 104))
        path.addCurve(to: CGPoint(x: 184, y: 112), control1: CGPoint(x: 180.4183, y: 104.0000), control2: CGPoint(x: 184.0000, y: 107.5817))
        path.addLine(to: CGPoint(x: 184, y: 120))
        path.addCurve(to: CGPoint(x: 176, y: 128), control1: CGPoint(x: 184.0000, y: 124.4183), control2: CGPoint(x: 180.4183, y: 128.0000))
        path.addLine(to: CGPoint(x: 144, y: 128))
        path.addCurve(to: CGPoint(x: 128, y: 144), control1: CGPoint(x: 135.1634, y: 128.0000), control2: CGPoint(x: 128.0000, y: 135.1634))
        path.addLine(to: CGPoint(x: 128, y: 192))
        path.addCurve(to: CGPoint(x: 120, y: 200), control1: CGPoint(x: 128.0000, y: 196.4183), control2: CGPoint(x: 124.4183, y: 200.0000))
        path.closeSubpath()
        return path
    }
}
