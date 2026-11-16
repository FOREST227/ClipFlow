import SwiftUI

struct QuickPastePanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipFlowStore
    let preferredTargetName: String?
    let onPaste: (ClipboardItem) -> Void
    let onPastePlain: (ClipboardItem) -> Void
    let onOpenLibrary: () -> Void
    let onClose: () -> Void
    var onPasteSnippet: ((SavedSnippet) -> Void)?
    var onPasteSnippetPlain: ((SavedSnippet) -> Void)?

    @ViewState private var query = ""
    @ViewState private var scope: QuickPasteScope
    // Keep selection independent of the parent view's layout/scroll identity.
    @ViewState private var selection = HistorySelection()
    @ViewState private var listProxy = QuickPasteListProxy()
    @StateObject private var inspector: InspectorPresentation
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }

    init(store: ClipFlowStore, preferredTargetName: String?, onPaste: @escaping (ClipboardItem) -> Void,
         onPastePlain: @escaping (ClipboardItem) -> Void = { _ in },
         onOpenLibrary: @escaping () -> Void, onClose: @escaping () -> Void,
         onPasteSnippet: ((SavedSnippet) -> Void)? = nil,
         onPasteSnippetPlain: ((SavedSnippet) -> Void)? = nil,
         initialScope: QuickPasteScope = .history,
         inspector: InspectorPresentation? = nil) {
        self.store = store
        self.preferredTargetName = preferredTargetName
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onOpenLibrary = onOpenLibrary
        self.onClose = onClose
        self.onPasteSnippet = onPasteSnippet
        self.onPasteSnippetPlain = onPasteSnippetPlain
        _scope = State(initialValue: initialScope)
        _inspector = StateObject(wrappedValue: inspector ??
            InspectorPresentation(driver: AppKitInspectorAnimationDriver()))
    }

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        let clips = store.hudItems(matching: query)
        let snippetRows = store.snippets(matching: query)
        let snippetMatches = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : snippetRows.count

        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                QuickPastePanelHeader(preferredTargetName: preferredTargetName, palette: palette, onClose: onClose)
                QuickPastePanelSearchRow(query: $query, scope: scope, snippetMatchCount: snippetMatches, palette: palette) { next in
                    guard scope != next else { return }
                    scope = next
                    selection.itemID = next == .history ? clips.first?.id : snippetRows.first?.id
                }
                if scope == .snippets {
                    QuickPasteSnippetSection(snippets: snippetRows, query: query, selection: selection,
                        onPaste: { pasteSnippet($0, plain: false) },
                        onPastePlain: { pasteSnippet($0, plain: true) })
                } else if clips.isEmpty {
                    QuickPasteHistoryPlaceholder(queryIsEmpty: query.isEmpty, shortcut: store.quickPasteShortcut)
                } else {
                    QuickPasteHistoryList(clips: clips, store: store, selection: selection, listProxy: listProxy,
                        inspector: inspector, reduceMotion: reduceMotion,
                        onPaste: { paste($0, plainText: false) },
                        onPastePlain: { paste($0, plainText: true) })
                }
                QuickPastePanelFooter(scope: scope, palette: palette, onClose: onClose, onOpenLibrary: onOpenLibrary)
            }
            .padding(ClipFlowLayout.pageInset)
            .allowsHitTesting(!inspector.blocksBackground)
            .disabled(inspector.blocksBackground)
            .accessibilityHidden(inspector.blocksBackground)

            // The full-sized scrim survives every last closing frame.
            if inspector.blocksBackground {
                InspectorScrim(motion: inspector.motion, opacity: 1) {
                    inspector.dismiss(reduceMotion: reduceMotion)
                }
            }

            if let inspectingItem {
                HUDInspectorOverlay(
                    item: inspectingItem, store: store,
                    sourceRectInWindow: inspector.snapshot.sourceRectInWindow,
                    motion: inspector.motion,
                    onClose: { inspector.dismiss(reduceMotion: reduceMotion) },
                    onPaste: {
                        inspector.dismiss(reduceMotion: reduceMotion) {
                            guard let current = store.item(withID: inspectingItem.id) else { return }
                            onClose()
                            onPaste(current)
                        }
                    },
                    onPastePlain: {
                        inspector.dismiss(reduceMotion: reduceMotion) {
                            guard let current = store.item(withID: inspectingItem.id) else { return }
                            onClose()
                            onPastePlain(current)
                        }
                    }
                )
            }
        }
        .frame(width: QuickPastePanelLayout.panelWidth, height: QuickPastePanelLayout.panelHeight, alignment: .topLeading)
        .background(
            InspectorEscapeHandler(onEscape: {
                guard inspector.blocksBackground else { return false }
                inspector.dismiss(reduceMotion: reduceMotion)
                return true
            }, onWindowInactive: { inspector.reset() }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .onChangeBackward(of: store.items) {
            inspector.invalidateIfMissing(availableIDs: Set(store.items.filter { !$0.isExpired() }.map(\.id)))
        }
        .onDisappear { inspector.reset() }
        .onAppear {
            if selection.itemID == nil {
                selection.itemID = clips.first?.id
            }
        }
        .onChangeBackward(of: query) {
            selection.itemID = scope == .history ? clips.first?.id : snippetRows.first?.id
        }
        .onChangeBackward(of: scope) {
            selection.itemID = scope == .history ? clips.first?.id : snippetRows.first?.id
        }
        .modifier(SensitiveSnippetConfirmation(store: store))
        .background(
            ListKeyCommandMonitor(queryIsEmpty: query.isEmpty, onCommand: { command in
                if scope == .snippets {
                    return handleSnippetKey(command, snippets: snippetRows)
                }
                return handleKeyCommand(command, clips: clips)
            })
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .background {
            GeometryReader { proxy in
                FloatingPanelBackground(palette: palette)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    private var inspectingItem: ClipboardItem? {
        guard let id = inspector.snapshot.itemID else { return nil }
        return store.item(withID: id)
    }

    private func handleKeyCommand(_ command: ListKeyCommand, clips: [ClipboardItem]) -> Bool {
        guard !inspector.blocksBackground, !clips.isEmpty else { return false }
        let selected = clips.first(where: { $0.id == selection.itemID })
        switch command {
        case .moveUp, .moveDown:
            return selection.move(by: command == .moveUp ? -1 : 1, in: clips.map(\.id)) != nil
        case .activate:
            paste(selected ?? clips[0], plainText: false)
        case .pastePlain:
            paste(selected ?? clips[0], plainText: true)
        case .pasteIndex(let index):
            guard clips.indices.contains(index) else { return false }
            paste(clips[index], plainText: false)
        case .toggleDetails:
            guard let selected else { return false }
            if listProxy.list?.openDetails(for: selected.id) != true {
                inspector.open(itemID: selected.id, reduceMotion: reduceMotion)
            }
        case .showSnippets:
            scope = .snippets
        case .showHistory:
            scope = .history
        case .reorder:
            return false
        }
        return true
    }

    private func handleSnippetKey(_ command: ListKeyCommand, snippets: [SavedSnippet]) -> Bool {
        guard !inspector.blocksBackground else { return false }
        switch command {
        case .showHistory:
            scope = .history
        case .showSnippets:
            scope = .snippets
        case .moveUp, .moveDown:
            guard !snippets.isEmpty else { return false }
            return selection.move(by: command == .moveUp ? -1 : 1, in: snippets.map(\.id)) != nil
        case .activate:
            guard !snippets.isEmpty else { return false }
            let selected = snippets.first(where: { $0.id == selection.itemID }) ?? snippets[0]
            pasteSnippet(selected, plain: false)
        case .pastePlain:
            guard !snippets.isEmpty else { return false }
            let selected = snippets.first(where: { $0.id == selection.itemID }) ?? snippets[0]
            pasteSnippet(selected, plain: true)
        case .pasteIndex(let index):
            guard snippets.indices.contains(index) else { return false }
            pasteSnippet(snippets[index], plain: false)
        case .toggleDetails, .reorder:
            return false
        }
        return true
    }

    /// Snippet bodies are already plain text. ↩ and ⇧↩ both write only that string;
    /// ⇧↩ uses the plain-text status so the gesture matches history.
    private func pasteSnippet(_ snippet: SavedSnippet, plain: Bool) {
        selection.itemID = snippet.id
        onClose()
        if plain {
            if let onPasteSnippetPlain {
                onPasteSnippetPlain(snippet)
            } else {
                ClipFlowRuntime.shared.pasteSnippetPlain(snippet)
            }
        } else if let onPasteSnippet {
            onPasteSnippet(snippet)
        } else {
            ClipFlowRuntime.shared.pasteSnippet(snippet)
        }
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        selection.itemID = item.id
        onClose()
        if plainText, PlainTextPaste.canPasteAsPlainText(item) {
            onPastePlain(item)
        } else {
            onPaste(item)
        }
    }
}
