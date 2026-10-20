import AppKit
import SwiftUI

enum MainWindowPage: String, CaseIterable, Identifiable, ClipFlowTab {
    case settings = "设置"
    case history = "剪贴历史"
    var id: Self { self }
    var title: String { rawValue }
    var icon: String { self == .history ? "rectangle.stack" : "gearshape" }
}

@MainActor
final class SettingsDraft: ObservableObject {
    @Published var excludedAppsText: String
    @Published var section: SettingsSection = .general

    init(store: ClipFlowStore) {
        excludedAppsText = store.excludedBundleIDs.joined(separator: "\n")
    }
}

@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published private(set) var page: MainWindowPage = .history
    let settingsDraft: SettingsDraft
    private let store: ClipFlowStore

    init(store: ClipFlowStore) {
        self.store = store
        settingsDraft = SettingsDraft(store: store)
    }

    func select(_ page: MainWindowPage) {
        if self.page == .settings && page != .settings {
            store.endShortcutRecording()
        }
        self.page = page
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let navigation: MainWindowNavigation
    private let store: ClipFlowStore

    init(store: ClipFlowStore, locale: Locale) {
        self.store = store
        navigation = MainWindowNavigation(store: store)
        let root = MainWindowView(store: store, navigation: navigation, locale: locale)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "ClipFlow 剪流"
        window.identifier = NSUserInterfaceItemIdentifier("ClipFlowMainWindow")
        window.setContentSize(NSSize(width: ClipFlowLayout.libraryWidth, height: 780))
        window.contentMinSize = NSSize(width: ClipFlowLayout.libraryWidth, height: 660)
        window.contentMaxSize = NSSize(width: ClipFlowLayout.libraryWidth, height: .greatestFiniteMagnitude)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Reuse the history window position; do not restore a second settings window.
        window.setFrameAutosaveName("ClipFlowLibraryWindow")
        window.setContentSize(NSSize(width: ClipFlowLayout.libraryWidth, height: max(660, window.contentLayoutRect.height)))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(page: MainWindowPage) {
        navigation.select(page)
        guard let window else { return }
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        store.endShortcutRecording()
        window?.orderOut(nil)
    }
}

private struct MainWindowView: View {
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var navigation: MainWindowNavigation
    let locale: Locale

    var body: some View {
        VStack(spacing: 0) {
            ClipFlowTabBar(
                options: MainWindowPage.allCases,
                selection: Binding(get: { navigation.page }, set: { navigation.select($0) }),
                accessibilityTitle: "窗口页面"
            )
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(.bar)

            Divider()
            Group {
                switch navigation.page {
                case .history:
                    ContentView(store: store)
                case .settings:
                    SettingsView(store: store, draft: navigation.settingsDraft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: ClipFlowLayout.libraryWidth)
        .frame(minHeight: 660)
        .environment(\.locale, locale)
    }
}
