import AppKit
import Carbon
import SwiftUI
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
        let controlV = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        XCTAssertEqual(controlV.displayName, "\u{2303}V")
        XCTAssertFalse(controlV.displayName.contains(" "))
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

    func testGlyphRunsSeparateModifiersAndCenterThemOnTheKey() {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let controlV = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        XCTAssertEqual(controlV.displayName, "\u{2303}V")
        XCTAssertFalse(controlV.displayName.contains(" "))
        XCTAssertEqual(ShortcutGlyphLayout.plainText(for: controlV), controlV.displayName)
        XCTAssertGreaterThanOrEqual(ShortcutGlyphLayout.spacing, 2)
        XCTAssertLessThanOrEqual(ShortcutGlyphLayout.spacing, 4)

        let runs = ShortcutGlyphLayout.runs(for: controlV, font: font)
        XCTAssertEqual(runs.map(\.text), ["⌃", "V"])
        let target = ShortcutGlyphLayout.opticalMiddle(of: "V", font: font)
        XCTAssertEqual(target, font.capHeight / 2, accuracy: 0.2)
        let rawLift = ShortcutGlyphLayout.inkMidY("⌃", font: font) - target
        XCTAssertGreaterThan(rawLift, 0.5, "⌃ is drawn above a capital's middle in the system font")
        XCTAssertEqual(runs[0].baselineOffset, -rawLift, accuracy: 0.01)
        XCTAssertEqual(runs[1].baselineOffset, 0, accuracy: 0.001)

        let combo = ClipFlowShortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        let comboRuns = ShortcutGlyphLayout.runs(for: combo, font: font)
        XCTAssertEqual(comboRuns.map(\.text), ["⌃", "⌥", "⇧", "⌘", "F18"])
        XCTAssertEqual(combo.displayName, "⌃⌥⇧⌘F18")
        let comboTarget = ShortcutGlyphLayout.opticalMiddle(of: "F18", font: font)
        for run in comboRuns.dropLast() {
            let centered = ShortcutGlyphLayout.inkMidY(run.text, font: font) + run.baselineOffset
            XCTAssertEqual(centered, comboTarget, accuracy: 0.05, run.text)
        }
        XCTAssertEqual(comboRuns.last?.baselineOffset ?? -1, 0, accuracy: 0.001)

        let period = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(controlKey))
        XCTAssertEqual(period.keyCaps.last, ".")
        let periodRuns = ShortcutGlyphLayout.runs(for: period, font: font)
        let corrected = ShortcutGlyphLayout.inkMidY("⌃", font: font) + periodRuns[0].baselineOffset
        XCTAssertEqual(corrected, font.capHeight / 2, accuracy: 0.25)
        XCTAssertGreaterThan(abs(corrected - ShortcutGlyphLayout.inkMidY(".", font: font)), 1)

        let menuFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let menuRuns = ShortcutGlyphLayout.runs(for: controlV, font: menuFont)
        let menuTarget = ShortcutGlyphLayout.opticalMiddle(of: "V", font: menuFont)
        XCTAssertEqual(
            ShortcutGlyphLayout.inkMidY("⌃", font: menuFont) + menuRuns[0].baselineOffset,
            menuTarget,
            accuracy: 0.05
        )

        let attributed = ShortcutGlyphLayout.attributedString(for: controlV, font: font)
        XCTAssertEqual(attributed.string, controlV.displayName)
        var sawKern = false
        var offsets: [CGFloat] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let slice = (attributed.string as NSString).substring(with: range)
            if let kern = attributes[.kern] as? NSNumber {
                XCTAssertEqual(slice, "⌃")
                XCTAssertEqual(kern.doubleValue, Double(ShortcutGlyphLayout.spacing), accuracy: 0.001)
                sawKern = true
            }
            if let offset = attributes[.baselineOffset] as? NSNumber {
                offsets.append(CGFloat(offset.doubleValue))
            }
        }
        XCTAssertTrue(sawKern)
        XCTAssertEqual(offsets.count, 2)
        XCTAssertEqual(offsets[0], runs[0].baselineOffset, accuracy: 0.01)
        XCTAssertEqual(offsets[1], 0, accuracy: 0.01)
    }

    func testRenderedShortcutCentersModifiersAndSeparatesThem() throws {
        let controlV = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        let controlParts = try glyphParts(in: ShortcutGlyphLayout.text(for: controlV, pointSize: 14, weight: .medium))
        XCTAssertEqual(controlParts.count, 2, "\(controlParts)")
        guard controlParts.count >= 2 else { return }
        XCTAssertEqual(controlParts[0].midY, controlParts[1].midY, accuracy: 1)
        let controlGap = controlParts[1].minX - controlParts[0].maxX
        XCTAssertGreaterThanOrEqual(controlGap, 2)
        XCTAssertLessThanOrEqual(controlGap, 7)

        let combo = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        let parts = try glyphParts(in: ShortcutGlyphLayout.text(for: combo, pointSize: 14, weight: .medium))
        XCTAssertEqual(parts.count, 5)
        let key = try XCTUnwrap(parts.last)
        for (index, part) in parts.dropLast().enumerated() {
            XCTAssertEqual(part.midY, key.midY, accuracy: 1, "modifier \(index)")
        }
        for pair in zip(parts, parts.dropFirst()) {
            let gap = pair.1.minX - pair.0.maxX
            XCTAssertGreaterThanOrEqual(gap, 2, "gap before \(pair.1.minX)")
            XCTAssertLessThanOrEqual(gap, 7)
        }
    }

    func testRecorderAccessibilityValueStaysCompact() throws {
        _ = NSApplication.shared
        let suite = "ClipFlowShortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.registerShortcut = { _ in nil }
        store.suspendShortcut = {}
        let controlV = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        XCTAssertTrue(store.setQuickPasteShortcut(controlV))
        let host = NSHostingController(rootView: ShortcutRecorder(store: store).frame(width: 144, height: 32))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 144, height: 32))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let button = try XCTUnwrap(descendants(host.view, ShortcutRecorderButton.self).first)
        XCTAssertEqual(button.accessibilityValue() as? String, "⌃V")
        XCTAssertTrue(store.beginShortcutRecording())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(button.accessibilityValue() as? String, "正在录入快捷键")
        store.endShortcutRecording()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(button.accessibilityValue() as? String, "⌃V")
    }

    private struct GlyphPart {
        var minX: CGFloat
        var maxX: CGFloat
        var midY: CGFloat
    }

    private func glyphParts(in view: some View) throws -> [GlyphPart] {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: view
            .foregroundStyle(Color.black)
            .padding(8)
            .frame(width: 220, height: 48, alignment: .leading)
            .background(Color.white))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 220, height: 48))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let root = host.view
        root.layoutSubtreeIfNeeded()
        let scale = root.window?.backingScaleFactor ?? 2
        let pixelsWide = max(1, Int((root.bounds.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((root.bounds.height * scale).rounded(.up)))
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        func luminance(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        }
        var columns: [Int] = []
        for x in 0..<pixelsWide {
            var ink = false
            for y in 0..<pixelsHigh where luminance(x, y) < 0.45 {
                ink = true
                break
            }
            if ink { columns.append(x) }
        }
        XCTAssertFalse(columns.isEmpty)
        var parts: [GlyphPart] = []
        var start = columns[0]
        var previous = start
        func close(_ from: Int, _ through: Int) {
            var minY = pixelsHigh
            var maxY = 0
            for x in from...through {
                for y in 0..<pixelsHigh where luminance(x, y) < 0.45 {
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            parts.append(GlyphPart(
                minX: CGFloat(from) / scale,
                maxX: CGFloat(through) / scale,
                midY: CGFloat(minY + maxY) / 2 / scale
            ))
        }
        for x in columns.dropFirst() {
            if x > previous + 2 {
                close(start, previous)
                start = x
            }
            previous = x
        }
        close(start, previous)
        return parts
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
}
