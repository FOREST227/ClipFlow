import AppKit
import SwiftUI
import XCTest
import Combine
@testable import ClipFlowApp

@MainActor
final class MainWindowTests: XCTestCase {
    private func makeStore() throws -> ClipFlowStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipFlowWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return ClipFlowStore(storageDirectory: directory, defaults: defaults)
    }

    func testSelectingScrolledHistoryRowKeepsViewport() throws {
        _ = NSApplication.shared
        let store = try makeStore()
        for index in 0..<40 {
            store.ingestCopiedText(index % 2 == 0 ? "Note \(index)" : "func example\(index)() {\n    return true\n}",
                sourceApp: "Test", sourceBundleID: nil)
        }
        XCTAssertTrue(store.items.contains { $0.kind == .code })
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentViewController)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 486, height: 680))
        window.orderFront(nil)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        settle()
        let scroll = try XCTUnwrap(descendants(host.view, of: NSScrollView.self).first {
            !descendants($0, of: LibraryInteractiveHostingView.self).isEmpty
        })
        for offset: CGFloat in [400, 1200, 800] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
            let before = scroll.contentView.bounds.minY
            let row = try XCTUnwrap(descendants(host.view, of: LibraryInteractiveHostingView.self).first {
                let rect = $0.convert($0.bounds, to: scroll.contentView)
                return scroll.contentView.bounds.insetBy(dx: 0, dy: 10).contains(rect)
            })
            let previous = store.selectedItemID
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            row.mouseDown(with: event)
            settle()
            XCTAssertNotEqual(store.selectedItemID, previous)
            XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 1,
                "Selection must not move a scrolled history viewport")
        }
    }

    func testBothLiveListViewportsHaveSixUnits() throws {
        _ = NSApplication.shared
        let store = try makeStore()
        for index in 0..<12 {
            store.ingestCopiedText("Row \(index)", sourceApp: "Test", sourceBundleID: nil)
        }
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let main = try XCTUnwrap(controller.window)
        main.setContentSize(NSSize(width: 620, height: 780))
        main.orderFront(nil)
        defer { main.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let historyScroll = try XCTUnwrap(scrolls(try XCTUnwrap(main.contentView)).first {
            abs($0.contentView.bounds.height - LibraryCardLayout.viewportHeight) < 1
        })
        XCTAssertEqual(historyScroll.contentView.bounds.height, 472, accuracy: 0.5)
        let historyRect = historyScroll.convert(historyScroll.bounds, to: main.contentView)
        XCTAssertTrue(try XCTUnwrap(main.contentView).bounds.contains(historyRect))

        let host = NSHostingController(rootView: QuickPastePanelView(store: store,
            preferredTargetName: nil, onPaste: { _ in }, onOpenLibrary: {}, onClose: {}))
        let panel = NSWindow(contentViewController: host)
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 360, height: 588))
        panel.orderFront(nil)
        defer { panel.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let quickScroll = try XCTUnwrap(scrolls(host.view).first)
        XCTAssertEqual(quickScroll.contentView.bounds.height, 424, accuracy: 0.5)
        XCTAssertTrue(host.view.bounds.contains(quickScroll.convert(quickScroll.bounds, to: host.view)))
        XCTAssertLessThanOrEqual(host.view.fittingSize.height, 588)
    }

    func testHistorySelectionDoesNotInvalidateWholeStore() throws {
        _ = NSApplication.shared
        let store = try makeStore()
        for index in 0..<80 {
            store.ingestCopiedText("Performance note \(index)", sourceApp: "Test", sourceBundleID: nil)
        }
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var broadcasts = 0
        let observation = store.objectWillChange.sink { broadcasts += 1 }
        let items = store.filteredItems
        let start = Date()
        for index in 0..<20 {
            store.select(items[index % 6])
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        print("History 20 selections: \(Date().timeIntervalSince(start))s, global broadcasts: \(broadcasts)")
        XCTAssertEqual(broadcasts, 0, "Selection must not invalidate settings, filters and every card")
        XCTAssertEqual(store.selectedItemID, items[19 % 6].id)
        withExtendedLifetime(observation) {}
    }

    func testSwitchingPagesKeepsUnsavedSettingsAndHistoryFilter() throws {
        let store = try makeStore()
        let navigation = MainWindowNavigation(store: store)
        store.searchText = "project notes"
        store.selectedCategory = .code
        navigation.select(.settings)
        navigation.settingsDraft.excludedAppsText = "com.example.unsaved"
        navigation.settingsDraft.section = .privacy
        navigation.select(.history)
        XCTAssertEqual(store.searchText, "project notes")
        XCTAssertEqual(store.selectedCategory, .code)
        navigation.select(.settings)
        XCTAssertEqual(navigation.settingsDraft.excludedAppsText, "com.example.unsaved")
        XCTAssertEqual(navigation.settingsDraft.section, .privacy)
        XCTAssertFalse(store.excludedBundleIDs.contains("com.example.unsaved"))
    }

    func testSelectingCurrentPageDoesNotRepublishOrInterruptRecording() throws {
        let store = try makeStore()
        let navigation = MainWindowNavigation(store: store)
        navigation.select(.settings)
        store.registerShortcut = { _ in nil }
        store.suspendShortcut = {}
        XCTAssertTrue(store.beginShortcutRecording())
        var updates = 0
        let observation = navigation.$page.dropFirst().sink { _ in updates += 1 }
        navigation.select(.settings)
        XCTAssertEqual(updates, 0)
        XCTAssertTrue(store.isRecordingShortcut)
        navigation.select(.history)
        XCTAssertEqual(updates, 1)
        XCTAssertFalse(store.isRecordingShortcut)
        withExtendedLifetime(observation) {}
    }

    func testSidebarSettingsSelectionPreservesDraftAndEndsRecording() throws {
        let store = try makeStore()
        let navigation = MainWindowNavigation(store: store)
        navigation.settingsDraft.excludedAppsText = "com.example.draft"
        navigation.selectSettings(.general)
        store.registerShortcut = { _ in nil }
        store.suspendShortcut = {}
        XCTAssertTrue(store.beginShortcutRecording())
        navigation.selectSettings(.privacy)
        XCTAssertEqual(navigation.page, .settings)
        XCTAssertEqual(navigation.settingsDraft.section, .privacy)
        XCTAssertFalse(store.isRecordingShortcut)
        navigation.select(.history)
        navigation.select(.settings)
        XCTAssertEqual(navigation.settingsDraft.section, .privacy)
        XCTAssertEqual(navigation.settingsDraft.excludedAppsText, "com.example.draft")
    }

    func testLeavingSettingsRestoresSuspendedShortcut() throws {
        let store = try makeStore()
        let navigation = MainWindowNavigation(store: store)
        var active: ClipFlowShortcut? = .default
        store.registerShortcut = { active = $0; return nil }
        store.suspendShortcut = { active = nil }
        navigation.select(.settings)
        XCTAssertTrue(store.beginShortcutRecording())
        XCTAssertNil(active)
        navigation.select(.history)
        XCTAssertFalse(store.isRecordingShortcut)
        XCTAssertEqual(active, .default)
    }

    func testSidebarOrderAndMotionFollowSettingsThenHistory() throws {
        let navigation = MainWindowNavigation(store: try makeStore())
        XCTAssertEqual(navigation.selectedIndex, 3)
        navigation.selectSettings(.general)
        XCTAssertEqual(navigation.selectedIndex, 0)
        XCTAssertFalse(navigation.settingsDraft.movesForward)
        navigation.selectSettings(.sync)
        XCTAssertEqual(navigation.selectedIndex, 2)
        XCTAssertTrue(navigation.settingsDraft.movesForward)
        navigation.selectSettings(.privacy)
        XCTAssertEqual(navigation.selectedIndex, 1)
        XCTAssertFalse(navigation.settingsDraft.movesForward)
        navigation.select(.history)
        XCTAssertEqual(navigation.selectedIndex, 3)
    }

    func testSharedDetailFitsQuickPasteWidth() throws {
        let store = try makeStore()
        let item = ClipboardClassifier.makeItem(text: String(repeating: "A long link description ", count: 60),
            sourceApp: "Browser", sourceBundleID: "com.example.browser", autoProtectSecrets: false, existingItem: nil)
        let host = NSHostingView(rootView: LibraryInspectorOverlay(item: item, store: store,
            palette: .resolve(for: .light), maxHeight: 464, contentWidth: 304,
            onPasteAction: {}, onClose: {}).frame(width: 304))
        XCTAssertLessThanOrEqual(host.fittingSize.width, 304)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 464)
    }

    func testShortItemDetailDoesNotFillTheWholeWindow() throws {
        let store = try makeStore()
        let item = ClipboardClassifier.makeItem(text: "A short note", sourceApp: "Notes",
            sourceBundleID: "com.example.notes", autoProtectSecrets: false, existingItem: nil)
        let host = NSHostingView(rootView: LibraryInspectorOverlay(item: item, store: store,
            palette: .resolve(for: .light), maxHeight: 660, onClose: {}).frame(width: 438))
        XCTAssertLessThan(host.fittingSize.height, 360)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 438)
    }

    func testSettingsFitsBesideSharedSidebar() throws {
        let store = try makeStore()
        let host = NSHostingView(rootView: SettingsView(showsBackground: false,
            store: store, draft: SettingsDraft(store: store)))
        host.setFrameSize(NSSize(width: 486, height: 680))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 486,
            "The settings pane must not reserve the full window width or a nested sidebar")
    }

    func testTrafficLightsSitInsideSidebarHeaderAfterResize() throws {
        _ = NSApplication.shared
        let controller = MainWindowController(store: try makeStore(), locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        for height: CGFloat in [680, 800] {
            window.setContentSize(NSSize(width: 620, height: height))
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                let rect = button.convert(button.bounds, to: nil)
                XCTAssertEqual(rect.midX, 26 + CGFloat(index) * 20, accuracy: 1)
                XCTAssertEqual(window.frame.height - rect.midY, 26, accuracy: 1)
                XCTAssertTrue(try XCTUnwrap(button.superview).bounds.contains(button.frame))
            }
        }
    }

    func testBothPagesUseTheSameWindowAndHostingController() throws {
        _ = NSApplication.shared
        let controller = MainWindowController(store: try makeStore(), locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        let content = window.contentViewController
        controller.navigation.select(.history)
        controller.navigation.select(.settings)
        controller.navigation.select(.history)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(controller.window?.contentViewController === content)
        XCTAssertEqual(window.contentLayoutRect.width, 620, accuracy: 0.5)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        window.close()
    }
}
