import AppKit
import QuartzCore

/// Crossfades native and SwiftUI content together without rebuilding the pages.
@MainActor
final class AppearanceTransition {
    private var appliedMode: ClipFlowAppearance?
    private var snapshots: [AppearanceSnapshotView] = []
    private var generation = UUID()

    static func needsCrossfade(from current: NSAppearance, to target: NSAppearance) -> Bool {
        let schemes: [NSAppearance.Name] = [.aqua, .darkAqua]
        return current.bestMatch(from: schemes) != target.bestMatch(from: schemes)
    }

    func apply(_ mode: ClipFlowAppearance) {
        guard mode != appliedMode else { return }
        let previousAppearance = NSApp.effectiveAppearance
        let shouldAnimate = appliedMode != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        appliedMode = mode
        generation = UUID()
        let currentGeneration = generation

        // Freeze an interrupted fade at its current opacity before capturing it.
        // This avoids exposing the previous target appearance during rapid clicks.
        for snapshot in snapshots {
            let opacity = snapshot.layer?.presentation()?.opacity ?? Float(snapshot.alphaValue)
            snapshot.layer?.removeAllAnimations()
            snapshot.alphaValue = CGFloat(opacity)
        }

        var nextSnapshots: [(NSView, AppearanceSnapshotView)] = []
        if shouldAnimate {
            for window in NSApp.windows where window.isVisible && !window.isMiniaturized {
                // Skip status-item and other system-managed windows.
                guard window.contentViewController != nil || window is QuickPastePanel,
                      let content = window.contentView,
                      !content.bounds.isEmpty,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let image = NSImage(size: content.bounds.size)
                image.addRepresentation(bitmap)
                let snapshot = AppearanceSnapshotView(frame: content.bounds)
                snapshot.image = image
                snapshot.imageScaling = .scaleAxesIndependently
                snapshot.autoresizingMask = [.width, .height]
                snapshot.wantsLayer = true
                snapshot.setAccessibilityElement(false)
                nextSnapshots.append((content, snapshot))
            }
        }

        snapshots.forEach { $0.removeFromSuperview() }
        snapshots = nextSnapshots.map(\.1)
        for (content, snapshot) in nextSnapshots {
            content.addSubview(snapshot, positioned: .above, relativeTo: nil)
        }

        NSApp.appearance = mode.appKitAppearance
        // Resolve after applying nil for System so we compare the actual system
        // color, not the enum case or a stale saved macOS preference.
        guard Self.needsCrossfade(from: previousAppearance, to: NSApp.effectiveAppearance) else {
            snapshots.forEach { $0.removeFromSuperview() }
            snapshots.removeAll()
            return
        }
        guard !snapshots.isEmpty else { return }

        // Give hosting views and popover appearance observers one run-loop turn
        // to redraw underneath the unchanged old frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            let fadingSnapshots = self.snapshots
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ClipFlowMotion.appearanceDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for snapshot in fadingSnapshots {
                    snapshot.animator().alphaValue = 0
                }
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    fadingSnapshots.forEach { $0.removeFromSuperview() }
                    if self?.generation == currentGeneration {
                        self?.snapshots.removeAll()
                    }
                }
            }
        }
    }
}

/// The visual overlay never intercepts clicks or keyboard focus.
private final class AppearanceSnapshotView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
