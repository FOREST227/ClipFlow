import AppKit
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

    func testSwitchingPagesKeepsUnsavedSettingsAndHistoryFilter() throws {
        let store = try makeStore()
        let navigation = MainWindowNavigation(store: store)
        store.searchText = "project notes"
        store.selectedCategory = .code
        navigation.select(.settings)
        navigation.settingsDraft.excludedAppsText = "com.example.unsaved"
        navigation.select(.history)
        XCTAssertEqual(store.searchText, "project notes")
        XCTAssertEqual(store.selectedCategory, .code)
        navigation.select(.settings)
        XCTAssertEqual(navigation.settingsDraft.excludedAppsText, "com.example.unsaved")
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
        XCTAssertEqual(window.contentLayoutRect.width, 460, accuracy: 0.5)
        window.close()
    }
}
