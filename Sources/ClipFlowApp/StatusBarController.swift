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
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(store: store)
        )
        updatePopoverSize()
    }

    /// The panel has no fixed height; follow what its content needs.
    private func updatePopoverSize() {
        guard let view = popover.contentViewController?.view else { return }
        let height = view.fittingSize.height
        guard height > 0 else { return }
        popover.contentSize = NSSize(width: ClipFlowLayout.menuWidth, height: ceil(height))
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
            updatePopoverSize()
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

enum ClipFlowStatusBarIcon {
    /// Renders the 18×18pt monochrome macOS template icon matching the Ceramic Archival Card Box:
    /// two stepped archival cards rising from a rounded card-box pocket with a concave center thumb notch.
    static func make(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let strokeWidth: CGFloat = 1.45
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(strokeWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            if paused {
                // Clip out the bottom-right corner badge zone so the pause bars read with crisp separation.
                ctx.saveGState()
                let clipPath = CGMutablePath()
                clipPath.addRect(CGRect(x: 0, y: 0, width: 18, height: 18))
                clipPath.addRoundedRect(in: CGRect(x: 11.4, y: 10.0, width: 6.6, height: 8.0), cornerWidth: 1.8, cornerHeight: 1.8)
                ctx.addPath(clipPath)
                ctx.clip(using: .evenOdd)
            }

            // 1. Rear peeking card top arch (y: 2.1 -> 4.6, x: 5.0 ... 13.0)
            let rearCard = CGMutablePath()
            rearCard.move(to: CGPoint(x: 5.0, y: 4.5))
            rearCard.addLine(to: CGPoint(x: 5.0, y: 3.5))
            rearCard.addArc(tangent1End: CGPoint(x: 5.0, y: 2.1), tangent2End: CGPoint(x: 6.4, y: 2.1), radius: 1.4)
            rearCard.addLine(to: CGPoint(x: 11.6, y: 2.1))
            rearCard.addArc(tangent1End: CGPoint(x: 13.0, y: 2.1), tangent2End: CGPoint(x: 13.0, y: 3.5), radius: 1.4)
            rearCard.addLine(to: CGPoint(x: 13.0, y: 4.5))
            ctx.addPath(rearCard)
            ctx.strokePath()

            // 2. Front hero card rising from pocket (y: 4.6 -> 9.8, x: 3.3 ... 14.7)
            let frontCard = CGMutablePath()
            frontCard.move(to: CGPoint(x: 3.3, y: 9.8))
            frontCard.addLine(to: CGPoint(x: 3.3, y: 6.2))
            frontCard.addArc(tangent1End: CGPoint(x: 3.3, y: 4.6), tangent2End: CGPoint(x: 4.9, y: 4.6), radius: 1.6)
            frontCard.addLine(to: CGPoint(x: 13.1, y: 4.6))
            frontCard.addArc(tangent1End: CGPoint(x: 14.7, y: 4.6), tangent2End: CGPoint(x: 14.7, y: 6.2), radius: 1.6)
            frontCard.addLine(to: CGPoint(x: 14.7, y: 9.8))
            ctx.addPath(frontCard)
            ctx.strokePath()

            // Subtle header pill accent inside the front card
            let headerLine = CGMutablePath()
            headerLine.move(to: CGPoint(x: 5.6, y: 7.1))
            headerLine.addLine(to: CGPoint(x: 9.6, y: 7.1))
            ctx.addPath(headerLine)
            ctx.strokePath()

            // 3. Archival box front pocket with concave center thumb notch (y: 9.8 ... 15.8, x: 1.9 ... 16.1)
            let pocket = CGMutablePath()
            pocket.move(to: CGPoint(x: 1.9, y: 10.6))
            pocket.addArc(tangent1End: CGPoint(x: 1.9, y: 9.8), tangent2End: CGPoint(x: 2.7, y: 9.8), radius: 0.8)
            pocket.addLine(to: CGPoint(x: 6.4, y: 9.8))
            pocket.addCurve(
                to: CGPoint(x: 9.0, y: 11.35),
                control1: CGPoint(x: 7.25, y: 9.8),
                control2: CGPoint(x: 7.85, y: 11.35)
            )
            pocket.addCurve(
                to: CGPoint(x: 11.6, y: 9.8),
                control1: CGPoint(x: 10.15, y: 11.35),
                control2: CGPoint(x: 10.75, y: 9.8)
            )
            pocket.addLine(to: CGPoint(x: 15.3, y: 9.8))
            pocket.addArc(tangent1End: CGPoint(x: 16.1, y: 9.8), tangent2End: CGPoint(x: 16.1, y: 10.6), radius: 0.8)
            pocket.addLine(to: CGPoint(x: 16.1, y: 13.0))
            pocket.addArc(tangent1End: CGPoint(x: 16.1, y: 15.8), tangent2End: CGPoint(x: 13.3, y: 15.8), radius: 2.8)
            pocket.addLine(to: CGPoint(x: 4.7, y: 15.8))
            pocket.addArc(tangent1End: CGPoint(x: 1.9, y: 15.8), tangent2End: CGPoint(x: 1.9, y: 13.0), radius: 2.8)
            pocket.closeSubpath()

            // Soft translucent glaze inside the pocket + crisp SF-Symbol-weight outline
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.addPath(pocket)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.addPath(pocket)
            ctx.strokePath()

            if paused {
                ctx.restoreGState()
                for x: CGFloat in [12.9, 15.3] {
                    ctx.addPath(CGPath(
                        roundedRect: CGRect(x: x, y: 11.3, width: 1.45, height: 4.8),
                        cornerWidth: 0.72,
                        cornerHeight: 0.72,
                        transform: nil
                    ))
                }
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "剪流：监听已暂停" : "剪流：正在监听"
        return image
    }
}
