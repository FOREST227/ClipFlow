import AppKit
import Carbon
import XCTest
@testable import ClipFlowApp

/// Opt-in renders of the real Settings keycap. Skipped unless CLIPFLOW_KEYCAP_DIR is set.
@MainActor
final class ShortcutGlyphScreenshotTests: XCTestCase {
    func testExportSettingsKeycaps() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_KEYCAP_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_KEYCAP_DIR to export keycap screenshots")
        }
        let tag = ProcessInfo.processInfo.environment["CLIPFLOW_KEYCAP_TAG"] ?? "shot"
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let controlV = ClipFlowShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        let combo = ClipFlowShortcut(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        for scheme in ["light", "dark"] {
            try exportSettings(shortcut: controlV, recording: false, scheme: scheme, name: "\(tag)-settings-\(scheme)-control-v", to: output)
            try exportSettings(shortcut: combo, recording: false, scheme: scheme, name: "\(tag)-settings-\(scheme)-all-modifiers", to: output)
            try exportSettings(shortcut: controlV, recording: true, scheme: scheme, name: "\(tag)-settings-\(scheme)-recording", to: output)
        }
    }

    private func exportSettings(shortcut: ClipFlowShortcut, recording: Bool, scheme: String, name: String, to output: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "KeycapShot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.registerShortcut = { _ in nil }
        store.suspendShortcut = {}
        XCTAssertTrue(store.setQuickPasteShortcut(shortcut))
        if recording {
            XCTAssertTrue(store.beginShortcutRecording())
        }
        let appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"), initialPage: .settings)
        let window = try XCTUnwrap(controller.window)
        window.appearance = appearance
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 760, height: 640))
        window.setFrameOrigin(NSPoint(x: 80, y: 120))
        controller.navigation.selectSettings(.general)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try snapshot(content)
        try write(bitmap, to: output.appendingPathComponent("\(name)-window.png"))
        let button = try XCTUnwrap(descendants(content, ShortcutRecorderButton.self).first)
        let keycap = content.convert(button.bounds, from: button).insetBy(dx: -6, dy: -6)
        try write(try crop(bitmap, view: content, rect: keycap), to: output.appendingPathComponent("\(name)-keycap.png"))
        let row = keycap.insetBy(dx: -220, dy: -8)
        try write(try crop(bitmap, view: content, rect: row.intersection(content.bounds)), to: output.appendingPathComponent("\(name)-row.png"))
        window.orderOut(nil)
        window.close()
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        let pixelsWide = max(1, Int((view.bounds.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((view.bounds.height * scale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
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
        ) else {
            XCTFail("bitmap")
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func crop(_ bitmap: NSBitmapImageRep, view: NSView, rect: NSRect) throws -> NSBitmapImageRep {
        let scale = bitmap.size.width > 0 ? CGFloat(bitmap.pixelsWide) / bitmap.size.width : 1
        var pixel = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        if !view.isFlipped {
            pixel.origin.y = CGFloat(bitmap.pixelsHigh) - pixel.origin.y - pixel.height
        }
        pixel.origin.x = max(0, pixel.origin.x)
        pixel.origin.y = max(0, pixel.origin.y)
        pixel.size.width = min(pixel.width, CGFloat(bitmap.pixelsWide) - pixel.origin.x)
        pixel.size.height = min(pixel.height, CGFloat(bitmap.pixelsHigh) - pixel.origin.y)
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: pixel))
        let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
        rep.size = NSSize(width: pixel.width / scale, height: pixel.height / scale)
        return rep
    }

    private func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
}
