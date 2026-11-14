import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Opt-in renders of the plain-text paste UI and a live pasteboard type dump.
@MainActor
final class PlainTextPasteScreenshotTests: XCTestCase {
    private let original = """
    会议纪要
        先对齐范围
            再改文案

    保留空行与缩进
    """

    func testExportPlainPasteEvidence() throws {
        guard let raw = ProcessInfo.processInfo.environment["CLIPFLOW_PLAIN_PASTE_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_PLAIN_PASTE_DIR to export plain-paste screenshots")
        }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        let previousAppearance = NSApp.appearance
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            NSApp.appearance = previousAppearance
            NSApp.setActivationPolicy(previousPolicy)
        }
        let output = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PlainPasteShot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults,
            accessibility: RecordingAccessibilityTrust(trusted: true))
        let rtf = try boldRTF()
        let html = Data("<p>会议纪要<br>先对齐<strong>范围</strong></p>".utf8)
        store.ingestCopiedText("已经是纯文本的一条备忘", sourceApp: "备忘录", sourceBundleID: nil)
        store.ingestCopiedText(original, sourceApp: "文本编辑", sourceBundleID: nil,
            richContent: ClipboardRepresentations.Snapshot(rtfData: rtf, htmlData: html, fileURLs: []))
        let rich = try XCTUnwrap(store.items.first { $0.fullText == original })
        XCTAssertTrue(PlainTextPaste.hasRichText(rich))

        for scheme in ["light", "dark"] {
            let appearance = try XCTUnwrap(NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua))
            NSApp.appearance = appearance
            store.appearanceMode = scheme == "dark" ? .dark : .light
            try exportQuickPaste(store: store, appearance: appearance, to: output.appendingPathComponent("quick-paste-\(scheme).png"))
            try exportHistory(store: store, richID: rich.id, appearance: appearance, showMenu: true, showInspector: false,
                to: output.appendingPathComponent("context-menu-\(scheme).png"))
            try exportHistory(store: store, richID: rich.id, appearance: appearance, showMenu: false, showInspector: true,
                to: output.appendingPathComponent("inspector-\(scheme).png"))
        }

        let destination = NSPasteboard.withUniqueName()
        addTeardownBlock { destination.releaseGlobally() }
        let service = PasteService(store: store, pasteboard: destination, commitPaste: { _ in })
        service.paste(rich, preferredTarget: nil, plainText: true)
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(destination))
        XCTAssertEqual(destination.string(forType: .string), original)
        try exportDump(pasteboard: destination, to: output.appendingPathComponent("pasteboard-types.png"))
    }

    private func exportQuickPaste(store: ClipFlowStore, appearance: NSAppearance, to url: URL) throws {
        let host = NSHostingController(rootView: QuickPastePanelView(
            store: store, preferredTargetName: "备忘录", onPaste: { _ in }, onOpenLibrary: {}, onClose: {}
        ).environment(\.locale, Locale(identifier: "zh-Hans")))
        let panel = QuickPastePanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickPastePanelLayout.panelWidth, height: QuickPastePanelLayout.panelHeight),
            styleMask: .borderless, backing: .buffered, defer: false)
        panel.appearance = appearance
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        pump(0.6)
        host.view.layoutSubtreeIfNeeded()
        try write(try snapshot(try XCTUnwrap(panel.contentView)), to: url)
        panel.orderOut(nil)
        panel.close()
    }

    private func exportHistory(store: ClipFlowStore, richID: UUID, appearance: NSAppearance,
                               showMenu: Bool, showInspector: Bool, to url: URL) throws {
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.appearance = appearance
        window.setContentSize(NSSize(width: ClipFlowLayout.libraryWidth, height: 640))
        window.isReleasedWhenClosed = false
        place(window)
        window.makeKeyAndOrderFront(nil)
        pump(0.7)
        let row = try XCTUnwrap(rows(in: window).first { $0.identifier?.rawValue == richID.uuidString })
        if showInspector {
            row.openDetails()
            pump(1.0)
            try write(try snapshot(try XCTUnwrap(window.contentView)), to: url)
        }
        if showMenu {
            let menu = try XCTUnwrap(row.contextMenu())
            let titles = menu.items.map(\.title)
            XCTAssertTrue(titles.contains(PlainTextPaste.pasteTitle))
            XCTAssertTrue(titles.contains(PlainTextPaste.copyTitle))
            try write(try captureMenu(menu, from: row, window: window), to: url)
        }
        window.orderOut(nil)
        window.close()
    }

    private func exportDump(pasteboard: NSPasteboard, to url: URL) throws {
        let types = PlainTextPaste.typeNames(on: pasteboard)
        let string = pasteboard.string(forType: .string) ?? ""
        let legacy = pasteboard.string(forType: NSPasteboard.PasteboardType(PlainTextPaste.legacyStringTypeName)) ?? ""
        let absent = [
            ("public.rtf", pasteboard.data(forType: .rtf) == nil),
            ("public.html", pasteboard.string(forType: .html) == nil && pasteboard.data(forType: .html) == nil),
            ("public.file-url", pasteboard.string(forType: .fileURL) == nil),
            ("NSFilenamesPboardType", pasteboard.propertyList(forType: ClipboardRepresentations.filenamesType) == nil),
            ("public.png", pasteboard.data(forType: .png) == nil)
        ]
        let typeLines = types.map { "  \($0)" }.joined(separator: "\n")
        let absentLines = absent.map { "  \($0.0): \($0.1 ? "无" : "存在")" }.joined(separator: "\n")
        let same = string == legacy
        let body = """
        纯文本粘贴写入的剪贴板

        types:
        \(typeLines)

        public.utf8-plain-text 与 NSStringPboardType 读回\(same ? "同一段原文" : "不同内容")。
        NSStringPboardType 是 AppKit 为纯字符串附带的旧类型名，不是第二种内容。

        不存在的类型:
        \(absentLines)

        public.utf8-plain-text:
        \(string)
        """
        let aqua = NSAppearance(named: .aqua)
        NSApp.appearance = aqua
        let text = NSTextField(wrappingLabelWithString: body)
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
        text.maximumNumberOfLines = 0
        text.frame = NSRect(x: 24, y: 24, width: 520, height: 10)
        text.preferredMaxLayoutWidth = 520
        text.sizeToFit()
        let size = NSSize(width: 568, height: ceil(text.frame.height) + 48)
        text.frame = NSRect(x: 24, y: 24, width: 520, height: size.height - 48)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClipFlow 剪贴板类型"
        window.appearance = aqua
        window.isReleasedWhenClosed = false
        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.appearance = aqua
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.95, alpha: 1).cgColor
        background.addSubview(text)
        window.contentView = background
        place(window)
        window.makeKeyAndOrderFront(nil)
        pump(0.3)
        try write(try snapshot(background), to: url)
        window.close()
    }

    private func captureMenu(_ menu: NSMenu, from row: NSView, window: NSWindow) throws -> NSBitmapImageRep {
        let before = Self.windowIDs()
        let point = NSPoint(x: 28, y: row.isFlipped ? row.bounds.maxY - 8 : 8)
        var captured: NSBitmapImageRep?
        var captureError: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let fresh = Self.windowIDs().subtracting(before)
            let info = Self.windowInfo().filter { entry in
                guard let number = entry[kCGWindowNumber as String] as? UInt32 else { return false }
                return fresh.contains(number)
            }
            let owned = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == Int32(ProcessInfo.processInfo.processIdentifier) }
            let chosen = owned.isEmpty ? info : owned
            if let image = Self.image(of: chosen) ?? Self.image(of: info) {
                captured = NSBitmapImageRep(cgImage: image)
            } else {
                let summary = info.map { entry -> String in
                    let name = entry[kCGWindowOwnerName as String] as? String ?? "?"
                    let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
                    return "\(name) \(bounds?["Width"] ?? 0)x\(bounds?["Height"] ?? 0)"
                }
                captureError = "no menu window image; new=\(fresh.count) \(summary.joined(separator: "; "))"
            }
            menu.cancelTracking()
        }
        menu.popUp(positioning: nil, at: point, in: row)
        if let captured { return captured }
        _ = window
        XCTFail(captureError ?? "菜单窗口没有生成可保存的图像")
        throw CocoaError(.fileWriteUnknown)
    }

    private func rows(in window: NSWindow) -> [LibraryInteractiveHostingView] {
        guard let root = window.contentView else { return [] }
        return descendants(root)
    }

    private func descendants(_ view: NSView) -> [LibraryInteractiveHostingView] {
        (view as? LibraryInteractiveHostingView).map { [$0] } ?? view.subviews.flatMap(descendants)
    }

    private func place(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + 72, y: visible.maxY - window.frame.height - 64))
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func boldRTF() throws -> Data {
        let text = NSMutableAttributedString(string: original)
        let regular = NSFont.systemFont(ofSize: 14)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        text.addAttribute(.font, value: regular, range: NSRange(location: 0, length: text.length))
        text.addAttribute(.font, value: bold, range: (original as NSString).range(of: "范围"))
        return try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        let pixelsWide = max(1, Int((view.bounds.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((view.bounds.height * scale).rounded(.up)))
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private static func windowIDs() -> Set<UInt32> {
        Set(windowInfo().compactMap { $0[kCGWindowNumber as String] as? UInt32 })
    }

    private static func windowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private static func image(of info: [[String: Any]]) -> CGImage? {
        let ids = info.compactMap { entry -> (UInt32, CGFloat)? in
            guard let number = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
            guard area > 400 else { return nil }
            return (number, area)
        }.sorted { $0.1 > $1.1 }
        guard let first = ids.first?.0 else { return nil }
        // One window at a time, so the capture stays inside that window and not the desktop.
        return CGWindowListCreateImage(.null, .optionIncludingWindow, first, [.boundsIgnoreFraming, .bestResolution])
    }
}
