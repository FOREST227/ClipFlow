import AppKit
import ApplicationServices

/// Reads Accessibility trust and, only when asked, shows the system prompt.
@MainActor
protocol AccessibilityTrustChecking: AnyObject {
    func isTrusted(prompt: Bool) -> Bool
}

/// System Accessibility trust, plus the Privacy & Security pane that grants it.
@MainActor
final class AccessibilityTrust: AccessibilityTrustChecking {
    static let system = AccessibilityTrust()

    private let check: @MainActor (Bool) -> Bool

    init(check: @MainActor @escaping (Bool) -> Bool = AccessibilityTrust.systemCheck) {
        self.check = check
    }

    func isTrusted(prompt: Bool) -> Bool {
        check(prompt)
    }

    /// `prompt` asks macOS to present the Accessibility alert. A silent check never does.
    static func systemCheck(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Privacy & Security → Accessibility, newest settings URL first.
    static func settingsURLs() -> [URL] {
        let candidates = if #available(macOS 13, *) {
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ]
        } else {
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ]
        }
        return candidates.compactMap { URL(string: $0) }
    }

    /// Opens System Settings (or System Preferences) at Privacy & Security → Accessibility.
    @discardableResult
    static func openSystemSettings(opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        for url in settingsURLs() where opener(url) {
            return true
        }
        return false
    }
}

/// Posts the synthetic Command-V used after a trusted auto-paste.
@MainActor
final class PasteShortcutSender {
    static func commit(_ target: NSRunningApplication?) {
        target?.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipFlowMotion.pasteActivationDelay) {
            send()
        }
    }

    static func send() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeV: CGKeyCode = 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
