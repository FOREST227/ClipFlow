import SwiftUI

struct ContentView: View {
    var showsBackground = true
    var showsPermissionOverlay = true
    var reservesTrafficLights = false
    @ObservedObject var store: ClipFlowStore
    var onToggleEdgeDock: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isPageEnabled
    @Environment(\.librarySearchFocus) private var searchFocus
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }
    @StateObject private var inspector: InspectorPresentation
    @ViewState private var deckExtraction = CardExtractionModel()

    init(
        showsBackground: Bool = true,
        showsPermissionOverlay: Bool = true,
        reservesTrafficLights: Bool = false,
        store: ClipFlowStore,
        inspector: InspectorPresentation? = nil,
        onToggleEdgeDock: (() -> Void)? = nil
    ) {
        self.showsBackground = showsBackground
        self.showsPermissionOverlay = showsPermissionOverlay
        self.reservesTrafficLights = reservesTrafficLights
        self.store = store
        self.onToggleEdgeDock = onToggleEdgeDock
        _inspector = StateObject(wrappedValue: inspector ??
            InspectorPresentation(driver: AppKitInspectorAnimationDriver()))
    }

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)

        GeometryReader { proxy in
            ZStack {
                if showsBackground {
                    FolioTheme.folioPage(for: colorScheme)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }

                VStack(spacing: 10) {
                    FolioHeaderBar(
                        store: store,
                        palette: palette,
                        searchFocus: searchFocus,
                        reservesTrafficLights: reservesTrafficLights,
                        showsInlineCategoryStrip: !reservesTrafficLights,
                        onToggleEdgeDock: onToggleEdgeDock
                    )

                    PasteStackTrayView(
                        store: store,
                        pasteStack: store.pasteStack,
                        onPasteNext: { ClipFlowRuntime.shared.pasteNextFromStack() }
                    )

                    LibraryView(
                        store: store,
                        palette: palette,
                        deckExtraction: deckExtraction,
                        onInspectFrom: { item, source in toggleLibraryInspector(for: item, source: source) },
                        onInspectItem: { item in toggleLibraryInspector(for: item) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 16)
                .padding(.top, reservesTrafficLights ? 8 : 14)
                .padding(.bottom, 14)
                .frame(width: min(1100, proxy.size.width), height: proxy.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .scaleEffect(!reduceMotion && store.libraryViewMode == .deck && inspector.blocksBackground ? 0.975 : 1.0)
                .animation(reduceMotion ? nil : ClipFlowMotion.selection, value: inspector.blocksBackground)
                .blur(radius: permissionOverlayActive ? ClipFlowMotion.backgroundDefocusRadius : 0)
                .disabled(overlayActive)
                .allowsHitTesting(!overlayActive)
                .accessibilityHidden(overlayActive)

                if permissionOverlayActive {
                    Color.black.opacity(0.18).ignoresSafeArea().zIndex(9)
                } else if inspector.blocksBackground {
                    InspectorScrim(motion: inspector.motion, opacity: 1) {
                        inspector.dismiss(reduceMotion: reduceMotion)
                    }
                    .ignoresSafeArea().zIndex(9)
                }

                if let inspectingItem {
                    let topInset: CGFloat = reservesTrafficLights ? 38 : 16
                    let bottomInset: CGFloat = 14
                    let cardWidth = max(320, min(proxy.size.width - 24, 920))
                    let cardMaxHeight = max(240, proxy.size.height - topInset - bottomInset)
                    LibraryInspectorOverlay(
                        item: inspectingItem,
                        store: store,
                        palette: palette,
                        maxHeight: cardMaxHeight,
                        contentWidth: cardWidth,
                        useBinderExtractMotion: store.libraryViewMode == .deck,
                        onPasteAction: {
                            inspector.dismiss(reduceMotion: reduceMotion) {
                                guard let current = store.item(withID: inspectingItem.id) else { return }
                                ClipFlowRuntime.shared.paste(current)
                            }
                        },
                        onPastePlainAction: {
                            inspector.dismiss(reduceMotion: reduceMotion) {
                                guard let current = store.item(withID: inspectingItem.id) else { return }
                                ClipFlowRuntime.shared.pastePlainText(current)
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
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                    .zIndex(10)
                }

                if showsPermissionOverlay, let permissionReport = store.startupPermissionReport {
                    StartupPermissionOverlay(
                        report: permissionReport,
                        palette: palette,
                        onDismiss: {
                            withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
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
                    .transition(.opacity)
                    .zIndex(11)
                }
            }
            .animation(reduceMotion ? nil : ClipFlowMotion.fade, value: permissionOverlayActive)
        }
        .background(
            InspectorEscapeHandler(onEscape: {
                guard isPageEnabled, store.startupPermissionReport == nil else { return false }
                let window = LibrarySearchFocus.eventWindow
                if LibrarySearchFocus.isComposing(in: window) {
                    return false
                }
                // A committed query leaves on the first Escape. The next one reaches the deck extraction or inspector.
                if LibrarySearchFocus.escapeClearsQuery(
                    query: store.searchText,
                    fieldFocused: LibrarySearchFocus.searchFieldIsFirstResponder(in: window),
                    isComposing: LibrarySearchFocus.isComposing(in: window)
                ) {
                    store.searchText = ""
                    return true
                }
                if store.libraryViewMode == .deck && deckExtraction.isActive {
                    deckExtraction.collapse(reduceMotion: reduceMotion)
                    return true
                }
                guard inspector.blocksBackground else { return false }
                inspector.dismiss(reduceMotion: reduceMotion)
                return true
            }, onWindowInactive: {
                inspector.reset()
                deckExtraction.reset()
            }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .background(
            ListKeyCommandMonitor(queryIsEmpty: store.searchText.isEmpty, onCommand: { handleKeyCommand($0) })
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .onChangeBackward(of: store.items) {
            inspector.invalidateIfMissing(availableIDs: Set(store.items.filter { !$0.isExpired() }.map(\.id)))
        }
        .onChangeBackward(of: isPageEnabled) {
            if !isPageEnabled {
                inspector.reset()
                deckExtraction.reset()
            }
        }
        .onChangeBackward(of: store.startupPermissionReport != nil) {
            if store.startupPermissionReport != nil {
                inspector.reset()
                deckExtraction.reset()
            }
        }
        .onDisappear {
            inspector.reset()
            deckExtraction.reset()
        }
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
        guard isPageEnabled, !overlayActive, store.startupPermissionReport == nil else { return false }
        let items = store.filteredItems
        switch command {
        case .moveUp, .moveDown:
            if store.libraryViewMode == .deck && deckExtraction.isActive {
                deckExtraction.collapse(reduceMotion: reduceMotion)
            }
            return store.historySelection.move(by: command == .moveUp ? -1 : 1, in: items.map(\.id)) != nil
        case .activate:
            guard let item = items.first(where: { $0.id == store.selectedItemID }) ?? items.first else { return false }
            if store.libraryViewMode == .deck && !LibrarySearchFocus.searchFieldIsFirstResponder(in: LibrarySearchFocus.eventWindow) {
                ClipFlowRuntime.shared.paste(item)
            } else {
                toggleLibraryInspector(for: item)
            }
            return true
        case .toggleDetails:
            guard let item = items.first(where: { $0.id == store.selectedItemID }) else { return false }
            if store.libraryViewMode == .deck {
                deckExtraction.toggle(itemID: item.id, reduceMotion: reduceMotion)
            } else {
                toggleLibraryInspector(for: item)
            }
            return true
        case .pastePlain:
            return false
        case .pasteIndex(let index):
            guard let item = HistoryPasteRouting.item(at: index, in: items) else { return false }
            store.select(item)
            ClipFlowRuntime.shared.paste(item)
            return true
        case .showHistory, .showSnippets, .reorder:
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
