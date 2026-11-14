import AppKit
import XCTest
@testable import ClipFlowApp

/// Opt-in renders of the real settings window. Skipped unless
/// CLIPFLOW_HISTORY_LIMIT_SCREENSHOT_DIR is set, so CI does not depend on pixels.
@MainActor
final class HistoryLimitScreenshotTests: XCTestCase {
    func testExportHistoryLimitScreenshots() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_HISTORY_LIMIT_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_HISTORY_LIMIT_SCREENSHOT_DIR to export history-limit screenshots")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "HistoryLimitScreenshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(200, forKey: ClipFlowStore.Keys.historyItemLimit)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            NSApp.appearance = nil
        }
        var items: [ClipboardItem] = (0..<90).map { index in
            var item = ClipboardClassifier.makeItem(
                text: "历史 \(index)", sourceApp: "备忘录", sourceBundleID: nil,
                autoProtectSecrets: false, existingItem: nil
            )
            let date = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
            item.createdAt = date
            item.capturedAt = date
            return item
        }
        var pinned = ClipboardClassifier.makeItem(
            text: "置顶的发布清单", sourceApp: "备忘录", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil
        )
        let pinDate = Date(timeIntervalSince1970: 1_700_000_500)
        pinned.createdAt = pinDate
        pinned.capturedAt = pinDate
        pinned.pinned = true
        pinned.pinnedAt = pinDate
        items.append(pinned)
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("history.json"))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.lastCaptureStatus = "正在监听系统剪贴板"
        XCTAssertEqual(store.historyItemLimit, 200)
        XCTAssertEqual(HistoryRetention.removalCount(in: store.items, limit: 80), 10)

        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"), initialPage: .settings)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 680, height: 720))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        func apply(_ scheme: NSAppearance.Name) {
            NSApp.appearance = NSAppearance(named: scheme)
            window.appearance = NSAppearance(named: scheme)
            root.appearance = NSAppearance(named: scheme)
            window.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        }
        func save(_ name: String) throws {
            let frame = try XCTUnwrap(root.superview)
            frame.layoutSubtreeIfNeeded()
            window.display()
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
        }

        apply(.aqua)
        try save("history_limit_setting_light.png")
        apply(.darkAqua)
        try save("history_limit_setting_dark.png")
        apply(.aqua)
        controller.navigation.settingsDraft.requestHistoryLimit(80, in: store)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        try save("history_limit_trim_light.png")
        apply(.darkAqua)
        try save("history_limit_trim_dark.png")
        XCTAssertEqual(store.historyItemLimit, 200, "Capturing the warning must not delete history")
        XCTAssertEqual(controller.navigation.settingsDraft.pendingHistoryLimit, 80)
    }
}
