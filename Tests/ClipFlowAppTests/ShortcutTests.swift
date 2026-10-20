import AppKit
import Carbon
import XCTest
@testable import ClipFlowApp

@MainActor
final class ShortcutTests: XCTestCase {
    func testLegacyQuickPasteShortcutIsPreservedWithoutOverridingNewPreference() throws {
        let suite = "ClipFlowShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"keyCode":8,"modifiers":6144}"#.utf8), forKey: "hotKeyQuickPaste")
        XCTAssertEqual(ClipFlowShortcut.load(from: defaults),
                       ClipFlowShortcut(keyCode: 8, modifiers: UInt32(controlKey | optionKey)))
        defaults.set(try JSONEncoder().encode(ClipFlowShortcut.default), forKey: ClipFlowShortcut.defaultsKey)
        XCTAssertEqual(ClipFlowShortcut.load(from: defaults), .default)
    }

    func testKeyCapsKeepNamedKeysTogether() {
        XCTAssertEqual(ClipFlowShortcut.default.keyCaps, ["⌥", "V"])
        let shortcut = ClipFlowShortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(shortcut.keyCaps, ["⌃", "⌥", "⇧", "⌘", "F18"])
        XCTAssertEqual(shortcut.displayName, "⌃⌥⇧⌘F18")
    }

    func testDefaultAndValidation() {
        XCTAssertEqual(ClipFlowShortcut.default.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(ClipFlowShortcut.default.modifiers, UInt32(optionKey))
        XCTAssertEqual(ClipFlowShortcut.default.displayName, "⌥V")
        XCTAssertFalse(ClipFlowShortcut(keyCode: 9, modifiers: 0).isValid)
        XCTAssertFalse(ClipFlowShortcut(keyCode: 9, modifiers: UInt32(shiftKey)).isValid)
        XCTAssertFalse(ClipFlowShortcut(keyCode: 999, modifiers: UInt32(cmdKey)).isValid)
        XCTAssertTrue(ClipFlowShortcut(keyCode: 9, modifiers: UInt32(controlKey | shiftKey)).isValid)
    }

    func testModifierConversionIgnoresCapsLockAndFunctionFlags() {
        let shortcut = ClipFlowShortcut(keyCode: 9, flags: [.command, .shift, .capsLock, .function])
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(shortcut.displayName, "⇧⌘V")
    }

    func testStandardPasteShortcutCannotInterceptAutomaticPaste() {
        XCTAssertFalse(ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)).isValid)
        XCTAssertTrue(ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey)).isValid)
    }

    func testSavedShortcutAndFailureRollback() throws {
        let suite = "ClipFlowShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let custom = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey))
        store.registerShortcut = { _ in nil }
        XCTAssertTrue(store.setQuickPasteShortcut(custom))
        XCTAssertEqual(store.quickPasteShortcut, custom)
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(reloaded.quickPasteShortcut, custom)
        store.registerShortcut = { _ in "快捷键已被占用" }
        XCTAssertFalse(store.setQuickPasteShortcut(.default))
        XCTAssertEqual(store.quickPasteShortcut, custom)
        XCTAssertNotNil(store.shortcutError)
        XCTAssertEqual(ClipFlowStore(storageDirectory: directory, defaults: defaults).quickPasteShortcut, custom)
        store.registerShortcut = { _ in nil }
        XCTAssertTrue(store.setQuickPasteShortcut(.default))
        XCTAssertEqual(ClipFlowStore(storageDirectory: directory, defaults: defaults).quickPasteShortcut, .default)
    }

    func testCorruptSavedShortcutFallsBackToDefault() throws {
        let suite = "ClipFlowShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"keyCode":999,"modifiers":256}"#.utf8), forKey: "quickPasteShortcut")
        XCTAssertEqual(ClipFlowShortcut.load(from: defaults), .default)
    }

    func testConflictingRegistrationKeepsOldShortcut() throws {
        let first = HotKeyController(action: {})
        let second = HotKeyController(action: {})
        let flags = UInt32(controlKey | optionKey | cmdKey)
        let original = ClipFlowShortcut(keyCode: UInt32(kVK_F18), modifiers: flags)
        let occupied = ClipFlowShortcut(keyCode: UInt32(kVK_F19), modifiers: flags)
        defer { first.stop(); second.stop() }
        XCTAssertNil(first.register(original))
        XCTAssertNil(second.register(occupied))
        XCTAssertNotNil(first.register(occupied))
        XCTAssertEqual(first.currentShortcut, original)
        second.stop()
        XCTAssertNotNil(second.register(original))
        first.stop()
        XCTAssertNil(second.register(original))
    }

    func testRecorderCapturesCombinationAndCancelsOnEscapeOrRemoval() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let button = ShortcutRecorderButton(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView = button
        var captured: ClipFlowShortcut?
        var isSuspended = false
        button.beginRecording = { isSuspended = true; return true }
        button.endRecording = { isSuspended = false }
        button.capture = { captured = $0 }
        button.performClick(nil)
        XCTAssertTrue(isSuspended)
        let combo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_K)))
        button.keyDown(with: combo)
        XCTAssertEqual(captured, ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertFalse(isSuspended)

        captured = nil
        button.performClick(nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)))
        button.keyDown(with: escape)
        XCTAssertNil(captured)
        XCTAssertFalse(isSuspended)
        button.performClick(nil)
        XCTAssertTrue(isSuspended)
        window.contentView = NSView()
        XCTAssertFalse(isSuspended)
        window.close()
    }

    func testCancelledRecordingRestoresSavedBinding() throws {
        let suite = "ClipFlowShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        var active: ClipFlowShortcut? = .default
        store.registerShortcut = { active = $0; return nil }
        store.suspendShortcut = { active = nil }
        XCTAssertTrue(store.beginShortcutRecording())
        XCTAssertNil(active)
        store.endShortcutRecording()
        XCTAssertEqual(active, .default)
        XCTAssertFalse(store.isRecordingShortcut)
        XCTAssertEqual(store.quickPasteShortcut, .default)
    }
}
