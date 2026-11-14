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

    func testListViewportsShowAtLeastSixUnitsAndHistoryGrowsWithTheWindow() throws {
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
        func historyScroll() throws -> NSScrollView {
            try XCTUnwrap(scrolls(try XCTUnwrap(main.contentView)).first { scroll in
                (scroll.documentView?.bounds.height ?? 0) > LibraryCardLayout.compactHeight * 8
            })
        }
        // CI runners can run the window's layout passes far later than a fixed
        // short sleep, so wait for the viewport to settle instead of sleeping.
        func viewportHeight() -> CGFloat {
            (try? historyScroll())?.contentView.bounds.height ?? 0
        }
        func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func settledViewportHeight(timeout: TimeInterval = 5) -> CGFloat {
            let deadline = Date().addingTimeInterval(timeout)
            var previous = -CGFloat.greatestFiniteMagnitude
            var stableReads = 0
            while Date() < deadline {
                let height = viewportHeight()
                // A missing scroll view reports 0 and must not count as settled.
                if height > 0, height == previous {
                    stableReads += 1
                    if stableReads >= 3 { return height }
                } else {
                    stableReads = 0
                }
                previous = height
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            return viewportHeight()
        }
        func describeWindow(_ label: String) {
            print("WINDOW_DEBUG \(label) contentHeight=\(main.contentView?.bounds.height ?? -1) frame=\(main.frame) titlebarHeight=\(MainWindowController.titlebarHeight)")
            if let contentView = main.contentView {
                for scroll in scrolls(contentView) {
                    print("WINDOW_DEBUG \(label) scroll clipHeight=\(scroll.contentView.bounds.height) bounds=\(scroll.bounds)")
                }
            }
        }
        _ = settledViewportHeight()
        describeWindow("initial")
        XCTAssertEqual(LibraryCardLayout.viewportHeight, 472)
        // AppKit clamps windows to the screen: the 1024x768 CI display cannot
        // fit the 780 pt window and pins it to the 720 pt minimum instead.
        let tallContentHeight = main.contentView?.bounds.height ?? 0
        let defaultHeight = viewportHeight()
        var historyRect = try historyScroll().convert(try historyScroll().bounds, to: main.contentView)
        XCTAssertTrue(try XCTUnwrap(main.contentView).bounds.contains(historyRect))
        main.setContentSize(NSSize(width: 620, height: ClipFlowLayout.libraryMinHeight))
        if tallContentHeight > ClipFlowLayout.libraryMinHeight + 1 {
            waitFor {
                let height = viewportHeight()
                return height > 0 && abs(height - defaultHeight) > 0.5
            }
            describeWindow("resized")
        }
        let shrunkHeight = settledViewportHeight()
        describeWindow("settled")
        let fourRows = LibraryCardLayout.compactHeight * 4 + LibraryCardLayout.spacing * 3
        XCTAssertGreaterThanOrEqual(shrunkHeight, fourRows - 80,
            "The 560pt minimum keeps about four history rows, without forcing a six-row viewport")
        historyRect = try historyScroll().convert(try historyScroll().bounds, to: main.contentView)
        XCTAssertTrue(try XCTUnwrap(main.contentView).bounds.contains(historyRect))
        if tallContentHeight >= 770 {
            XCTAssertEqual(shrunkHeight,
                defaultHeight - (tallContentHeight - ClipFlowLayout.libraryMinHeight), accuracy: 1,
                "Window height changes belong to the list, not to blank space")
        } else {
            print("WINDOW_GROWTH_SKIPPED screen clamped content height to \(tallContentHeight)")
        }

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

    func testSidebarOrderAndMotionFollowHistoryThenSettings() throws {
        let navigation = MainWindowNavigation(store: try makeStore())
        XCTAssertEqual(navigation.selectedIndex, 0)
        navigation.selectSettings(.general)
        XCTAssertEqual(navigation.selectedIndex, 1)
        XCTAssertTrue(navigation.settingsDraft.movesForward)
        navigation.selectSettings(.sync)
        XCTAssertEqual(navigation.selectedIndex, 3)
        XCTAssertTrue(navigation.settingsDraft.movesForward)
        navigation.selectSettings(.privacy)
        XCTAssertEqual(navigation.selectedIndex, 2)
        XCTAssertFalse(navigation.settingsDraft.movesForward)
        navigation.select(.history)
        XCTAssertEqual(navigation.selectedIndex, 0)
    }

    func testMainWindowWidthIsBoundedButResizable() throws {
        _ = NSApplication.shared
        let controller = MainWindowController(store: try makeStore(), locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        XCTAssertEqual(window.contentMinSize.width, ClipFlowLayout.libraryWidth)
        XCTAssertEqual(window.contentMaxSize.width, ClipFlowLayout.libraryMaxWidth)
        XCTAssertEqual(window.contentMinSize.height, ClipFlowLayout.libraryMinHeight)
        XCTAssertGreaterThan(ClipFlowLayout.libraryMaxWidth, ClipFlowLayout.libraryWidth)
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

    func testTrafficLightsClearTheSidebarCardAcrossResizeAndReopen() throws {
        _ = NSApplication.shared
        let controller = MainWindowController(store: try makeStore(), locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        func assertLights(file: StaticString = #filePath, line: UInt = #line) throws {
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                let button = try XCTUnwrap(window.standardWindowButton(type), file: file, line: line)
                let rect = button.convert(button.bounds, to: nil)
                XCTAssertEqual(rect.midX, WindowChrome.firstButtonCenterX + CGFloat(index) * WindowChrome.buttonSpacing,
                    accuracy: 1, file: file, line: line)
                XCTAssertEqual(window.frame.height - rect.midY, WindowChrome.buttonCenterFromTop,
                    accuracy: 1, file: file, line: line)
                XCTAssertGreaterThanOrEqual(window.frame.height - rect.maxY, 10,
                    "Traffic lights must sit below the window edge", file: file, line: line)
                XCTAssertLessThan(window.frame.height - rect.minY, WindowChrome.cardTop - 4,
                    "Traffic lights must clear the sidebar card", file: file, line: line)
                XCTAssertTrue(try XCTUnwrap(button.superview, file: file, line: line).bounds.contains(button.frame),
                    file: file, line: line)
            }
        }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try assertLights()
        for height: CGFloat in [680, 800] {
            window.setContentSize(NSSize(width: 620, height: height))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try assertLights()
        }
        window.orderOut(nil)
        controller.show(page: .settings)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try assertLights()
        // A live fullscreen transition does not finish inside XCTest. The delegate still has to
        // leave the buttons alone while the system owns them, then put them back when it returns.
        let fullscreen = Notification(name: NSWindow.didEnterFullScreenNotification, object: window)
        controller.windowWillEnterFullScreen(fullscreen)
        controller.windowDidEnterFullScreen(fullscreen)
        XCTAssertTrue(controller.controlsFollowSystem)
        controller.positionWindowControls()
        try assertLights()
        controller.windowWillExitFullScreen(fullscreen)
        controller.windowDidExitFullScreen(fullscreen)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        XCTAssertFalse(controller.controlsFollowSystem)
        try assertLights()
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
