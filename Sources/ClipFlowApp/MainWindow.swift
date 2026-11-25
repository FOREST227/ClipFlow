import AppKit
import SwiftUI

enum MainWindowPage: String, CaseIterable, Identifiable, ClipFlowTab {
    case settings = "设置"
    case history = "剪贴历史"
    case snippets = "片段"
    var id: Self { self }
    var title: String { rawValue }
    var icon: String {
        switch self {
        case .history: "rectangle.stack"
        case .snippets: "text.quote"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class SettingsDraft: ObservableObject {
    @Published var section: SettingsCategory = .general
    var movesForward = true
    @Published var excludedAppsText: String
    @Published var exclusionError: String?
    /// A lower history limit that is waiting for the inline confirmation.
    @Published var pendingHistoryLimit: Int?

    init(store: ClipFlowStore) {
        excludedAppsText = ExcludedAppRules.normalizedText(store.excludedBundleIDs)
    }

    func requestHistoryLimit(_ limit: Int, in store: ClipFlowStore) {
        let resolved = HistoryRetention.normalized(limit)
        if resolved == store.historyItemLimit {
            pendingHistoryLimit = nil
            return
        }
        let removal = HistoryRetention.removalCount(in: store.items, limit: resolved)
        if HistoryRetention.needsConfirmation(
            currentLimit: store.historyItemLimit,
            proposedLimit: resolved,
            removalCount: removal
        ) {
            pendingHistoryLimit = resolved
            return
        }
        pendingHistoryLimit = nil
        store.applyHistoryItemLimit(resolved)
    }

    func confirmHistoryLimitChange(in store: ClipFlowStore) {
        guard let pendingHistoryLimit else { return }
        self.pendingHistoryLimit = nil
        store.applyHistoryItemLimit(pendingHistoryLimit)
    }

    func cancelHistoryLimitChange() {
        pendingHistoryLimit = nil
    }

    /// Drops a confirmation that would no longer delete anything, and applies that choice.
    func refreshHistoryLimitPrompt(in store: ClipFlowStore) {
        guard let pending = pendingHistoryLimit else { return }
        let removal = HistoryRetention.removalCount(in: store.items, limit: pending)
        guard !HistoryRetention.needsConfirmation(
            currentLimit: store.historyItemLimit,
            proposedLimit: pending,
            removalCount: removal
        ) else { return }
        pendingHistoryLimit = nil
        if pending != store.historyItemLimit {
            store.applyHistoryItemLimit(pending)
        }
    }

    func saveExcludedApps(into store: ClipFlowStore) {
        let parsed = ExcludedAppRules.lines(in: excludedAppsText)
        let invalid = ExcludedAppRules.invalidLines(in: parsed)
        guard invalid.isEmpty else {
            exclusionError = ExcludedAppRules.invalidMessage(invalid)
            return
        }
        store.updateExcludedApps(from: ExcludedAppRules.normalizedText(parsed))
        excludedAppsText = ExcludedAppRules.normalizedText(store.excludedBundleIDs)
        exclusionError = nil
    }

    func resetExcludedApps(in store: ClipFlowStore) {
        store.resetExcludedAppsToDefaults()
        excludedAppsText = ExcludedAppRules.normalizedText(store.excludedBundleIDs)
        exclusionError = nil
    }

    func noteExclusionEdits() {
        guard exclusionError != nil else { return }
        exclusionError = nil
    }
}

@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published private(set) var page: MainWindowPage
    @Published private(set) var loadedPages: Set<MainWindowPage>
    @Published var isEdgeDocked = false
    @Published var onToggleEdgeDock: (() -> Void)?
    let settingsDraft: SettingsDraft
    let searchFocus = LibrarySearchFocusModel()
    /// Used to present the editor on first appearance. Nil in normal use.
    var initialSnippetEditor: SnippetEditorDraft?
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
    /// Sidebar order: history, snippets, then the settings sections.
    var selectedIndex: Int {
        switch page {
        case .history: 0
        case .snippets: 1
        case .settings: 2 + (SettingsCategory.allCases.firstIndex(of: settingsDraft.section) ?? 0)
        }
    }

    func selectSettings(_ category: SettingsCategory) {
        let target = 2 + (SettingsCategory.allCases.firstIndex(of: category) ?? 0)
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
    var controlsFollowSystem = false
    var isPositioningControls = false
    private var undockedFrame: NSRect?
    private(set) var edgePeekPanel: NSPanel?
    static let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
    static let edgePeekVisibleWidth: CGFloat = 24
    static let edgePeekHeight: CGFloat = 136

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
        window.setContentSize(NSSize(width: ClipFlowLayout.libraryWidth, height: ClipFlowLayout.libraryHeight))
        window.contentMinSize = NSSize(width: ClipFlowLayout.libraryMinWidth, height: ClipFlowLayout.libraryMinHeight)
        window.contentMaxSize = NSSize(width: ClipFlowLayout.libraryMaxWidth, height: .greatestFiniteMagnitude)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setFrameAutosaveName("ClipFlowFolioWindow")
        let restored = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(
            width: min(max(restored.width, ClipFlowLayout.libraryMinWidth), ClipFlowLayout.libraryMaxWidth),
            height: max(ClipFlowLayout.libraryMinHeight, restored.height)))
        super.init(window: window)
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        navigation.onToggleEdgeDock = { [weak self] in
            self?.toggleEdgeDock()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(page: MainWindowPage) {
        if navigation.isEdgeDocked {
            setEdgeDocked(false, animated: true)
        }
        navigation.select(page)
        guard let window else { return }
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        scheduleWindowControlLayout()
        guard page == .history else { return }
        // Claim focus after AppKit finishes making the window key.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigation.page == .history else { return }
            self.navigation.searchFocus.request()
        }
    }

    func toggleEdgeDock() {
        setEdgeDocked(!navigation.isEdgeDocked, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func setEdgeDocked(_ docked: Bool, animated: Bool) {
        guard let window, navigation.isEdgeDocked != docked else { return }
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if docked {
            undockedFrame = window.frame
            navigation.isEdgeDocked = true
            let peekY = min(
                max(window.frame.midY - Self.edgePeekHeight / 2, screenFrame.minY + 32),
                screenFrame.maxY - Self.edgePeekHeight - 32
            )
            let peekFrame = NSRect(
                x: screenFrame.maxX - Self.edgePeekVisibleWidth,
                y: peekY,
                width: Self.edgePeekVisibleWidth,
                height: Self.edgePeekHeight
            )
            window.orderOut(nil)
            showEdgePeekPanel(at: peekFrame, animated: animated)
        } else {
            hideEdgePeekPanel()
            navigation.isEdgeDocked = false
            let fallbackOrigin = NSPoint(
                x: max(screenFrame.minX + 24, screenFrame.maxX - window.frame.width - 28),
                y: window.frame.origin.y
            )
            let target = undockedFrame ?? NSRect(origin: fallbackOrigin, size: window.frame.size)
            window.setFrame(target, display: true)
            setTrafficLightsHidden(false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            scheduleWindowControlLayout()
        }
    }

    private func showEdgePeekPanel(at frame: NSRect, animated: Bool) {
        hideEdgePeekPanel()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: ScreenEdgePeekStrip(
                store: store,
                pasteStack: store.pasteStack
            ) { [weak self] in
                self?.setEdgeDocked(false, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        )
        panel.setFrame(frame, display: true)
        if animated { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        edgePeekPanel = panel
    }

    private func hideEdgePeekPanel() {
        guard let panel = edgePeekPanel else { return }
        panel.orderOut(nil)
        panel.close()
        edgePeekPanel = nil
    }

    private func setTrafficLightsHidden(_ hidden: Bool) {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = hidden
        }
    }

    func windowWillClose(_ notification: Notification) {
        store.endShortcutRecording()
        hideEdgePeekPanel()
        navigation.isEdgeDocked = false
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
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                // Concept 2: Protruding Morandi Stationery Spine Index Tabs
                FolioSpineTabsView(store: store, navigation: navigation)
                    .padding(.leading, 6)
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(2)

                // Inner Folio Sheet seamlessly fused with active spine tab
                ZStack {
                    if navigation.loadedPages.contains(.settings) {
                        SettingsView(
                            showsBackground: false,
                            reservesTrafficLights: true,
                            store: store,
                            draft: navigation.settingsDraft,
                            onSelectHistory: { navigation.select(.history) },
                            onToggleEdgeDock: navigation.onToggleEdgeDock
                        )
                        .modifier(PageMotion(isSelected: navigation.page == .settings,
                            hiddenOffset: 10, reduceMotion: reduceMotion))
                    }
                    if navigation.loadedPages.contains(.history) {
                        ContentView(
                            showsBackground: false,
                            showsPermissionOverlay: false,
                            reservesTrafficLights: true,
                            store: store,
                            onToggleEdgeDock: navigation.onToggleEdgeDock
                        )
                        .environment(\.librarySearchFocus, navigation.searchFocus)
                        .modifier(PageMotion(isSelected: navigation.page == .history,
                            hiddenOffset: -10, reduceMotion: reduceMotion))
                    }
                    if navigation.loadedPages.contains(.snippets) {
                        SnippetsView(
                            reservesTrafficLights: true,
                            store: store,
                            initialEditor: navigation.initialSnippetEditor,
                            onToggleEdgeDock: navigation.onToggleEdgeDock
                        )
                        .modifier(PageMotion(isSelected: navigation.page == .snippets,
                            hiddenOffset: 10, reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(FolioTheme.folioPage(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.05), radius: 12, y: 4)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .padding(.trailing, 8)
                .ignoresSafeArea(.container, edges: .top)
                .zIndex(1)
            }
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
        .background(WindowChromeAnchor())
        .frame(minWidth: 0, idealWidth: ClipFlowLayout.libraryWidth,
            maxWidth: ClipFlowLayout.libraryMaxWidth,
            minHeight: ClipFlowLayout.libraryMinHeight - MainWindowController.titlebarHeight)
        .overlay {
            if let report = store.startupPermissionReport {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    StartupPermissionOverlay(report: report, palette: .resolve(for: colorScheme),
                        onDismiss: { store.dismissStartupPermissionReport() },
                        onRefresh: { store.rerunPermissionCheck() },
                        onRequestAccessibility: { store.requestAccessibilityPermissionPrompt() },
                        onOpenAccessibilitySettings: { _ = AccessibilityTrust.openSystemSettings() })
                        .padding(.horizontal, ClipFlowLayout.space24)
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : ClipFlowMotion.fade, value: store.startupPermissionReport != nil)
        .modifier(SensitiveSnippetConfirmation(store: store))
        .environment(\.locale, locale)
    }
}

/// Sleek floating right-edge bookmark ear (`24×136pt`) shown when the Folio window is edge-docked.
private struct ScreenEdgePeekStrip: View {
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var pasteStack: PasteStackState
    let onExpand: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: onExpand) {
                VStack(spacing: 7) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: ClipFlowType.mono, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                    if !pasteStack.queuedIDs.isEmpty {
                        Text("\(pasteStack.queuedIDs.count)")
                            .font(.system(size: ClipFlowType.mono, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 3, height: 32)
                }
                .frame(width: isHovered ? 24 : 20, height: 128)
                .background(
                    FolioSpineTabShape(radius: 9)
                        .fill(FolioTheme.primaryAccent(for: colorScheme))
                )
                .overlay(
                    FolioSpineTabOpenBorder(radius: 9)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .contentShape(FolioSpineTabShape(radius: 9))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                    isHovered = hovering
                }
            }
            .help("点击展开 ClipFlow 活页夹（\(store.items.count) 条）")
            .accessibilityLabel("展开 ClipFlow 活页夹")
        }
        .frame(width: MainWindowController.edgePeekVisibleWidth, height: MainWindowController.edgePeekHeight)
        .background(Color.clear)
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
