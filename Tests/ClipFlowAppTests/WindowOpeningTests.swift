import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class WindowOpeningTests: XCTestCase {
    func testQuickPasteUsesActivatingWindowForTrackpadGestures() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "QuickPasteWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let controller = QuickPastePanelController(store: store, onPaste: { _ in }, onOpenLibrary: {})
        controller.show(anchorAt: NSPoint(x: 400, y: 400), preferredTarget: nil)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? QuickPastePanel }.first { $0.isVisible })
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertNotNil(panel.contentView)
    }

    func testOpeningOnlyBuildsRequestedPageAndVisibleHistoryRows() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WindowOpening.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        for index in 0..<80 {
            store.ingestCopiedText("Opening test \(index)", sourceApp: "Test", sourceBundleID: nil)
        }
        func rows(_ view: NSView) -> [LibraryInteractiveHostingView] {
            (view as? LibraryInteractiveHostingView).map { [$0] } ?? view.subviews.flatMap(rows)
        }
        let start = Date()
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"), initialPage: .settings)
        controller.navigation.select(.settings)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let root = try XCTUnwrap(window.contentView)
        print("Settings open: \(Date().timeIntervalSince(start))s, history hosts: \(rows(root).count)")
        XCTAssertEqual(rows(root).count, 0, "Settings must not construct hidden history cards")
        let historyStart = Date()
        controller.show(page: .history)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        print("History open: \(Date().timeIntervalSince(historyStart))s, hosts: \(rows(root).count)")
        XCTAssertGreaterThan(rows(root).count, 0)
        XCTAssertLessThan(rows(root).count, 30, "Opening must not construct all 80 hosted cards")
        let contentController = window.contentViewController
        window.orderOut(nil)
        let reopenStart = Date()
        controller.show(page: .history)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(window.contentViewController === contentController)
        print("History reopen: \(Date().timeIntervalSince(reopenStart))s")
        let coldStart = Date()
        let history = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let historyWindow = try XCTUnwrap(history.window)
        defer { historyWindow.close() }
        historyWindow.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(rows(try XCTUnwrap(historyWindow.contentView)).count, 30)
        print("History first open: \(Date().timeIntervalSince(coldStart))s")
    }
}
