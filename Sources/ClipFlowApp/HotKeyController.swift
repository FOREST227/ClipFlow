import Carbon
import Foundation

final class HotKeyController {
    private let action: @MainActor () -> Void
    private let signature = OSType.random(in: 1...UInt32.max)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var activeID: UInt32 = 0
    private(set) var currentShortcut: ClipFlowShortcut?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    // Register the replacement before releasing the working shortcut.
    // On failure the existing binding remains active.
    func register(_ shortcut: ClipFlowShortcut) -> String? {
        if let error = shortcut.validationError { return error }
        if hotKeyRef != nil, currentShortcut == shortcut { return nil }
        if let error = installHandlerIfNeeded() { return error }

        nextID &+= 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: signature, id: nextID),
            GetApplicationEventTarget(), 0, &replacement
        )
        guard status == noErr, let replacement else {
            return "无法使用 \(shortcut.displayName)，可能已被系统或其他应用占用。请换一个组合。（\(status)）"
        }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = replacement
        currentShortcut = shortcut
        activeID = nextID
        return nil
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        currentShortcut = nil
        activeID = 0
    }

    private func installHandlerIfNeeded() -> String? {
        guard eventHandler == nil else { return nil }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
            )
            guard status == noErr, identifier.signature == controller.signature,
                  identifier.id == controller.activeID, controller.hotKeyRef != nil else {
                return OSStatus(eventNotHandledErr)
            }
            let action = controller.action
            Task { @MainActor in action() }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        return status == noErr ? nil : "无法启动全局快捷键服务。（\(status)）"
    }

    deinit {
        stop()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
