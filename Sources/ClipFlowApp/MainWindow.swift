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
    @Published var section: SettingsCategory = .general
    var movesForward = true
    @Published var excludedAppsText: String

    init(store: ClipFlowStore) {
        excludedAppsText = store.excludedBundleIDs.joined(separator: "\n")
    }
}

@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published private(set) var page: MainWindowPage
    @Published private(set) var loadedPages: Set<MainWindowPage>
    let settingsDraft: SettingsDraft
    private let store: ClipFlowStore

    init(store: ClipFlowStore, initialPage: MainWindowPage = .history) {
        self.page = initialPage
        self.loadedPages = [initialPage]
        self.store = store
        settingsDraft = SettingsDraft(store: store)
    }

    func select(_ page: MainWindowPage) {
        guard self.page != page else { return }
        if self.page == .settings && page != .settings {
            store.endShortcutRecording()
        }
        if !loadedPages.contains(page) { loadedPages.insert(page) }
        self.page = page
    }
    var selectedIndex: Int {
        page == .history ? SettingsCategory.allCases.count
            : (SettingsCategory.allCases.firstIndex(of: settingsDraft.section) ?? 0)
    }

    func selectSettings(_ category: SettingsCategory) {
        let target = SettingsCategory.allCases.firstIndex(of: category) ?? 0
        guard page != .settings || settingsDraft.section != category else { return }
        settingsDraft.movesForward = target > selectedIndex
        store.endShortcutRecording()
        settingsDraft.section = category
        select(.settings)
    }

}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let navigation: MainWindowNavigation
    private let store: ClipFlowStore

    init(store: ClipFlowStore, locale: Locale, initialPage: MainWindowPage = .history) {
        self.store = store
        navigation = MainWindowNavigation(store: store, initialPage: initialPage)
        let root = MainWindowView(store: store, navigation: navigation, locale: locale)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "ClipFlow 剪流"
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("ClipFlowMainWindow")
        window.setContentSize(NSSize(width: ClipFlowLayout.libraryWidth, height: 780))
        window.contentMinSize = NSSize(width: ClipFlowLayout.libraryWidth, height: 780)
        window.contentMaxSize = NSSize(width: ClipFlowLayout.libraryWidth, height: .greatestFiniteMagnitude)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Reuse the history window position; do not restore a second settings window.
        window.setFrameAutosaveName("ClipFlowLibraryWindow")
        window.setContentSize(NSSize(width: ClipFlowLayout.libraryWidth, height: max(780, window.contentLayoutRect.height)))
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var navigation: MainWindowNavigation
    let locale: Locale

    var body: some View {
        HStack(spacing: 0) {
            MainSidebarView(navigation: navigation, draft: navigation.settingsDraft)
                .padding(.leading, 6)
                .padding(.vertical, 8)
                .ignoresSafeArea(.container, edges: .top)
            ZStack {
                if navigation.loadedPages.contains(.settings) {
                    SettingsView(showsBackground: false, store: store, draft: navigation.settingsDraft)
                        .modifier(PageMotion(isSelected: navigation.page == .settings,
                            hiddenOffset: -12, reduceMotion: reduceMotion))
                }
                if navigation.loadedPages.contains(.history) {
                    ContentView(showsBackground: false, showsPermissionOverlay: false, store: store)
                        .modifier(PageMotion(isSelected: navigation.page == .history,
                            hiddenOffset: 12, reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Do not clip the detail scrim to the safe-area content rectangle:
            // it must extend behind the transparent titlebar above this pane.
        }
        .blur(radius: store.startupPermissionReport != nil ? ClipFlowMotion.backgroundDefocusRadius : 0)
        .allowsHitTesting(store.startupPermissionReport == nil)
        .background {
            GeometryReader { proxy in
                AppBackground(palette: .resolve(for: colorScheme), restrained: true)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
        .frame(width: ClipFlowLayout.libraryWidth)
        .frame(minHeight: 780)
        .overlay {
            if let report = store.startupPermissionReport {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    StartupPermissionOverlay(report: report, palette: .resolve(for: colorScheme),
                        onDismiss: { store.dismissStartupPermissionReport() },
                        onRefresh: { store.rerunPermissionCheck() },
                        onRequestAccessibility: { store.requestAccessibilityPermissionPrompt() })
                        .padding(.horizontal, 24)
                }
            }
        }
        .environment(\.locale, locale)
    }
}

/// Keep page identity (and scroll position) stable while retargeting a short fade.
private struct PageMotion: ViewModifier {
    let isSelected: Bool
    let hiddenOffset: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isSelected ? 1 : 0)
            .offset(y: isSelected || reduceMotion ? 0 : hiddenOffset)
            .allowsHitTesting(isSelected)
            .disabled(!isSelected)
            .accessibilityHidden(!isSelected)
            .animation(reduceMotion ? nil : (isSelected ? ClipFlowMotion.pageSwitch : ClipFlowMotion.pageExit), value: isSelected)
    }
}

private struct MainSidebarView: View {
    @ObservedObject var navigation: MainWindowNavigation
    @ObservedObject var draft: SettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach(SettingsCategory.allCases) { category in
                navigationButton(category.rawValue, icon: category.icon,
                    selected: navigation.page == .settings && draft.section == category) {
                    navigation.selectSettings(category)
                }
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 10)
            navigationButton("剪贴历史", icon: "rectangle.stack", selected: navigation.page == .history) {
                navigation.select(.history)
            }
            Spacer(minLength: 12)
        }
        .padding(8)
        // Keep navigation aligned while the shell has equal top/bottom insets.
        .padding(.top, 30)
        .frame(width: 128)
        .frame(maxHeight: .infinity)
        .background(CleanGlassBackground(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func navigationButton(_ title: String, icon: String, selected: Bool,
        action: @escaping () -> Void) -> some View {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
            .padding(.horizontal, 10).frame(height: 36)
            .background(selected ? ClipCategory.all.tint : .clear,
                in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
