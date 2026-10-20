import SwiftUI

enum ClipFlowMotion {
    static let overlay = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.92, blendDuration: 0.06)
    static let selection = Animation.easeOut(duration: 0.14)
    static let press = Animation.easeOut(duration: 0.10)
    static let fade = Animation.easeOut(duration: 0.16)

    @MainActor
    static var overlayTransition: AnyTransition {
        .scale(scale: 0.985).combined(with: .opacity)
    }

    static let clipboardPollInterval: TimeInterval = 0.24
    static let clipboardPollTolerance: TimeInterval = 0.04
    static let pasteActivationDelay: TimeInterval = 0.16
    static let relaunchDelay: TimeInterval = 0.18
    static let doubleClickDelay: TimeInterval = 0.18
    static let appearanceDuration: TimeInterval = 0.28

    static let backgroundDefocusRadius: CGFloat = 1.4
}
