import AppKit
import SwiftUI

@MainActor
final class QuickPastePanelController: NSObject, NSWindowDelegate {
    private let store: ClipFlowStore
    private let onPaste: (ClipboardItem) -> Void
    private let onPastePlain: (ClipboardItem) -> Void
    private let onOpenLibrary: () -> Void
    private var panel: QuickPastePanel?
    private var inspector: InspectorPresentation?
    private var lastAnchorLocation: CGPoint = .zero

    init(store: ClipFlowStore, onPaste: @escaping (ClipboardItem) -> Void,
         onPastePlain: @escaping (ClipboardItem) -> Void = { _ in },
         onOpenLibrary: @escaping () -> Void) {
        self.store = store
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onOpenLibrary = onOpenLibrary
    }

    func toggle(anchorAt mouseLocation: CGPoint, preferredTarget: NSRunningApplication?) {
        if panel?.isVisible == true {
            hide()
        } else {
            show(anchorAt: mouseLocation, preferredTarget: preferredTarget)
        }
    }

    func show(anchorAt mouseLocation: CGPoint, preferredTarget: NSRunningApplication?) {
        inspector?.reset()
        lastAnchorLocation = mouseLocation
        store.prewarmQuickPasteAssets(limit: 24)
        let panel = makePanel(floatingCarousel: true)
        let inspector = InspectorPresentation(driver: AppKitInspectorAnimationDriver())
        self.inspector = inspector
        panel.onCancelInspector = { [weak inspector] in
            guard let inspector, inspector.blocksBackground else { return false }
            inspector.dismiss(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return true
        }
        panel.onCancelPanel = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(
            rootView: QuickPastePanelView(
                store: store,
                preferredTargetName: preferredTarget?.localizedName,
                onPaste: onPaste,
                onPastePlain: onPastePlain,
                onOpenLibrary: onOpenLibrary,
                onClose: { [weak self] in
                    self?.hide()
                },
                onPasteSnippet: { snippet in
                    ClipFlowRuntime.shared.pasteSnippet(snippet)
                },
                onPasteSnippetPlain: { snippet in
                    ClipFlowRuntime.shared.pasteSnippetPlain(snippet)
                },
                inspector: inspector,
                initialMode: .fan,
                onModeChanged: { [weak self] nextMode in
                    self?.reconfigurePanel(for: nextMode)
                }
            )
        )

        configureTransparentPanel(panel)
        position(panel: panel, near: mouseLocation, centeredOnCursor: true)
        let animateEntrance = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animateEntrance { panel.alphaValue = 0 }
        // Activate like the history window so SwiftUI receives full trackpad gestures.
        // Runtime retains lastExternalApp separately for the eventual paste.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if animateEntrance {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        inspector?.reset()
        inspector = nil
        guard let panel else { return }
        panel.onCancelInspector = nil
        panel.onCancelPanel = nil
        panel.delegate = nil
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    private func reconfigurePanel(for mode: QuickPastePresentationMode) {
        guard let panel else { return }
        let floating = mode == .fan
        let size = NSSize(
            width: floating ? QuickPastePanelLayout.floatingCarouselWidth : QuickPastePanelLayout.panelWidth,
            height: floating ? QuickPastePanelLayout.floatingCarouselHeight : QuickPastePanelLayout.panelHeight
        )
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.hasShadow = !floating
        panel.setContentSize(size)
        if floating {
            configureTransparentPanel(panel)
        } else {
            configurePanelMask(panel)
        }
        position(panel: panel, near: center, centeredOnCursor: true)
    }

    private func makePanel(floatingCarousel: Bool = false) -> QuickPastePanel {
        if let existing = panel {
            existing.delegate = nil
            existing.contentView = nil
            existing.orderOut(nil)
            existing.close()
            self.panel = nil
        }

        let width = floatingCarousel ? QuickPastePanelLayout.floatingCarouselWidth : QuickPastePanelLayout.panelWidth
        let height = floatingCarousel ? QuickPastePanelLayout.floatingCarouselHeight : QuickPastePanelLayout.panelHeight
        let panel = QuickPastePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !floatingCarousel
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? QuickPastePanel === panel else { return }
        hide()
    }

    private func configureTransparentPanel(_ panel: QuickPastePanel) {
        let views: [NSView] = [panel.contentView, panel.contentView?.superview].compactMap { $0 }
        for view in views {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = 0
            view.layer?.masksToBounds = false
        }
    }

    private func configurePanelMask(_ panel: QuickPastePanel) {
        let radius = QuickPastePanelLayout.cornerRadius
        let views: [NSView] = [panel.contentView, panel.contentView?.superview].compactMap { $0 }

        for view in views {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
            if #available(macOS 10.15, *) {
                view.layer?.cornerCurve = .continuous
            }
        }
    }

    private func position(panel: NSPanel, near mouseLocation: CGPoint, centeredOnCursor: Bool = false) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 120, y: 120, width: 1200, height: 800)
        let panelSize = panel.frame.size
        let inset = QuickPastePanelLayout.screenInset

        if centeredOnCursor {
            let centeredOrigin = CGPoint(
                x: mouseLocation.x - panelSize.width / 2,
                y: mouseLocation.y - panelSize.height / 2
            )
            let clamped = clamp(
                origin: centeredOrigin,
                panelSize: panelSize,
                to: visibleFrame.insetBy(dx: inset, dy: inset)
            )
            panel.setFrameOrigin(clamped)
            return
        }

        let offset = QuickPastePanelLayout.anchorOffset

        let candidateOrigins: [CGPoint] = [
            CGPoint(x: mouseLocation.x + offset, y: mouseLocation.y - panelSize.height - offset),
            CGPoint(x: mouseLocation.x - panelSize.width - offset, y: mouseLocation.y - panelSize.height - offset),
            CGPoint(x: mouseLocation.x + offset, y: mouseLocation.y + offset),
            CGPoint(x: mouseLocation.x - panelSize.width - offset, y: mouseLocation.y + offset)
        ]

        let bestOrigin = candidateOrigins.min { lhs, rhs in
            placementScore(for: lhs, panelSize: panelSize, mouseLocation: mouseLocation, visibleFrame: visibleFrame, inset: inset)
                < placementScore(for: rhs, panelSize: panelSize, mouseLocation: mouseLocation, visibleFrame: visibleFrame, inset: inset)
        } ?? candidateOrigins[0]

        let clampedOrigin = clamp(
            origin: bestOrigin,
            panelSize: panelSize,
            to: visibleFrame.insetBy(dx: inset, dy: inset)
        )

        panel.setFrameOrigin(clampedOrigin)
    }

    private func placementScore(
        for origin: CGPoint,
        panelSize: CGSize,
        mouseLocation: CGPoint,
        visibleFrame: CGRect,
        inset: CGFloat
    ) -> CGFloat {
        let safeFrame = visibleFrame.insetBy(dx: inset, dy: inset)
        let clampedOrigin = clamp(origin: origin, panelSize: panelSize, to: safeFrame)

        let overflowX = abs(origin.x - clampedOrigin.x)
        let overflowY = abs(origin.y - clampedOrigin.y)
        let overflowPenalty = (overflowX + overflowY) * 20

        let panelCenter = CGPoint(
            x: clampedOrigin.x + panelSize.width / 2,
            y: clampedOrigin.y + panelSize.height / 2
        )
        let distancePenalty = hypot(panelCenter.x - mouseLocation.x, panelCenter.y - mouseLocation.y)

        return overflowPenalty + distancePenalty
    }

    private func clamp(origin: CGPoint, panelSize: CGSize, to frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - panelSize.width)),
            y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - panelSize.height))
        )
    }
}
