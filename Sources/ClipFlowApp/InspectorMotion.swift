import AppKit
import SwiftUI

struct InspectorMotionPolicy: Equatable, Sendable {
    var reduceMotion: Bool
    var reduceTransparency: Bool
}
private struct InspectorMotionPolicyKey: EnvironmentKey {
    static let defaultValue: InspectorMotionPolicy? = nil
}
extension EnvironmentValues {
    // System accessibility keys are read-only. A nil override always follows macOS.
    var inspectorMotionPolicy: InspectorMotionPolicy? {
        get { self[InspectorMotionPolicyKey.self] }
        set { self[InspectorMotionPolicyKey.self] = newValue }
    }
}
struct InspectorMotionPreferences: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.inspectorMotionPolicy) private var override
    var reduceMotion: Bool { override?.reduceMotion ?? systemReduceMotion }
    var reduceTransparency: Bool { override?.reduceTransparency ?? systemReduceTransparency }
}

private final class InspectorTween: NSAnimation {
    var tick: ((CGFloat) -> Void)?
    override var currentProgress: NSAnimation.Progress {
        didSet { tick?(CGFloat(currentProgress)) }
    }
}

/// Non-threaded AppKit animation works back to macOS 12 and has a real end callback.
@MainActor
final class AppKitInspectorAnimationDriver: NSObject, InspectorAnimationDriving, NSAnimationDelegate {
    private var tween: InspectorTween?
    private var completion: (() -> Void)?
    private var revision: UInt64 = 0

    func animate(from: CGFloat, to: CGFloat, duration: TimeInterval,
                 update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        cancel()
        guard duration > 0 else { update(to); completion(); return }
        let token = revision
        let animation = InspectorTween(duration: duration, animationCurve: .linear)
        animation.animationBlockingMode = .nonblocking
        animation.frameRate = 60
        animation.delegate = self
        animation.tick = { [weak self] fraction in
            MainActor.assumeIsolated {
                guard let self, self.revision == token else { return }
                update(from + (to - from) * min(1, max(0, fraction)))
            }
        }
        self.completion = completion
        tween = animation
        animation.start()
    }

    func cancel() {
        revision &+= 1
        completion = nil
        let previous = tween
        tween = nil
        previous?.delegate = nil
        previous?.tick = nil
        previous?.stop()
    }

    nonisolated func animationDidEnd(_ animation: NSAnimation) {
        let identity = ObjectIdentifier(animation)
        MainActor.assumeIsolated {
            guard tween.map(ObjectIdentifier.init) == identity else { return }
            let action = completion
            completion = nil
            tween?.tick = nil
            tween?.delegate = nil
            tween = nil
            action?()
        }
    }
}

struct InspectorMotionValues: Equatable {
    let progress: CGFloat
    let shellScaleY: CGFloat
    let shellOffsetY: CGFloat
    let contentOpacity: CGFloat
    let contentOffsetY: CGFloat
    let chromeOpacity: CGFloat
    let backdropProgress: CGFloat
    let backgroundBlur: CGFloat

    static func resolve(progress: CGFloat, reduceMotion: Bool, reduceTransparency: Bool) -> Self {
        let p = min(1, max(0, progress.isFinite ? progress : 0))
        let eased = 1 - pow(1 - p, 4)
        let reveal = min(1, max(0, (p - 0.64) / 0.30))
        let content = reveal * reveal * (3 - 2 * reveal)
        return Self(progress: p, shellScaleY: 1,
            shellOffsetY: 0,
            contentOpacity: reduceMotion ? p : content,
            contentOffsetY: reduceMotion ? 0 : 8 * (1 - content),
            chromeOpacity: reduceMotion ? p : min(1, max(0, (p - 0.06) / 0.22)),
            backdropProgress: eased,
            backgroundBlur: reduceMotion || reduceTransparency ? 0 : ClipFlowMotion.backgroundDefocusRadius * eased)
    }
}

extension InspectorMotionProgress {
    static let settled = InspectorMotionProgress(value: 1)
}

struct InspectorMotionSurface<Content: View>: View {
    @ObservedObject var motion: InspectorMotionProgress
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let content: (InspectorMotionValues) -> Content

    var body: some View {
        content(.resolve(progress: motion.value, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
    }
}

/// Applying visual effects as a modifier keeps the list content out of the tick observer.
struct InspectorBackdropMotion: ViewModifier {
    @ObservedObject var motion: InspectorMotionProgress
    private var preferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { preferences.reduceMotion }
    private var reduceTransparency: Bool { preferences.reduceTransparency }

    init(motion: InspectorMotionProgress) {
        _motion = ObservedObject(wrappedValue: motion)
    }

    func body(content: Content) -> some View {
        let values = InspectorMotionValues.resolve(progress: motion.value,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        content.blur(radius: values.backgroundBlur)
            .opacity(1 - 0.60 * Double(values.backdropProgress))
    }
}

struct InspectorScrim: View {
    @ObservedObject var motion: InspectorMotionProgress
    let opacity: Double
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var preferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { preferences.reduceMotion }
    private var reduceTransparency: Bool { preferences.reduceTransparency }

    init(motion: InspectorMotionProgress, opacity: Double, onDismiss: @escaping () -> Void) {
        _motion = ObservedObject(wrappedValue: motion)
        self.opacity = opacity
        self.onDismiss = onDismiss
    }

    var body: some View {
        let values = InspectorMotionValues.resolve(progress: motion.value,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        (colorScheme == .dark ? Color.black : Color.white).opacity(opacity * Double(values.backdropProgress))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .accessibilityHidden(true)
    }
}
