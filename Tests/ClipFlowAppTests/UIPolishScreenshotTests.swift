import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Opt-in before/after renders for the label, card, snippet, and inspector polish.
/// Skipped unless CLIPFLOW_UI_POLISH_DIR is set.
@MainActor
final class UIPolishScreenshotTests: XCTestCase {
    func testExportUIPolishScreenshots() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_UI_POLISH_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_UI_POLISH_DIR to export UI polish screenshots")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "UIPolishScreenshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temp)
            NSApp.appearance = nil
        }
        let store = ClipFlowStore(storageDirectory: temp, defaults: defaults)
        store.ingestCopiedText("把界面说明写清楚，方便以后找回。", sourceApp: "备忘录", sourceBundleID: nil)
        store.ingestCopiedText("https://github.com/FOREST227/ClipFlow", sourceApp: "Safari", sourceBundleID: nil)
        store.ingestCopiedText("""
        func greeting(_ name: String) -> String {
            return "你好，\\(name)"
        }
        """, sourceApp: "Xcode", sourceBundleID: nil)
        let sample = NSImage(size: NSSize(width: 960, height: 240))
        sample.lockFocus()
        NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 960, height: 240).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSRect(x: 36, y: 70, width: 280, height: 100).fill()
        sample.unlockFocus()
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sample.tiffRepresentation)))
        store.ingestCopiedImage(try XCTUnwrap(image.representation(using: .png, properties: [:])),
            size: sample.size, sourceApp: "预览", sourceBundleID: nil)
        _ = store.createSnippet(title: "公司地址", body: "上海市徐汇区漕溪北路 18 号\n3 楼前台", category: "地址")
        _ = store.createSnippet(title: "邮件签名", body: "淇铖\nClipFlow 剪流", category: "签名")
        _ = store.createSnippet(title: "常用回复", body: "收到，我看完后回复你。", category: "回复")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        func bitmap(of view: NSView) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            return image
        }
        func save(_ view: NSView, name: String) throws {
            try XCTUnwrap(try bitmap(of: view).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func export<V: View>(_ view: V, size: NSSize, name: String, scheme: ColorScheme) throws {
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let host = NSHostingController(rootView: view
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(scheme))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable]
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            try save(host.view, name: name)
        }

        let markdown = ClipboardClassifier.makeItem(text: """
        # 周会纪要

        - 统一菜单和设置里的开关文案
        - 图片卡片不要留下空白

        **记下的内容，随时找回。**
        """, sourceApp: "备忘录", sourceBundleID: nil, autoProtectSecrets: false, existingItem: nil)
        let imageItem = try XCTUnwrap(store.items.first(where: \.isImage))

        for scheme: ColorScheme in [.light, .dark] {
            let tag = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: appearance)
            let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 880, height: 720))
            window.makeKeyAndOrderFront(nil)
            controller.navigation.select(.history)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            try save(try XCTUnwrap(window.contentView?.superview), name: "history-\(tag)")
            controller.navigation.select(.snippets)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            try save(try XCTUnwrap(window.contentView?.superview), name: "snippets-\(tag)")
            for section in SettingsCategory.allCases {
                controller.navigation.selectSettings(section)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                try save(try XCTUnwrap(window.contentView?.superview), name: "settings-\(section.id)-\(tag)")
            }
            window.close()

            let menu = MenuBarView(store: store)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(scheme)
            let menuHeight = ceil(NSHostingController(rootView: menu).view.fittingSize.height)
            let backdrop = scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color(red: 0.93, green: 0.94, blue: 0.96)
            try export(menu.frame(width: 360, height: max(menuHeight, 280)).background(backdrop),
                size: NSSize(width: 360, height: max(menuHeight, 280)), name: "menu-\(tag)", scheme: scheme)

            let palette = ClipFlowPalette.resolve(for: scheme)
            func detail(_ item: ClipboardItem) -> some View {
                LibraryInspectorOverlay(item: item, store: store, palette: palette,
                    maxHeight: 560, contentWidth: 380, compactShadow: true, onClose: {})
                    .frame(width: 380, height: 560, alignment: .top)
                    .padding(12)
                    .background(backdrop)
            }
            try export(detail(markdown), size: NSSize(width: 404, height: 584), name: "inspector-markdown-\(tag)", scheme: scheme)
            try export(detail(imageItem), size: NSSize(width: 404, height: 584), name: "inspector-image-\(tag)", scheme: scheme)
        }
    }
}
