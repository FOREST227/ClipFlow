import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: View {
    @ObservedObject var store: ClipFlowStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    @ViewState private var focused = false

    private var accent: Color { ClipCategory.all.tint }

    var body: some View {
        ShortcutRecorderInput(store: store, focused: $focused)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(store.isRecordingShortcut ? accent.opacity(0.10) : Color.primary.opacity(0.035))
            }
            .overlay {
                Text(store.isRecordingShortcut ? "按下组合键…" : store.quickPasteShortcut.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(store.isRecordingShortcut ? accent : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(store.isRecordingShortcut || focused ? accent.opacity(0.5)
                        : hovered ? accent.opacity(0.3) : Color.primary.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: store.isRecordingShortcut)
    }
}

private struct ShortcutRecorderInput: NSViewRepresentable {
    @ObservedObject var store: ClipFlowStore
    @Binding var focused: Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.isBordered = false
        button.isTransparent = true
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("录入快速粘贴快捷键")
        button.setAccessibilityHelp("点击后按组合键，按 Escape 取消。")
        configure(button)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        configure(button)
        // Leaving Settings ends recording on the store. The button stays mounted
        // on the hidden page, so drop its monitor here or the next key is swallowed.
        if !store.isRecordingShortcut {
            button.disarmLocalCapture()
        }
    }

    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 176, height: proposal.height ?? 36)
    }

    private func configure(_ button: ShortcutRecorderButton) {
        button.focusChanged = { isFocused in
            // Resigning during a page change is inside the SwiftUI update.
            // Writing focus state there cycles the attribute graph.
            DispatchQueue.main.async {
                if focused != isFocused { focused = isFocused }
            }
        }
        button.beginRecording = { store.beginShortcutRecording() }
        button.endRecording = { store.endShortcutRecording() }
        button.recordingIsActive = { store.isRecordingShortcut }
        button.capture = { shortcut in _ = store.setQuickPasteShortcut(shortcut) }
        button.shortcutTitle = store.quickPasteShortcut.displayName
        button.setAccessibilityValue(store.isRecordingShortcut ? "正在录入快捷键" : store.quickPasteShortcut.displayName)
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.finishRecording()
    }
}

final class ShortcutRecorderButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 176, height: 36) }
    var focusChanged: ((Bool) -> Void)?
    var beginRecording: (() -> Bool)?
    var endRecording: (() -> Void)?
    var recordingIsActive: (() -> Bool)?
    var capture: ((ClipFlowShortcut) -> Void)?
    var shortcutTitle = ""
    private var recording = false
    var isCapturing: Bool { recording }
    private var resignObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // SwiftUI draws the single rounded focus/recording border.
        focusRingType = .none
        target = self
        action = #selector(begin)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func begin() {
        guard !recording, let window, window.makeFirstResponder(self) else { return }
        guard beginRecording?() == true else { return }
        recording = true
        refreshTitle()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecording() }
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if self.recording, self.recordingIsActive?() == false {
                    self.disarmLocalCapture()
                }
                let active = self.recording && (self.recordingIsActive?() ?? true) && self.window?.isKeyWindow == true
                guard active else { return event }
                self.keyDown(with: event)
                return nil
            }
            if event.window !== self.window
                || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.finishRecording()
            }
            return event
        }
    }

    func refreshTitle() {
        let next = recording ? "请按组合键…（Esc 取消）" : shortcutTitle
        guard title != next else { return }
        title = next
    }

    /// Stops the local monitor without asking the store to restore the shortcut.
    /// The store is already idle when Settings hides the recorder but keeps the view.
    func disarmLocalCapture() {
        guard recording else { return }
        recording = false
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        refreshTitle()
    }

    func finishRecording() {
        guard recording else { return }
        disarmLocalCapture()
        endRecording?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged?(false) }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode != UInt16(kVK_Escape) {
            capture?(ClipFlowShortcut(keyCode: event.keyCode, flags: event.modifierFlags))
        }
        finishRecording()
    }
}
