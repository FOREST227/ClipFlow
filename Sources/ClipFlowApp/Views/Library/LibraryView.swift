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
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)? = nil
    let onInspectItem: (ClipboardItem) -> Void
    @ViewState private var confirmsClearHistory = false
    @Environment(\.colorScheme) private var colorScheme

    private var unpinnedCount: Int { store.items.filter { !$0.pinned }.count }

    var body: some View {
        LayoutSurface {
            VStack(alignment: .leading, spacing: ClipFlowLayout.space12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.selectedCategory.title).font(.system(size: 15, weight: .semibold))
                    Text("\(store.filteredItems.count) 条").font(.system(size: 11))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    Spacer()
                    Text("双击查看详情 · 右键更多操作").font(.system(size: 11))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .lineLimit(1)
                    Button(role: .destructive) { confirmsClearHistory = true } label: {
                        Label("清空未置顶历史", systemImage: "trash")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .padding(.leading, ClipFlowLayout.space8)
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
                Divider()
                if store.filteredItems.isEmpty {
                    EmptyLibraryView(store: store, palette: palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HistoryRowList(items: store.filteredItems, revealedItemIDs: store.revealedItemIDs,
                        store: store, palette: palette, onInspectFrom: onInspectFrom,
                        onInspectItem: onInspectItem)
                        .equatable()
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

/// The history stack stays mounted while the inspector opens. Re-evaluating this
/// `LazyVStack` is what inserts or replaces scrolled hosting views on Xcode 26.3.
private struct HistoryRowList: View, Equatable {
    let items: [ClipboardItem]
    let revealedItemIDs: Set<UUID>
    let store: ClipFlowStore
    let palette: ClipFlowPalette
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)?
    let onInspectItem: (ClipboardItem) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.revealedItemIDs == rhs.revealedItemIDs
    }

    var body: some View {
        ScrollViewReader { scroll in
            SoftEdgeScrollView(showsEdgeEffects: false) {
                // Fixed card heights and an independent selection layer allow
                // offscreen content to stay unloaded without selection relayout.
                LazyVStack(spacing: LibraryCardLayout.spacing) {
                    ForEach(items) { item in
                        StableHistoryRow(item: item, store: store, palette: palette,
                            showsSensitive: store.isRevealed(item),
                            onInspectFrom: onInspectFrom, onInspectItem: onInspectItem)
                            .equatable()
                    }
                }
            }
            // Only keyboard navigation scrolls; pointer selection keeps the viewport.
            .onReceive(store.historySelection.revealRequests) { id in scroll.scrollTo(id) }
        }
    }
}

/// Skip row updates while the inspector animates. Selection is observed inside the card,
/// so a highlight does not replace the native row.
private struct StableHistoryRow: View, Equatable {
    let item: ClipboardItem
    let store: ClipFlowStore
    let palette: ClipFlowPalette
    let showsSensitive: Bool
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)?
    let onInspectItem: (ClipboardItem) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.showsSensitive == rhs.showsSensitive
    }

    var body: some View {
        LibraryInteractiveCard(item: item, store: store,
            displayedSnippet: store.displaySnippet(for: item), palette: palette,
            onInspectFrom: { source in
                if let onInspectFrom { onInspectFrom(item, source) }
                else { onInspectItem(item) }
            }, onSelect: { store.select(item) },
            onInspect: { onInspectItem(item) })
        .frame(maxWidth: .infinity)
        .frame(height: LibraryCardLayout.height(for: item.kind))
    }
}

struct EmptyLibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: ClipFlowLayout.space12) {
            Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            Text(store.items.isEmpty ? "从一次复制开始" : "没有匹配的内容")
                .font(.system(size: 16, weight: .semibold))
            Text(store.items.isEmpty
                ? "复制文字或图片后会出现在这里。\n按 \(store.quickPasteShortcut.displayName) 可随时快速回贴。"
                : "试试其他关键词，或切换到“全部”。")
                .font(.system(size: 12))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !store.items.isEmpty {
                Button("查看全部内容") { store.searchText = ""; store.selectedCategory = .all }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
            }
        }
        .padding(ClipFlowLayout.space24)
    }
}

