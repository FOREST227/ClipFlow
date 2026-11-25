import SwiftUI

enum ClearHistoryConfirmation {
    static func message(unpinnedCount: Int) -> String {
        "清空未置顶的 \(unpinnedCount) 条，置顶保留"
    }

    static func canRequest(unpinnedCount: Int) -> Bool {
        unpinnedCount > 0
    }
}

struct LibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    var deckExtraction: CardExtractionModel = CardExtractionModel()
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)? = nil
    let onInspectItem: (ClipboardItem) -> Void
    @ViewState private var confirmsClearHistory = false
    @Environment(\.colorScheme) private var colorScheme

    private var unpinnedCount: Int { store.items.filter { !$0.pinned }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Clean flush Folio subheader bar (equal left/right edges, no instructional caption clutter)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.selectedCategory.title)
                    .font(.system(size: ClipFlowType.cardTitle, weight: .semibold))
                Text("\(store.filteredItems.count) 条")
                    .font(.system(size: ClipFlowType.meta, design: .monospaced))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                Spacer()
                PasteStackSubheaderToggle(pasteStack: store.pasteStack)
                Button(role: .destructive) { confirmsClearHistory = true } label: {
                    Label("清空未置顶", systemImage: "trash")
                }
                .font(.system(size: ClipFlowType.meta))
                .buttonStyle(.borderless)
                .disabled(!ClearHistoryConfirmation.canRequest(unpinnedCount: unpinnedCount))
                .help(ClearHistoryConfirmation.message(unpinnedCount: unpinnedCount))
                .confirmationDialog(
                    ClearHistoryConfirmation.message(unpinnedCount: unpinnedCount),
                    isPresented: $confirmsClearHistory,
                    titleVisibility: .visible
                ) {
                    Button("清空未置顶历史", role: .destructive) { store.clearHistory() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("置顶条目会保留。此操作不能撤销。")
                }
            }

            if store.filteredItems.isEmpty {
                EmptyLibraryView(store: store, palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(FolioTheme.recessedWell(for: colorScheme).opacity(0.45))
                    )
            } else if store.libraryViewMode == .deck {
                FolioTimeDeckView(
                    items: store.filteredItems,
                    store: store,
                    selection: store.historySelection,
                    pasteStack: store.pasteStack,
                    extraction: deckExtraction,
                    palette: palette,
                    onInspectFrom: onInspectFrom,
                    onInspectOverlay: onInspectItem,
                    onPasteItem: { item in
                        ClipFlowRuntime.shared.paste(item)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HistoryNativeList(
                    items: store.filteredItems,
                    revealedItemIDs: store.revealedItemIDs,
                    store: store,
                    palette: palette,
                    onInspectFrom: onInspectFrom,
                    onInspectItem: onInspectItem
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct EmptyLibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: ClipFlowLayout.space12) {
            Image(systemName: store.items.isEmpty ? "book.closed" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            Text(store.items.isEmpty ? "活页夹尚无剪贴卡片" : "没有匹配的卡片")
                .font(.system(size: 15, weight: .semibold))
            Group {
                if store.items.isEmpty {
                    (Text("复制文字、代码或图片后会自动归入叠卡盒。\n按 ")
                        + ShortcutGlyphLayout.text(for: store.quickPasteShortcut, pointSize: 12)
                        + Text(" 可随时呼出快速粘贴。"))
                        .accessibilityLabel("复制文字或图片后会出现在这里。按 \(store.quickPasteShortcut.displayName) 可随时快速回贴。")
                } else {
                    Text("试试其他关键词，或点击左侧「全部」折签。")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !store.items.isEmpty {
                Button("查看全部卡片") { store.searchText = ""; store.selectedCategory = .all }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
            }
        }
        .padding(ClipFlowLayout.space24)
    }
}
