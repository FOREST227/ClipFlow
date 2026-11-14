import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Opt-in renders of the real product views for the UI audit. Skipped unless
/// CLIPFLOW_AUDIT_SCREENSHOT_DIR is set, so the default suite stays quiet.
@MainActor
final class AuditScreenshotTests: XCTestCase {
    func testExportAuditScreenshots() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_AUDIT_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_AUDIT_SCREENSHOT_DIR to export audit screenshots")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AuditScreenshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temp)
        }
        let store = ClipFlowStore(storageDirectory: temp, defaults: defaults)
        for index in 0..<130 {
            store.ingestCopiedText("备忘 \(index)：把界面说明写清楚，方便以后找回。", sourceApp: "备忘录", sourceBundleID: nil)
        }
        for index in 0..<110 {
            store.ingestCopiedText("https://github.com/FOREST227/ClipFlow/pull/\(index)", sourceApp: "Safari", sourceBundleID: nil)
        }
        for index in 0..<20 {
            store.ingestCopiedText("func note\(index)() {\n    return \(index)\n}", sourceApp: "Xcode", sourceBundleID: nil)
        }
        if let first = store.items.first { store.togglePin(first.id) }
        let sample = NSImage(size: NSSize(width: 720, height: 400))
        sample.lockFocus()
        NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 720, height: 400).fill()
        sample.unlockFocus()
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sample.tiffRepresentation)))
        store.ingestCopiedImage(try XCTUnwrap(image.representation(using: .png, properties: [:])),
            size: sample.size, sourceApp: "预览", sourceBundleID: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))

        func save(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func export<V: View>(_ view: V, size: NSSize, name: String, scheme: ColorScheme) throws {
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let host = NSHostingController(rootView: view
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(scheme))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            try save(host.view, name: name)
        }

        for scheme: ColorScheme in [.light, .dark] {
            let tag = scheme == .dark ? "dark" : "light"
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: appearance)
            let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 620, height: 780))
            window.makeKeyAndOrderFront(nil)
            controller.navigation.select(.history)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            try save(try XCTUnwrap(window.contentView?.superview), name: "history-\(tag)")
            controller.navigation.selectSettings(.general)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            try save(try XCTUnwrap(window.contentView?.superview), name: "settings-\(tag)")
            store.startupPermissionReport = ClipFlowPermissionReport(
                title: "需要辅助功能权限",
                message: "自动粘贴需要这项权限。未授权时会改为复制到剪贴板，请在目标应用中手动粘贴。",
                items: [
                    ClipFlowPermissionItem(title: "辅助功能", detail: "用于把选中的历史直接粘贴到上一个应用。",
                        icon: "accessibility", status: .needsAttention),
                    ClipFlowPermissionItem(title: "剪贴板", detail: "读取你复制的文字和图片。",
                        icon: "doc.on.clipboard", status: .granted)
                ])
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            try save(try XCTUnwrap(window.contentView?.superview), name: "permission-\(tag)")
            store.startupPermissionReport = nil
            window.close()

            let menuHeight = ceil(NSHostingController(rootView: MenuBarView(store: store)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(scheme)).view.fittingSize.height)
            let backdrop = scheme == .dark ? Color.black : Color.white
            try export(MenuBarView(store: store)
                .frame(width: 360, height: menuHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(12).background(backdrop),
                size: NSSize(width: 384, height: menuHeight + 24), name: "menu-\(tag)", scheme: scheme)

            let code = ClipboardClassifier.makeItem(text: """
            // 注释需要在浅色底上可读
            func greeting(_ name: String) -> String {
                return "你好，\\(name)"
            }
            """, sourceApp: "Xcode", sourceBundleID: nil, autoProtectSecrets: false, existingItem: nil)
            let imageItem = try XCTUnwrap(store.items.first(where: \.isImage))
            func detail(_ item: ClipboardItem) -> some View {
                LibraryInspectorOverlay(item: item, store: store,
                    palette: .resolve(for: scheme), maxHeight: 576, contentWidth: 340,
                    compactShadow: true, onClose: {})
                    .frame(width: 340, height: 576)
                    .padding(16)
                    .background(backdrop)
            }
            try export(detail(code), size: NSSize(width: 372, height: 608), name: "inspector-\(tag)", scheme: scheme)
            try export(detail(imageItem), size: NSSize(width: 372, height: 608), name: "image-detail-\(tag)", scheme: scheme)
            // The history store keeps 80 items, so live counts stay two digits.
            // This is the same CategoryPill row at the 454pt content width with the
            // three-digit counts the audit measured.
            try export(AuditFilterStrip().frame(width: 454, height: 40).background(scheme == .dark
                ? Color(red: 0.11, green: 0.12, blue: 0.15)
                : Color(red: 0.97, green: 0.965, blue: 0.955)),
                size: NSSize(width: 454, height: 40), name: "filter-\(tag)", scheme: scheme)
        }
        NSApp.appearance = nil
    }
}

private struct AuditFilterStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    private let counts: [(ClipCategory, Int)] = [
        (.all, 128), (.pinned, 104), (.text, 256), (.code, 188),
        (.links, 312), (.images, 101), (.protected, 240)
    ]

    private var page: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.12, blue: 0.15)
            : Color(red: 0.97, green: 0.965, blue: 0.955)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ClipFlowLayout.space8) {
                ForEach(counts, id: \.0) { category, count in
                    CategoryPill(category: category, count: count, isSelected: category == .all)
                }
            }
        }
        .frame(width: 454, height: CategoryPill.height)
        .background(page)
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [page.opacity(0), page], startPoint: .leading, endPoint: .trailing)
                .frame(width: ClipFlowLayout.space12)
                .allowsHitTesting(false)
        }
    }
}
