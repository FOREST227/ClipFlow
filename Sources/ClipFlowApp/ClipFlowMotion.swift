import CoreVideo
import Foundation
import SwiftUI

/// VSync-synchronized display frame driver backed by `CVDisplayLink` (macOS 12+ compatible).
/// Coalesces ticks so frames never pile up on the main queue, eliminating Timer/VSync phase drift
/// and micro-stutter on both 60Hz and 120Hz ProMotion displays.
@MainActor
final class DisplayLinkDriver {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false
        private var active = true

        func trySchedule() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard active, !pending else { return false }
            pending = true
            return true
        }

        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pending = false
            return active
        }

        func invalidate() {
            lock.lock()
            active = false
            pending = false
            lock.unlock()
        }
    }

    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?
    private var gate: Gate?
    private var onFrame: (() -> Void)?

    var isRunning: Bool {
        displayLink != nil || fallbackTimer != nil
    }

    func start(_ handler: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        self.onFrame = handler
        let gate = Gate()
        self.gate = gate

        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link {
            let status = CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                guard gate.trySchedule() else { return kCVReturnSuccess }
                DispatchQueue.main.async {
                    guard gate.consume() else { return }
                    MainActor.assumeIsolated {
                        self?.onFrame?()
                    }
                }
                return kCVReturnSuccess
            }
            if status == kCVReturnSuccess, CVDisplayLinkStart(link) == kCVReturnSuccess {
                self.displayLink = link
                return
            }
        }

        // Fallback for headless test environments without an active CGDisplay.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onFrame?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.fallbackTimer = timer
    }

    func stop() {
        gate?.invalidate()
        gate = nil
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        onFrame = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}

enum ClipFlowMotion {
    /// Calm, restrained critically-damped springs (no playful overshoot).
    static let overlay = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.94, blendDuration: 0.06)
    static let deckFlip = Animation.spring(response: 0.26, dampingFraction: 0.92, blendDuration: 0.04)
    static let pinBounce = Animation.spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.02)
    static let tabSelection = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static let pageSwitch = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
    static let pageExit = Animation.easeOut(duration: 0.12)
    static let rowSelection = Animation.easeOut(duration: 0.16)
    static let selection = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
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
