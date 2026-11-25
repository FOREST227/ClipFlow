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
    @ViewState private var showsFloatingSearch = false
    @FocusState private var isFloatingSearchFocused: Bool
    @ViewState private var carouselHoverState = CarouselHoverState()
    @ViewState private var presentationMode: QuickPastePresentationMode
    @ViewState private var scope: QuickPasteScope
    // Keep selection independent of the parent view's layout/scroll identity.
    @ViewState private var selection = HistorySelection()
    @ViewState private var listProxy = QuickPasteListProxy()
    @StateObject private var inspector: InspectorPresentation
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }
    private let initialSelectionID: UUID?

    init(store: ClipFlowStore, preferredTargetName: String?, onPaste: @escaping (ClipboardItem) -> Void,
         onPastePlain: @escaping (ClipboardItem) -> Void = { _ in },
         onOpenLibrary: @escaping () -> Void, onClose: @escaping () -> Void,
         onPasteSnippet: ((SavedSnippet) -> Void)? = nil,
         onPasteSnippetPlain: ((SavedSnippet) -> Void)? = nil,
         initialScope: QuickPasteScope = .history,
         inspector: InspectorPresentation? = nil,
         initialMode: QuickPastePresentationMode = .list,
         initialSelectionID: UUID? = nil) {
        self.store = store
        self.preferredTargetName = preferredTargetName
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onOpenLibrary = onOpenLibrary
        self.onClose = onClose
        self.onPasteSnippet = onPasteSnippet
        self.onPasteSnippetPlain = onPasteSnippetPlain
        self.initialSelectionID = initialSelectionID
        _scope = State(initialValue: initialScope)
        _presentationMode = State(initialValue: initialMode)
        _inspector = StateObject(wrappedValue: inspector ??
            InspectorPresentation(driver: AppKitInspectorAnimationDriver()))
    }

    var body: some View {
        let clips = store.hudItems(matching: query)
        if presentationMode == .fan {
            floatingCarouselBody(clips: clips)
        } else {
            classicListBody(clips: clips)
        }
    }

    private func floatingCarouselBody(clips: [ClipboardItem]) -> some View {
        let queued = store.pasteStack.queuedItems(from: store.items)
        return ZStack {
            // Clicking any transparent empty space outside the floating cards closes the HUD.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if showsFloatingSearch {
                        dismissFloatingSearch()
                    } else {
                        onClose()
                    }
                }

            VStack(spacing: 10) {
                ZStack {
                    if showsFloatingSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: ClipFlowType.meta, weight: .semibold))
                                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            TextField("输入关键词过滤…", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: ClipFlowType.body, weight: .medium))
                                .focused($isFloatingSearchFocused)
                            if !query.isEmpty {
                                Text("\(clips.count) 条")
                                    .font(.system(size: ClipFlowType.mono, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            }
                            Button {
                                dismissFloatingSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: ClipFlowType.body))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("关闭搜索 (Esc)")
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 276, height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(FolioTheme.deckCardFill(depth: 0, for: colorScheme))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(FolioTheme.primaryAccent(for: colorScheme).opacity(0.65), lineWidth: 1.2)
                        )
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.36 : 0.12), radius: 10, y: 4)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    } else if let head = queued.first {
                        Button {
                            guard let next = store.pasteStack.popNext(from: store.items) else { return }
                            onClose()
                            onPaste(next)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(FolioTheme.sageAccent(for: colorScheme))
                                    .frame(width: 6, height: 6)
                                Text("待贴 ① \(PasteStackTrayView.shortLabel(for: head, store: store))")
                                    .font(.system(size: ClipFlowType.meta, weight: .semibold))
                                    .lineLimit(1)
                                Text("粘贴下一条 ↩")
                                    .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(FolioTheme.deckCardFill(depth: 0, for: colorScheme).opacity(0.96))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.10), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 36)
                .animation(reduceMotion ? nil : ClipFlowMotion.selection, value: showsFloatingSearch)

                if clips.isEmpty {
                    VStack(spacing: 10) {
                        Text(query.isEmpty ? "还没有剪贴记录" : "没有匹配「\(query)」的卡片")
                            .font(.system(size: ClipFlowType.cardTitle, weight: .semibold))
                        if !query.isEmpty {
                            Button("清除搜索") { dismissFloatingSearch() }
                                .buttonStyle(FolioButtonStyle(prominence: .secondary))
                        } else {
                            Text("复制文字或图片后按 \(store.quickPasteShortcut.displayName) 呼出")
                                .font(.system(size: ClipFlowType.meta))
                                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        }
                    }
                    .padding(20)
                    .frame(width: 244, height: 140)
                    .background(
                        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                            .fill(FolioTheme.deckCardFill(depth: 0, for: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                            .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.14), radius: 14, y: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    QuickPasteFanDeckView(
                        items: clips,
                        store: store,
                        selection: selection,
                        pasteStack: store.pasteStack,
                        hoverState: carouselHoverState,
                        isSearchActive: showsFloatingSearch,
                        isBlocked: inspector.blocksBackground,
                        onSelectCenter: { item in selection.itemID = item.id },
                        onPaste: { item in
                            paste(item, plainText: false)
                        },
                        onInspect: { item in
                            selection.itemID = item.id
                            if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
                                inspector.dismiss(reduceMotion: reduceMotion)
                            } else {
                                inspector.open(itemID: item.id, reduceMotion: reduceMotion)
                            }
                        },
                        onOpenLibrary: {
                            onClose()
                            onOpenLibrary()
                        },
                        onToggleSearch: {
                            if showsFloatingSearch {
                                dismissFloatingSearch()
                            } else {
                                activateFloatingSearch(initialText: nil)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.vertical, 8)
            .allowsHitTesting(!inspector.blocksBackground)
            .disabled(inspector.blocksBackground)
            .accessibilityHidden(inspector.blocksBackground)

            if let inspectingItem {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { inspector.dismiss(reduceMotion: reduceMotion) }
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
                .frame(maxWidth: 360, maxHeight: QuickPastePanelLayout.floatingCarouselHeight - 16)
            }
        }
        .frame(width: QuickPastePanelLayout.floatingCarouselWidth, height: QuickPastePanelLayout.floatingCarouselHeight, alignment: .center)
        .background(Color.clear)
        .background(
            InspectorEscapeHandler(onEscape: {
                if inspector.blocksBackground {
                    inspector.dismiss(reduceMotion: reduceMotion)
                    return true
                }
                if showsFloatingSearch {
                    dismissFloatingSearch()
                    return true
                }
                return false
            }, onWindowInactive: { inspector.reset() }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .background(
            FloatingQuickPasteKeyMonitor(
                isSearchActive: showsFloatingSearch,
                isBlocked: inspector.blocksBackground,
                onStartSearch: { initialChars in
                    activateFloatingSearch(initialText: initialChars)
                },
                onDismissSearch: {
                    dismissFloatingSearch()
                },
                onOpenLibrary: {
                    onClose()
                    onOpenLibrary()
                }
            )
            .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .background(
            ListKeyCommandMonitor(
                queryIsEmpty: query.isEmpty,
                allowHorizontalArrows: !showsFloatingSearch || query.isEmpty,
                onCommand: { handleFanKeyCommand($0, clips: clips) }
            )
            .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .modifier(SensitiveSnippetConfirmation(store: store))
        .onChangeBackward(of: store.items) {
            inspector.invalidateIfMissing(availableIDs: Set(store.items.filter { !$0.isExpired() }.map(\.id)))
        }
        .onDisappear { inspector.reset() }
        .onAppear {
            if let initialSelectionID, clips.contains(where: { $0.id == initialSelectionID }) {
                selection.itemID = initialSelectionID
            } else if selection.itemID == nil {
                selection.itemID = clips.first?.id
            }
        }
        .onChangeBackward(of: query) {
            selection.itemID = clips.first?.id
        }
    }

    private func activateFloatingSearch(initialText: String?) {
        withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
            showsFloatingSearch = true
        }
        if let initialText, !initialText.isEmpty {
            query.append(initialText)
        }
        DispatchQueue.main.async {
            isFloatingSearchFocused = true
        }
    }

    private func dismissFloatingSearch() {
        isFloatingSearchFocused = false
        query = ""
        withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
            showsFloatingSearch = false
        }
    }

    private func classicListBody(clips: [ClipboardItem]) -> some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        let snippetRows = store.snippets(matching: query)
        let snippetMatches = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : snippetRows.count

        return ZStack {
            VStack(alignment: .leading, spacing: 12) {
                QuickPastePanelHeader(
                    preferredTargetName: preferredTargetName,
                    palette: palette,
                    onClose: onClose
                )
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
                selection.itemID = scope == .history ? clips.first?.id : snippetRows.first?.id
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

    private func handleFanKeyCommand(_ command: ListKeyCommand, clips: [ClipboardItem]) -> Bool {
        guard !inspector.blocksBackground, !clips.isEmpty else { return false }
        let activeID = carouselHoverState.hoveredID ?? selection.itemID
        let selected = clips.first(where: { $0.id == activeID })
        switch command {
        case .moveUp, .moveDown:
            carouselHoverState.hoveredID = nil
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
            inspector.open(itemID: selected.id, reduceMotion: reduceMotion)
        case .showHistory, .showSnippets, .reorder:
            return false
        }
        return true
    }

    private func handleKeyCommand(_ command: ListKeyCommand, clips: [ClipboardItem]) -> Bool {
        guard !inspector.blocksBackground else { return false }
        switch command {
        case .showSnippets:
            scope = .snippets
            return true
        case .showHistory:
            scope = .history
            return true
        default:
            break
        }
        guard !clips.isEmpty else { return false }
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
        case .showSnippets, .showHistory, .reorder:
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
