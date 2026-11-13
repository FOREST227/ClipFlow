import SwiftUI

struct ContentView: View {
    var showsBackground = true
    var showsPermissionOverlay = true
    @ObservedObject var store: ClipFlowStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isPageEnabled
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }
    @StateObject private var inspector: InspectorPresentation

    init(showsBackground: Bool = true, showsPermissionOverlay: Bool = true,
         store: ClipFlowStore, inspector: InspectorPresentation? = nil) {
        self.showsBackground = showsBackground
        self.showsPermissionOverlay = showsPermissionOverlay
        self.store = store
        _inspector = StateObject(wrappedValue: inspector ??
            InspectorPresentation(driver: AppKitInspectorAnimationDriver()))
    }

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)

        GeometryReader { proxy in
            ZStack {
                if showsBackground {
                    AppBackground(palette: palette)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }

                VStack(spacing: ClipFlowLayout.sectionGap) {
                    VStack(spacing: 10) {
                        HeaderView(store: store, palette: palette)
                        CategoryFilterBar(store: store)
                    }
                    LibraryView(store: store, palette: palette,
                        onInspectFrom: { item, source in toggleLibraryInspector(for: item, source: source) }) { item in
                        toggleLibraryInspector(for: item)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(ClipFlowLayout.pageInset)
                .frame(width: min(1100, proxy.size.width), height: proxy.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: permissionOverlayActive ? ClipFlowMotion.backgroundDefocusRadius : 0)
                .modifier(InspectorBackdropMotion(motion: inspector.motion))
                .disabled(overlayActive)
                .accessibilityHidden(overlayActive)

                if permissionOverlayActive {
                    Color.black.opacity(0.18).ignoresSafeArea().zIndex(9)
                } else if inspector.blocksBackground {
                    InspectorScrim(motion: inspector.motion, opacity: 0.18) {
                        inspector.dismiss(reduceMotion: reduceMotion)
                    }
                    .ignoresSafeArea().zIndex(9)
                }

                if let inspectingItem {
                    let cardWidth = min(620, proxy.size.width - 24)
                    let tallImage = inspectingItem.isImage && LibraryImageShape.resolve(
                        width: inspectingItem.imageWidth, height: inspectingItem.imageHeight) == .portrait
                    LibraryInspectorOverlay(
                        item: inspectingItem,
                        store: store,
                        palette: palette,
                        maxHeight: tallImage ? max(200, proxy.size.height - 32)
                            : min(max(proxy.size.height - 32, 420), 760),
                        contentWidth: cardWidth,
                        onPasteAction: {
                            inspector.dismiss(reduceMotion: reduceMotion) {
                                guard let current = store.item(withID: inspectingItem.id) else { return }
                                ClipFlowRuntime.shared.paste(current)
                            }
                        },
                        sourceRectInWindow: inspector.snapshot.sourceRectInWindow,
                        motion: inspector.motion
                    ) {
                        inspector.dismiss(reduceMotion: reduceMotion)
                    }
                    .frame(width: cardWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .zIndex(10)
                }

                if showsPermissionOverlay, let permissionReport = store.startupPermissionReport {
                    StartupPermissionOverlay(
                        report: permissionReport,
                        palette: palette,
                        onDismiss: {
                            withAnimation(ClipFlowMotion.overlay) {
                                store.dismissStartupPermissionReport()
                            }
                        },
                        onRefresh: {
                            store.rerunPermissionCheck()
                        },
                        onRequestAccessibility: {
                            store.requestAccessibilityPermissionPrompt()
                        },
                        onOpenAccessibilitySettings: {
                            _ = AccessibilityTrust.openSystemSettings()
                        }
                    )
                    .frame(width: min(560, proxy.size.width - 48))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 48)
                    .transition(ClipFlowMotion.overlayTransition)
                    .zIndex(11)
                }
            }
        }
        .background(
            InspectorEscapeHandler(onEscape: {
                guard isPageEnabled, inspector.blocksBackground,
                      store.startupPermissionReport == nil else { return false }
                inspector.dismiss(reduceMotion: reduceMotion)
                return true
            }, onWindowInactive: { inspector.reset() }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .background(
            ListKeyCommandMonitor(queryIsEmpty: store.searchText.isEmpty, onCommand: { handleKeyCommand($0) })
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .onChangeBackward(of: store.items) {
            inspector.invalidateIfMissing(availableIDs: Set(store.items.filter { !$0.isExpired() }.map(\.id)))
        }
        .onChangeBackward(of: isPageEnabled) {
            if !isPageEnabled { inspector.reset() }
        }
        .onChangeBackward(of: store.startupPermissionReport != nil) {
            if store.startupPermissionReport != nil { inspector.reset() }
        }
        .onDisappear { inspector.reset() }
    }

    private var inspectingItem: ClipboardItem? {
        guard let id = inspector.snapshot.itemID else { return nil }
        return store.item(withID: id)
    }

    private var permissionOverlayActive: Bool {
        showsPermissionOverlay && store.startupPermissionReport != nil
    }

    private var overlayActive: Bool {
        inspector.blocksBackground || permissionOverlayActive
    }

    private func handleKeyCommand(_ command: ListKeyCommand) -> Bool {
        // The main window presents the permission report itself, above this page.
        guard isPageEnabled, !overlayActive, store.startupPermissionReport == nil else { return false }
        let items = store.filteredItems
        switch command {
        case .moveUp, .moveDown:
            return store.historySelection.move(by: command == .moveUp ? -1 : 1, in: items.map(\.id)) != nil
        case .activate, .toggleDetails:
            guard let item = items.first(where: { $0.id == store.selectedItemID }) else { return false }
            toggleLibraryInspector(for: item)
            return true
        case .pasteIndex:
            return false
        }
    }

    private func toggleLibraryInspector(for item: ClipboardItem, source: InspectorSourceAnchor? = nil) {
        store.select(item)
        if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
            inspector.dismiss(reduceMotion: reduceMotion)
        } else {
            inspector.open(itemID: item.id, reduceMotion: reduceMotion, source: source)
        }
    }

}
