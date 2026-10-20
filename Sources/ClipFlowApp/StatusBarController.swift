import AppKit
import Combine
import CoreText
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
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            image.isTemplate = true
            return image
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(NSColor.black.cgColor)

        if let path = makeCPath(in: CGRect(origin: .zero, size: size), paused: paused) {
            context.addPath(path)
            context.fillPath()
        }

        if paused {
            drawPauseBars(in: context)
        }

        image.unlockFocus()
        image.isTemplate = true
        image.size = size
        return image
    }

    private static func makeCPath(in rect: CGRect, paused: Bool) -> CGPath? {
        guard let basePath = glyphPath() else { return nil }

        let targetWidth: CGFloat = paused ? 12.4 : 13.2
        let targetHeight: CGFloat = 13.8
        let bounds = basePath.boundingBox
        let scale = min(targetWidth / bounds.width, targetHeight / bounds.height)

        var transform = CGAffineTransform(scaleX: scale, y: scale)
        guard let scaledPath = basePath.copy(using: &transform) else { return nil }

        let scaledBounds = scaledPath.boundingBox
        let center = CGPoint(x: rect.midX - 0.15, y: rect.midY + 0.05)
        transform = CGAffineTransform(
            translationX: center.x - scaledBounds.midX - (paused ? 0.45 : 0.0),
            y: center.y - scaledBounds.midY
        )

        return scaledPath.copy(using: &transform)
    }

    private static func drawPauseBars(in context: CGContext) {
        let barColor = NSColor.black.cgColor
        let leftBar = CGPath(
            roundedRect: CGRect(x: 10.35, y: 5.0, width: 1.55, height: 7.9),
            cornerWidth: 0.78,
            cornerHeight: 0.78,
            transform: nil
        )
        let rightBar = CGPath(
            roundedRect: CGRect(x: 12.55, y: 5.0, width: 1.55, height: 7.9),
            cornerWidth: 0.78,
            cornerHeight: 0.78,
            transform: nil
        )

        context.saveGState()
        context.setFillColor(barColor)
        context.addPath(leftBar)
        context.addPath(rightBar)
        context.fillPath()
        context.restoreGState()
    }

    private static func glyphPath() -> CGPath? {
        let font = preferredFont(size: 17)
        let ctFont = font as CTFont

        guard let scalar = Character("C").unicodeScalars.first else { return nil }
        var character = UniChar(scalar.value)
        var glyph = CGGlyph()

        guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else {
            return nil
        }

        return CTFontCreatePathForGlyph(ctFont, glyph, nil)
    }

    private static func preferredFont(size: CGFloat) -> NSFont {
        let names = [
            "Avenir-Heavy",
            "AvenirNext-Heavy",
            "Avenir-Black"
        ]

        for name in names {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }

        return NSFont.systemFont(ofSize: size, weight: .heavy)
    }
}
