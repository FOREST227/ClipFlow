import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Opt-in stills of the table grid, the history row, and an ordinary text item.
@MainActor
final class TablePreviewScreenshotTests: XCTestCase {
    func testExportTablePreviewScreenshots() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_TABLE_PREVIEW_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_TABLE_PREVIEW_DIR to export table preview screenshots")
        }
        _ = NSApplication.shared
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = oldAppearance }
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "TablePreviewScreenshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(
            storageDirectory: directory,
            defaults: defaults,
            payloadRepository: MemorySensitivePayloadRepository()
        )
        let palette = ClipFlowPalette.resolve(for: .light)
        let capturedAt = Date().addingTimeInterval(-9)
        var table = sample(
            text: """
            活动\t曝光\t点击\t花费\t转化率\t订单
            春季上新\t128430\t6421\t18320.50\t5.0%\t312
            会员日\t98400\t4102\t9600.00\t4.2%\t188
            清明档\t76420\t3011\t7420.00\t3.9%\t141
            周末返场\t110230\t4988\t12110.75\t4.5%\t256
            直播专场\t156000\t8120\t20440.00\t5.2%\t401
            """,
            labels: ["Microsoft Excel", "长文本", "表格"],
            capturedAt: capturedAt
        )
        var prose = sample(
            text: "设计稿确认后，记得同步更新使用文档。",
            labels: ["备忘录", "便签"],
            sourceApp: "备忘录",
            capturedAt: capturedAt.addingTimeInterval(-40)
        )
        prose.kind = .text
        table.kind = .text

        func save(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func export<V: View>(_ view: V, name: String, width: CGFloat) throws {
            let host = NSHostingController(rootView: view
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(.light))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: width, height: 720))
            window.appearance = NSAppearance(named: .aqua)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            host.view.layoutSubtreeIfNeeded()
            let fitted = host.view.fittingSize
            let height = min(720, max(180, ceil(fitted.height)))
            window.setContentSize(NSSize(width: width, height: height))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.view.layoutSubtreeIfNeeded()
            let settled = host.view.fittingSize
            let settledHeight = min(720, max(height, ceil(settled.height)))
            if abs(settledHeight - height) > 1 {
                window.setContentSize(NSSize(width: width, height: settledHeight))
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.view.layoutSubtreeIfNeeded()
            }
            try save(host.view, name: name)
        }

        let detailWidth: CGFloat = 460
        try export(
            LibraryInspectorOverlay(
                item: table,
                store: store,
                palette: palette,
                maxHeight: 620,
                contentWidth: detailWidth,
                onClose: {}
            ),
            name: "table-detail",
            width: detailWidth
        )
        try export(
            VStack(spacing: LibraryCardLayout.spacing) {
                listRow(table, store: store, palette: palette)
                listRow(prose, store: store, palette: palette)
            }
            .padding(16)
            .frame(width: 520)
            .background(AppBackground(palette: palette)),
            name: "history-list",
            width: 520
        )
        try export(
            LibraryInspectorOverlay(
                item: prose,
                store: store,
                palette: palette,
                maxHeight: 420,
                contentWidth: detailWidth,
                onClose: {}
            ),
            name: "text-detail",
            width: detailWidth
        )
    }

    private func listRow(_ item: ClipboardItem, store: ClipFlowStore, palette: ClipFlowPalette) -> some View {
        ZStack {
            CardSelectionChrome(isSelected: false, tint: item.kind.tint, palette: palette)
            ClipboardCard(item: item, displayedSnippet: item.snippet, palette: palette, store: store)
        }
        .frame(height: LibraryCardLayout.height(for: item))
    }

    private func sample(text: String, labels: [String], sourceApp: String = "Microsoft Excel", capturedAt: Date) -> ClipboardItem {
        var stored = ClipboardClassifier.makeItem(
            text: text,
            sourceApp: sourceApp,
            sourceBundleID: sourceApp == "Microsoft Excel" ? "com.microsoft.Excel" : nil,
            autoProtectSecrets: false,
            existingItem: nil
        )
        stored.labels = labels
        stored.kind = .text
        stored.title = ClipboardKind.text.label
        stored.createdAt = capturedAt
        stored.capturedAt = capturedAt
        return stored
    }
}
