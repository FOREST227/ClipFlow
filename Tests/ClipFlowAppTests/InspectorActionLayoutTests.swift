import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Renders every detail-card action set at the overlay's real widths.
@MainActor
final class InspectorActionLayoutTests: XCTestCase {
    func testRenderedActionsStayInsideRealCardWidths() throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        let previousAppearance = NSApp.appearance
        let previousExcel = ExcelInsertContext.lastBundleID
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        ExcelInsertContext.lastBundleID = SpreadsheetClipboard.excelBundleID
        defer {
            ExcelInsertContext.lastBundleID = previousExcel
            NSApp.appearance = previousAppearance
            NSApp.setActivationPolicy(previousPolicy)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "InspectorActions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(
            storageDirectory: directory,
            defaults: defaults,
            payloadRepository: MemorySensitivePayloadRepository(),
            accessibility: RecordingAccessibilityTrust(trusted: true)
        )
        let fixtures = try makeFixtures(store: store)
        let output = ProcessInfo.processInfo.environment["CLIPFLOW_INSPECTOR_ACTION_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }

        let widths: [(String, CGFloat, Bool)] = [
            ("narrow", InspectorCardWidth.quickPaste, true),
            ("library", InspectorCardWidth.libraryNarrow, false),
            ("wide", InspectorCardWidth.libraryWide, true)
        ]
        for (label, width, capture) in widths {
            for fixture in fixtures {
                let window = try show(fixture.item, store: store, width: width)
                defer { window.close() }
                try assertContained(fixture: fixture, in: window, contentWidth: width)
                if capture, let output {
                    try write(window: window, to: output.appendingPathComponent("\(label)-\(fixture.name).png"))
                }
            }
        }

        guard let sensitive = fixtures.first(where: { $0.name == "sensitive" }) else {
            XCTFail("缺少敏感条目")
            return
        }
        for (label, width) in [("narrow", InspectorCardWidth.quickPaste), ("wide", InspectorCardWidth.libraryWide)] {
            let window = try show(sensitive.item, store: store, width: width)
            defer { window.close() }
            try assertMenuAnchor(for: sensitive.item, in: window)
            if let output {
                try captureMenu(for: sensitive.item, in: window, to: output.appendingPathComponent("\(label)-sensitive-menu.png"))
            }
        }
    }

    private struct Fixture {
        var name: String
        var item: ClipboardItem
    }

    private func makeFixtures(store: ClipFlowStore) throws -> [Fixture] {
        let text = ClipboardClassifier.makeItem(
            text: "把界面说明写清楚，方便以后找回。",
            sourceApp: "备忘录", sourceBundleID: nil, autoProtectSecrets: false, existingItem: nil)
        let secretText = "password: 临时口令 482913"
        let secretRTF = NSAttributedString(string: secretText).rtf(
            from: NSRange(location: 0, length: (secretText as NSString).length),
            documentAttributes: [:])
        let sensitive = ClipboardClassifier.makeItem(
            text: secretText, sourceApp: "1Password", sourceBundleID: nil, autoProtectSecrets: true, existingItem: nil,
            richContent: ClipboardRepresentations.Snapshot(rtfData: secretRTF, htmlData: nil, fileURLs: [], extraTypes: []))
        XCTAssertEqual(sensitive.kind, .secret)
        XCTAssertTrue(PlainTextPaste.hasRichText(sensitive))
        XCTAssertNotEqual(sensitive.privacy, .standard)

        let sample = NSImage(size: NSSize(width: 640, height: 360))
        sample.lockFocus()
        NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        sample.unlockFocus()
        let imageData = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sample.tiffRepresentation))?.representation(using: .png, properties: [:]))
        store.ingestCopiedImage(imageData, size: sample.size, sourceApp: "预览", sourceBundleID: nil)
        let image = try XCTUnwrap(store.items.first(where: \.isImage))

        let table = ClipboardClassifier.makeItem(
            text: "名称\t数量\n苹果\t2\n梨\t5",
            sourceApp: "Microsoft Excel", sourceBundleID: nil, autoProtectSecrets: false, existingItem: nil,
            richContent: ClipboardRepresentations.Snapshot(
                rtfData: nil, htmlData: nil, fileURLs: [],
                extraTypes: [ClipboardPasteboardType(type: "com.microsoft.Excel.xml", data: Data([1]))]))
        XCTAssertTrue(SpreadsheetClipboard.hasOriginalTypes(table))
        XCTAssertTrue(ExcelInsertOffer.shouldOffer(item: table, bundleIDs: ExcelInsertContext.currentBundleIDs()))

        let file = ClipboardClassifier.makeItem(
            text: "季度报表.xlsx", sourceApp: "访达", sourceBundleID: nil, autoProtectSecrets: false, existingItem: nil,
            richContent: ClipboardRepresentations.Snapshot(
                rtfData: nil, htmlData: nil, fileURLs: ["file:///Users/me/季度报表.xlsx"], extraTypes: []))
        XCTAssertFalse(file.fileURLs?.isEmpty ?? true)
        XCTAssertNil(file.primaryURL)

        let link = ClipboardClassifier.makeItem(
            text: "https://github.com/FOREST227/ClipFlow",
            sourceApp: "Safari", sourceBundleID: nil, autoProtectSecrets: false, existingItem: nil)
        XCTAssertEqual(link.kind, .link)
        XCTAssertNotNil(link.primaryURL)

        return [
            Fixture(name: "text", item: text),
            Fixture(name: "sensitive", item: sensitive),
            Fixture(name: "image", item: image),
            Fixture(name: "table", item: table),
            Fixture(name: "file", item: file),
            Fixture(name: "link", item: link)
        ]
    }

    private func show(_ item: ClipboardItem, store: ClipFlowStore, width: CGFloat) throws -> NSWindow {
        let root = LibraryInspectorOverlay(
            item: item, store: store, palette: .resolve(for: .light),
            maxHeight: 460, contentWidth: width, compactShadow: true, onClose: {}
        )
        .padding(24)
        .background(Color(red: 0.90, green: 0.92, blue: 0.94))
        let host = NSHostingController(rootView: root
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .preferredColorScheme(.light))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable]
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: width + 48, height: 640))
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.maxY - 700))
        }
        window.makeKeyAndOrderFront(nil)
        pump(0.35)
        host.view.layoutSubtreeIfNeeded()
        if let card = InspectorViewLocator.view(named: InspectorAnchor.card, in: window) {
            window.setContentSize(NSSize(width: width + 48, height: card.bounds.height + 48))
        }
        pump(0.25)
        host.view.layoutSubtreeIfNeeded()
        return window
    }

    private func assertContained(fixture: Fixture, in window: NSWindow, contentWidth: CGFloat) throws {
        let card = try XCTUnwrap(InspectorViewLocator.view(named: InspectorAnchor.card, in: window), "卡片锚点缺失 \(fixture.name)")
        let actions = try XCTUnwrap(InspectorViewLocator.view(named: InspectorAnchor.actions, in: window))
        let set = actionSet(for: fixture.item)
        var frames: [(InspectorCommand.ID, CGRect)] = []
        for command in set.commands {
            let view = try XCTUnwrap(
                InspectorViewLocator.view(named: InspectorAnchor.action(command.id), in: window),
                "找不到 \(command.id) \(fixture.name)")
            let rect = view.convert(view.bounds, to: card)
            XCTAssertGreaterThanOrEqual(rect.minX, 10, "\(fixture.name) \(command.id) 越过卡片左内边距 \(rect)")
            XCTAssertLessThanOrEqual(rect.maxX, card.bounds.width - 10, "\(fixture.name) \(command.id) 越过卡片右内边距 \(rect) card \(card.bounds)")
            XCTAssertGreaterThanOrEqual(rect.minY, -0.5, "\(fixture.name) \(command.id)")
            XCTAssertLessThanOrEqual(rect.maxY, card.bounds.height + 0.5, "\(fixture.name) \(command.id)")
            frames.append((command.id, topLeft(view, in: actions)))
        }
        let heights = frames.map(\.1.height)
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 1.5, "\(fixture.name) 按钮高度不一致 \(heights)")
        let ordered = frames.sorted { lhs, rhs in
            if abs(lhs.1.midY - rhs.1.midY) > 2 { return lhs.1.midY < rhs.1.midY }
            return lhs.1.minX < rhs.1.minX
        }
        XCTAssertEqual(ordered.map(\.0), set.commands.map(\.id), "\(fixture.name) 动作顺序")
        for pair in ordered.indices.dropFirst() {
            let previous = ordered[pair - 1].1
            let current = ordered[pair].1
            let overlap = previous.intersection(current)
            XCTAssertFalse(overlap.width > 1 && overlap.height > 1, "\(fixture.name) 按钮重叠")
        }
        let limit = InspectorActionMetrics.actionWidth(contentWidth: contentWidth)
        let arranged = InspectorActionArrangement.arrange(
            sizes: frames.map { CGSize(width: $0.1.width, height: $0.1.height) },
            containerWidth: limit,
            iconClusterCount: set.iconClusterCount)
        for (item, frame) in zip(arranged.items, frames.map(\.1)) {
            XCTAssertEqual(item.frame.minX, frame.minX, accuracy: 2, "\(fixture.name)")
            XCTAssertEqual(item.frame.minY, frame.minY, accuracy: 2, "\(fixture.name)")
        }
    }

    private func assertMenuAnchor(for item: ClipboardItem, in window: NSWindow) throws {
        let card = try XCTUnwrap(InspectorViewLocator.view(named: InspectorAnchor.card, in: window))
        let button = try XCTUnwrap(InspectorViewLocator.view(named: InspectorAnchor.action(.more), in: window))
        let buttonScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let cardScreen = window.convertToScreen(card.convert(card.bounds, to: nil))
        let menu = InspectorOverflowMenu.makeMenu(actions: overflowActions(for: item)) { _ in }
        let menuSize = InspectorOverflowMenu.size(of: menu)
        let origin = InspectorMenuAnchor.topLeft(menuSize: menuSize, button: buttonScreen, card: cardScreen)
        let placed = CGRect(x: origin.x, y: origin.y - menuSize.height, width: menuSize.width, height: menuSize.height)
        XCTAssertLessThanOrEqual(placed.maxX, cardScreen.maxX - InspectorActionMetrics.menuInset + 1)
        XCTAssertGreaterThanOrEqual(placed.minX, cardScreen.minX + InspectorActionMetrics.menuInset - 1)
        if menuSize.height + InspectorActionMetrics.menuInset * 2 <= cardScreen.height {
            XCTAssertLessThanOrEqual(placed.maxY, cardScreen.maxY - InspectorActionMetrics.menuInset + 1)
            XCTAssertGreaterThanOrEqual(placed.minY, cardScreen.minY + InspectorActionMetrics.menuInset - 1)
        }
    }

    private func captureMenu(for item: ClipboardItem, in window: NSWindow, to url: URL) throws {
        let before = Self.windowIDs()
        var captured: NSBitmapImageRep?
        var captureError: String?
        let cardView = InspectorViewLocator.view(named: InspectorAnchor.card, in: window)
        let cardScreen = cardView.flatMap { view in
            view.window?.convertToScreen(view.convert(view.bounds, to: nil))
        } ?? .zero
        let savedMouse = NSEvent.mouseLocation
        Self.warpMouse(toAppKit: CGPoint(x: 24, y: 24))
        defer { Self.warpMouse(toAppKit: savedMouse) }
        InspectorOverflowMenu.popUp(actions: overflowActions(for: item), willPresent: { menu in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let info = Self.windowInfo().filter { entry in
                    guard let number = entry[kCGWindowNumber as String] as? UInt32 else { return false }
                    let owned = (entry[kCGWindowOwnerPID as String] as? Int32) == Int32(ProcessInfo.processInfo.processIdentifier)
                    return owned && (number == CGWindowID(window.windowNumber) || !before.contains(number))
                }
                let menus = info.filter { ($0[kCGWindowNumber as String] as? UInt32) != CGWindowID(window.windowNumber) }
                if menus.isEmpty {
                    captureError = "没有出现溢出菜单窗口"
                }
                let cardQuartz = Self.quartzRect(cardScreen)
                for entry in menus {
                    guard let menuBounds = Self.bounds(of: entry) else { continue }
                    let inside = menuBounds.minX >= cardQuartz.minX - 2
                        && menuBounds.maxX <= cardQuartz.maxX + 2
                        && menuBounds.minY >= cardQuartz.minY - 2
                        && menuBounds.maxY <= cardQuartz.maxY + 2
                    if !inside {
                        captureError = "菜单越过卡片 menu \(menuBounds) card \(cardQuartz)"
                    }
                }
                if let image = Self.composite(info, host: CGWindowID(window.windowNumber)) {
                    captured = NSBitmapImageRep(cgImage: image)
                } else if captureError == nil {
                    captureError = "菜单窗口没有生成图像"
                }
                menu.cancelTracking()
            }
        }) { _ in }
        if let captured {
            try XCTUnwrap(captured.representation(using: .png, properties: [:])).write(to: url)
        }
        if let captureError {
            XCTFail(captureError)
        }
    }

    private func actionSet(for item: ClipboardItem) -> InspectorActionSet {
        InspectorCommands.actions(
            pinned: item.pinned,
            canSaveSnippet: SnippetLibrary.canSave(item),
            showsReveal: item.privacy != .standard,
            revealed: false,
            hasRichText: PlainTextPaste.hasRichText(item),
            hasOriginalTypes: SpreadsheetClipboard.hasOriginalTypes(item),
            offersExcelInsert: ExcelInsertOffer.shouldOffer(item: item, bundleIDs: ExcelInsertContext.currentBundleIDs())
        )
    }

    private func overflowActions(for item: ClipboardItem) -> [InspectorOverflowAction] {
        InspectorCommands.overflowActions(
            canOpenURL: item.primaryURL != nil,
            canSaveSnippet: SnippetLibrary.canSave(item),
            hasOriginalTypes: SpreadsheetClipboard.hasOriginalTypes(item),
            offersExcelInsert: ExcelInsertOffer.shouldOffer(item: item, bundleIDs: ExcelInsertContext.currentBundleIDs())
        )
    }

    private func topLeft(_ view: NSView, in container: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: container)
        guard container.isFlipped else {
            return CGRect(x: rect.minX, y: container.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        return rect
    }

    private func write(window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func windowIDs() -> Set<UInt32> {
        Set(windowInfo().compactMap { $0[kCGWindowNumber as String] as? UInt32 })
    }

    private static func windowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private static func bounds(of entry: [String: Any]) -> CGRect? {
        guard let raw = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: raw["X"] ?? 0, y: raw["Y"] ?? 0, width: raw["Width"] ?? 0, height: raw["Height"] ?? 0)
    }

    private static func warpMouse(toAppKit point: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
    }

    private static func quartzRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func composite(_ info: [[String: Any]], host: CGWindowID) -> CGImage? {
        let windows: [(CGWindowID, CGRect)] = info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? UInt32, let bounds = bounds(of: entry), bounds.width > 2 else {
                return nil
            }
            return (number, bounds)
        }.sorted { lhs, rhs in
            if (lhs.0 == host) != (rhs.0 == host) { return lhs.0 == host }
            return lhs.1.width * lhs.1.height > rhs.1.width * rhs.1.height
        }
        guard !windows.isEmpty else { return nil }
        let union = windows.reduce(CGRect.null) { $0.union($1.1) }
        guard union.width > 2, union.height > 2 else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = NSSize(width: union.width * scale, height: union.height * scale)
        guard let context = CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.90, green: 0.92, blue: 0.94, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixels))
        context.interpolationQuality = .high
        for (id, bounds) in windows {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
                continue
            }
            let dest = CGRect(
                x: (bounds.minX - union.minX) * scale,
                y: (union.maxY - bounds.maxY) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale)
            context.draw(image, in: dest)
        }
        return context.makeImage()
    }
}
