import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)? = nil
    let onInspectItem: (ClipboardItem) -> Void

    var body: some View {
        LayoutSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.selectedCategory.title).font(.system(size: 15, weight: .semibold))
                    Text("\(store.filteredItems.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("双击查看详情 · 右键更多操作").font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(role: .destructive) { store.clearHistory() } label: {
                        Label("清空未置顶历史", systemImage: "trash")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    .disabled(!store.items.contains(where: { !$0.pinned }))
                    .help("清空所有未置顶历史，保留置顶条目；不限于当前筛选结果")
                }
                Divider()
                if store.filteredItems.isEmpty {
                    EmptyLibraryView(store: store, palette: palette)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: LibraryCardLayout.viewportHeight, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scroll in
                        SoftEdgeScrollView(showsEdgeEffects: false) {
                            // Fixed card heights and an independent selection layer allow
                            // offscreen content to stay unloaded without selection relayout.
                            LazyVStack(spacing: LibraryCardLayout.spacing) {
                                ForEach(store.filteredItems) { item in
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
                        }
                        // Only keyboard navigation scrolls; pointer selection keeps the viewport.
                        .onReceive(store.historySelection.revealRequests) { id in scroll.scrollTo(id) }
                    }
                    .frame(minHeight: LibraryCardLayout.viewportHeight, maxHeight: .infinity)
                }
            }
        }
    }
}

struct EmptyLibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text(store.items.isEmpty ? "从一次复制开始" : "没有匹配的内容")
                .font(.system(size: 16, weight: .semibold))
            Text(store.items.isEmpty
                ? "复制文字或图片后会出现在这里。\n按 \(store.quickPasteShortcut.displayName) 可随时快速回贴。"
                : "试试其他关键词，或切换到“全部”。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !store.items.isEmpty {
                Button("查看全部内容") { store.searchText = ""; store.selectedCategory = .all }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
            }
        }
        .padding(24)
    }
}

