import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Opt-in export of real app views with synthetic data for the README.
@MainActor
final class DocumentationScreenshotTests: XCTestCase {
    func testExportScreenshots() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_SCREENSHOT_DIR to export documentation screenshots")
        }
        _ = NSApplication.shared
        let oldPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(oldPolicy) }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DocumentationScreenshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: temp) }
        let store = ClipFlowStore(storageDirectory: temp, defaults: defaults)
        let oldIcon = NSApp.applicationIconImage
        if let root = ProcessInfo.processInfo.environment["CLIPFLOW_PROJECT_DIR"] {
            NSApp.applicationIconImage = NSImage(contentsOfFile: root + "/assets/icon/ClipFlow-icon-1024.png")
        }
        defer { NSApp.applicationIconImage = oldIcon }
        let texts = [
            ("设计稿确认后，记得同步更新使用文档。", "备忘录"),
            ("https://github.com/FOREST227/ClipFlow", "Safari"),
            ("Get-ChildItem -Path . -Recurse\n    | Where-Object { $_.Extension -eq '.swift' }", "终端"),
            ("func greeting(_ name: String) -> String {\n    return \"你好，\\(name)！\"\n}\n\nprint(greeting(\"ClipFlow\"))", "Xcode"),
            ("周五发布清单\n• 检查快捷键与自动粘贴\n• 更新功能截图\n• 整理版本说明", "备忘录"),
            ("# 项目笔记\n\n## 本周安排\n- 完成界面调整\n- 整理使用说明\n\n**所有记录，随时找回。**", "文本编辑")
        ]
        for (text, app) in texts { store.ingestCopiedText(text, sourceApp: app, sourceBundleID: nil) }
        if let swift = store.items.first(where: { $0.sourceApp == "Xcode" }) { store.togglePin(swift.id) }
        let sample = NSImage(size: NSSize(width: 720, height: 400))
        sample.lockFocus()
        NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 720, height: 400).fill()
        ("ClipFlow 剪流" as NSString).draw(at: NSPoint(x: 58, y: 230), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.23, green: 0.40, blue: 0.69, alpha: 1)])
        ("复制过的内容，随时找回。" as NSString).draw(at: NSPoint(x: 60, y: 166), withAttributes: [
            .font: NSFont.systemFont(ofSize: 26),
            .foregroundColor: NSColor.darkGray])
        sample.unlockFocus()
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sample.tiffRepresentation)))
        store.ingestCopiedImage(try XCTUnwrap(image.representation(using: .png, properties: [:])),
            size: sample.size, sourceApp: "预览", sourceBundleID: nil)
        store.lastCaptureStatus = "正在监听系统剪贴板"

        func save(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func export<V: View>(_ view: V, size: NSSize, name: String) throws {
            let host = NSHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(.light))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.setContentSize(size)
            window.appearance = NSAppearance(named: .aqua)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            try save(host.view, name: name)
        }
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 620, height: 780))
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        try save(try XCTUnwrap(window.contentView?.superview), name: "history")
        controller.navigation.selectSettings(.general)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        try save(try XCTUnwrap(window.contentView?.superview), name: "settings")
        try export(QuickPastePanelView(store: store, preferredTargetName: nil,
            onPaste: { _ in }, onOpenLibrary: {}, onClose: {}),
            size: NSSize(width: 360, height: 588), name: "quick-paste")
        try export(MenuBarView(store: store), size: NSSize(width: 360, height: 440), name: "menu")
        let code = try XCTUnwrap(store.items.first { $0.sourceApp == "Xcode" })
        try export(ZStack {
            Color(red: 0.94, green: 0.96, blue: 0.98)
            LibraryInspectorOverlay(item: code, store: store, palette: .resolve(for: .light),
                maxHeight: 500, onClose: {}).frame(width: 438).padding(16)
        }.frame(width: 470, height: 360),
            size: NSSize(width: 470, height: 360), name: "code-detail")
        try export(DetailTextRenderer(
            text: "# 项目笔记\n\n## 本周安排\n- 完成界面调整\n- 整理使用说明\n\n| 功能 | 状态 |\n| --- | --- |\n| 快速粘贴 | 已完成 |\n| 图片缩放 | 已完成 |\n\n> 复制过的内容，随时找回。",
            markdown: true, language: "markdown", dark: false).frame(width: 438, height: 330),
            size: NSSize(width: 438, height: 330), name: "markdown-preview")
    }
}
