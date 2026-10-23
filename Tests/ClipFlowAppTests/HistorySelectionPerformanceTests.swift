import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class HistorySelectionPerformanceTests: XCTestCase {
    func testSelectionChromeChangesWithoutReplacingContent() throws {
        _ = NSApplication.shared
        let selection = HistorySelection()
        let id = UUID()
        let row = LibraryInteractiveHostingView(frame: NSRect(x: 0, y: 0, width: 400, height: 152))
        row.update(rootView: AnyView(Text("Stable card content")),
            selectionView: AnyView(LibrarySelectionChrome(itemID: id, selection: selection,
                tint: ClipCategory.all.tint, palette: .resolve(for: .light))),
            onSelect: {}, onInspect: {})
        let window = NSWindow(contentRect: row.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = row
        window.orderFront(nil)
        defer { window.close() }
        func rendered() throws -> Data {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            row.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let before = try rendered()
        let revision = row.contentRevision
        selection.itemID = id
        let selected = try rendered()
        XCTAssertNotEqual(before, selected, "The isolated highlight must actually render")
        selection.itemID = UUID()
        XCTAssertEqual(try rendered(), before, "Deselecting must restore the original appearance")
        XCTAssertEqual(row.contentRevision, revision)
    }

    func testMixedHistoryClicksDoNotRebuildCardContent() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HistoryPerformance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800,
            pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for index in 0..<80 {
            if index % 2 == 0 {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(index) / 80, green: 0.5, blue: 0.5, alpha: 1), atX: 0, y: 0)
                store.ingestCopiedImage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    size: CGSize(width: 800, height: 1000), sourceApp: "Test", sourceBundleID: nil)
            } else {
                store.ingestCopiedText("Mixed note \(index)", sourceApp: "Test", sourceBundleID: nil)
            }
        }
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func rows(_ view: NSView) -> [LibraryInteractiveHostingView] {
            (view as? LibraryInteractiveHostingView).map { [$0] } ?? view.subviews.flatMap(rows)
        }
        let all = rows(try XCTUnwrap(window.contentView))
        let visible = all.filter { $0.visibleRect.height > 60 }
        XCTAssertGreaterThanOrEqual(visible.count, 2)
        let before = all.reduce(0) { $0 + $1.contentRevision }
        let initialSelection = store.selectedItemID
        let start = Date()
        for index in 0..<20 {
            let row = visible[index % 2]
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
                modifierFlags: [], timestamp: Double(index), windowNumber: window.windowNumber,
                context: nil, eventNumber: index, clickCount: 1, pressure: 1))
            row.mouseDown(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let updates = all.reduce(0) { $0 + $1.contentRevision } - before
        print("Mixed history 20 clicks: \(Date().timeIntervalSince(start))s, content replacements: \(updates)")
        XCTAssertNotEqual(initialSelection, store.selectedItemID)
        XCTAssertEqual(updates, 0, "Selection must not replace hosted image/text content or invalidate its layout")
    }
}
