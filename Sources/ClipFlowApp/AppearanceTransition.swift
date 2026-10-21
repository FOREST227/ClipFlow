import AppKit
import QuartzCore

/// Let Core Animation blend the existing rendered layers rather than synchronously
/// rasterizing whole SwiftUI windows on the input event thread.
@MainActor
final class AppearanceTransition {
    private var appliedMode: ClipFlowAppearance?
    // Core Animation stores CATransition under its reserved "transition" key.
    static let animationKey = "transition"

    static func needsCrossfade(from current: NSAppearance, to target: NSAppearance) -> Bool {
        let schemes: [NSAppearance.Name] = [.aqua, .darkAqua]
        return current.bestMatch(from: schemes) != target.bestMatch(from: schemes)
    }

    func apply(_ mode: ClipFlowAppearance) {
        guard mode != appliedMode else { return }
        let previousAppearance = NSApp.effectiveAppearance
        let shouldAnimate = appliedMode != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        appliedMode = mode

        let contents = NSApp.windows.compactMap { window -> NSView? in
            guard window.isVisible, !window.isMiniaturized,
                  window.contentViewController != nil || window is QuickPastePanel,
                  let content = window.contentView, !content.bounds.isEmpty else { return nil }
            return content
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for content in contents {
            content.layer?.removeAnimation(forKey: Self.animationKey)
            if shouldAnimate { content.wantsLayer = true }
        }

        NSApp.appearance = mode.appKitAppearance
        // Resolve System after clearing the override: equal actual colors never
        // animate, and do not require a throwaway bitmap capture to discover that.
        if shouldAnimate && Self.needsCrossfade(from: previousAppearance, to: NSApp.effectiveAppearance) {
            for content in contents {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = ClipFlowMotion.appearanceDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                content.layer?.add(fade, forKey: Self.animationKey)
            }
        }
        CATransaction.commit()
    }
}
