import SwiftUI

enum ClipFlowMotion {
    /// The only spring. Reserved for the permission overlay; visible transitions use `fade`.
    static let overlay = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.92, blendDuration: 0.06)
    static let tabSelection = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)
    static let pageSwitch = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
    static let pageExit = Animation.easeOut(duration: 0.12)
    static let rowSelection = Animation.easeOut(duration: 0.18)
    static let selection = Animation.easeOut(duration: 0.14)
    static let press = Animation.easeOut(duration: 0.10)
    static let fade = Animation.easeOut(duration: 0.16)
    static let inspectorOpen: TimeInterval = 0.28
    static let inspectorClose: TimeInterval = 0.20
    static let inspectorReduced: TimeInterval = 0.11
    /// One press scale for every control. Reduce Motion skips the scale.
    static let pressScale: CGFloat = 0.98

    @MainActor
    static var overlayTransition: AnyTransition {
        .opacity
    }

    static let clipboardPollInterval: TimeInterval = 0.24
    static let clipboardPollTolerance: TimeInterval = 0.04
    /// Idle history is swept on this cadence. A clipboard change purges immediately.
    static let clipboardPurgeInterval: TimeInterval = 30
    static let pasteActivationDelay: TimeInterval = 0.16
    static let relaunchDelay: TimeInterval = 0.18
    static let doubleClickDelay: TimeInterval = 0.18
    static let appearanceDuration: TimeInterval = 0.28

    static let backgroundDefocusRadius: CGFloat = 1.4
}
