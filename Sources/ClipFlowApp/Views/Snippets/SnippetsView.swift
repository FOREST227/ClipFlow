import AppKit
import SwiftUI

struct SensitiveSnippetConfirmation: ViewModifier {
    @ObservedObject var store: ClipFlowStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            SnippetLibrary.sensitiveConfirmationTitle,
            isPresented: Binding(
                get: { store.sensitiveSnippetPrompt != nil },
                set: { if !$0 { store.cancelSensitiveSnippetSave() } }
            ),
            titleVisibility: .visible
        ) {
            Button("存为片段") { store.confirmSensitiveSnippetSave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(SnippetLibrary.sensitiveConfirmationMessage)
        }
    }
}

struct SnippetEditorDraft: Identifiable, Equatable {
    let id: UUID
    var existingID: UUID?
    var title: String
    var category: String
    var body: String

    static func creating() -> SnippetEditorDraft {
        SnippetEditorDraft(id: UUID(), existingID: nil, title: "", category: "", body: "")
    }

    static func editing(_ snippet: SavedSnippet) -> SnippetEditorDraft {
        SnippetEditorDraft(
            id: snippet.id,
            existingID: snippet.id,
            title: snippet.title,
            category: snippet.category ?? "",
            body: snippet.body
        )
    }
}

struct SnippetsView: View {
    var reservesTrafficLights = false
    @ObservedObject var store: ClipFlowStore
    var initialEditor: SnippetEditorDraft?
    var onToggleEdgeDock: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var editor: SnippetEditorDraft?
    @State private var selectedID: UUID?
    @State private var pendingDelete: SavedSnippet?

    private var rows: [SavedSnippet] { store.snippets(matching: store.snippetSearch) }
    private var searching: Bool {
        !store.snippetSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        VStack(alignment: .leading, spacing: ClipFlowLayout.space12) {
            header(palette: palette)
            searchField(palette: palette)
            Text(store.iCloudSyncEnabled
                ? "不会随历史条数清除，也不会自动过期。普通片段会写入文稿同步；从敏感记录保存的片段只留在本机。"
                : "不会随历史条数清除，也不会自动过期。开启文稿同步后，普通片段会一并同步；从敏感记录保存的片段只留在本机。")
                .font(.system(size: 11))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("常用片段保留说明")
            Divider()
            if rows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                snippetList(palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, reservesTrafficLights ? 8 : 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editor) { draft in
            SnippetEditorSheet(draft: draft, palette: palette) { editor = nil } onSave: { draft in
                save(draft)
                editor = nil
            }
        }
        .confirmationDialog(
            "删除这个片段？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除片段", role: .destructive) {
                if let pendingDelete { store.deleteSnippet(pendingDelete.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let pendingDelete {
                Text(deleteMessage(pendingDelete))
            }
        }
        .onAppear {
            if editor == nil { editor = initialEditor }
            if selectedID == nil { selectedID = rows.first?.id }
        }
        .onChangeBackward(of: store.snippetSearch) {
            if !rows.contains(where: { $0.id == selectedID }) {
                selectedID = rows.first?.id
            }
        }
        .background(
            ListKeyCommandMonitor(queryIsEmpty: store.snippetSearch.isEmpty, onCommand: handleKey)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("常用片段")
    }

    private func header(palette: ClipFlowPalette) -> some View {
        HStack(spacing: 10) {
            if reservesTrafficLights {
                Spacer().frame(width: 60)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("常用片段").font(.system(size: 14, weight: .semibold))
                Text("\(rows.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            }
            Spacer(minLength: 8)
            Button {
                editor = .creating()
            } label: {
                Label("新建片段", systemImage: "plus")
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(ClipFlowActionButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
            .accessibilityLabel("新建片段")
            .accessibilityHint("填写标题和正文，保存后可反复粘贴")

            if let onToggleEdgeDock {
                Button(action: onToggleEdgeDock) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: ClipFlowType.meta, weight: .medium))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                }
                .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 30, horizontalPadding: 9, cornerRadius: 9))
                .help("收起至屏幕右侧书签耳")
            }
        }
    }

    private func searchField(palette: ClipFlowPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索标题、内容或分类", text: $store.snippetSearch)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索片段")
            if !store.snippetSearch.isEmpty {
                Button { store.snippetSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除片段搜索")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, ClipFlowLayout.space12)
        .frame(height: ClipFlowLayout.controlHeight)
        .background(palette.inputFill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: ClipFlowLayout.space12) {
            Image(systemName: store.snippets.isEmpty ? "text.quote" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
            Text(store.snippets.isEmpty ? "还没有常用片段" : "没有匹配的片段")
                .font(.system(size: 16, weight: .semibold))
            Text(store.snippets.isEmpty
                ? "把地址、签名、常用回复或代码模板存在这里。历史里的“存为片段”也会出现在这份列表。"
                : "试试其他关键词，或清除搜索。")
                .font(.system(size: 12))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ClipFlowLayout.space24)
        .accessibilityElement(children: .combine)
    }

    private func snippetList(palette: ClipFlowPalette) -> some View {
        List {
            ForEach(rows) { snippet in
                SnippetRow(snippet: snippet, palette: palette, canReorder: !searching,
                    isSelected: selectedID == snippet.id,
                    onSelect: { selectedID = snippet.id },
                    onEdit: { editor = .editing(snippet) },
                    onMoveUp: { store.moveSnippet(id: snippet.id, by: -1) },
                    onMoveDown: { store.moveSnippet(id: snippet.id, by: 1) },
                    onDelete: { pendingDelete = snippet })
                    .tag(snippet.id)
                    .snippetListRowChrome()
            }
            .onMove { offsets, destination in
                guard !searching else { return }
                store.moveSnippets(from: offsets, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackgroundHiddenCompat()
        .background(SnippetListHighlightDisabler())
        .accessibilityLabel("常用片段列表")
    }

    private func save(_ draft: SnippetEditorDraft) {
        if let existingID = draft.existingID {
            _ = store.updateSnippet(id: existingID, title: draft.title, body: draft.body, category: draft.category)
            selectedID = existingID
        } else if let created = store.createSnippet(title: draft.title, body: draft.body, category: draft.category) {
            selectedID = created.id
        }
    }

    private func deleteMessage(_ snippet: SavedSnippet) -> String {
        if snippet.localOnly {
            return "“\(snippet.title)”只保存在这台 Mac 上。删除后不能恢复。"
        }
        return "“\(snippet.title)”会从本机删除。若已开启文稿同步，其他 Mac 上的同一片段也会删除。此操作不能撤销。"
    }

    private func handleKey(_ command: ListKeyCommand) -> Bool {
        switch command {
        case .moveUp, .moveDown:
            return moveSelection(by: command == .moveUp ? -1 : 1)
        case .activate:
            guard let snippet = rows.first(where: { $0.id == selectedID }) ?? rows.first else { return false }
            selectedID = snippet.id
            editor = .editing(snippet)
            return true
        case .reorder(let direction):
            guard !searching, let selectedID else { return false }
            store.moveSnippet(id: selectedID, by: direction)
            return true
        case .toggleDetails, .pasteIndex, .pastePlain, .showHistory, .showSnippets:
            return false
        }
    }

    private func moveSelection(by direction: Int) -> Bool {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return false }
        let next: Int
        if let selectedID, let current = ids.firstIndex(of: selectedID) {
            next = min(max(current + direction, 0), ids.count - 1)
        } else {
            next = direction < 0 ? ids.count - 1 : 0
        }
        selectedID = ids[next]
        return true
    }
}

private struct SnippetRow: View {
    let snippet: SavedSnippet
    let palette: ClipFlowPalette
    let canReorder: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snippet.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let category = snippet.category {
                        Text(category)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                    if snippet.localOnly {
                        Text("仅本机")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ClipCategory.protected.labelColor(for: colorScheme))
                    }
                }
                Text(snippet.body)
                    .font(.system(size: 12))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
                onEdit()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("编辑片段")

            Menu {
                Button("编辑", action: onEdit)
                if canReorder {
                    Button("上移", action: onMoveUp)
                    Button("下移", action: onMoveDown)
                }
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(snippet.title)的操作")
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(CardSelectionChrome(isSelected: isSelected, tint: ClipCategory.all.tint, palette: palette))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SnippetLibrary.accessibilityLabel(for: snippet))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "编辑", onEdit)
        .accessibilityAction(named: "上移") { if canReorder { onMoveUp() } }
        .accessibilityAction(named: "下移") { if canReorder { onMoveDown() } }
        .accessibilityAction(named: "删除", onDelete)
        .contextMenu {
            Button("编辑", action: onEdit)
            if canReorder {
                Button("上移", action: onMoveUp)
                Button("下移", action: onMoveDown)
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

struct SnippetEditorSheet: View {
    @State var draft: SnippetEditorDraft
    let palette: ClipFlowPalette
    let onCancel: () -> Void
    let onSave: (SnippetEditorDraft) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var canSave: Bool { SnippetLibrary.hasBody(draft.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existingID == nil ? "新建片段" : "编辑片段")
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            field("标题", prompt: "不填则使用正文第一行", text: $draft.title)
                .accessibilityLabel("片段标题")
            field("分类", prompt: "可选，例如签名、地址", text: $draft.category)
                .accessibilityLabel("片段分类")
            Text("正文")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            TextEditor(text: $draft.body)
                .font(.system(size: 13))
                .frame(minHeight: 160)
                .scrollContentBackgroundHiddenCompat()
                .padding(8)
                .background(colorScheme == .dark ? palette.inputFill : Color.white,
                    in: RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1))
                .accessibilityLabel("片段正文")
            if !canSave {
                Text(SnippetLibrary.emptyBodyStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(ClipCategory.protected.labelColor(for: colorScheme))
                    .accessibilityLabel(SnippetLibrary.emptyBodyStatus)
            }
            HStack {
                Button("取消", action: onCancel)
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存片段") { onSave(draft) }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("保存片段")
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(palette.backgroundMiddle)
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: ClipFlowLayout.controlHeight)
                .background(colorScheme == .dark ? palette.inputFill : Color.white,
                    in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1))
        }
    }
}

private extension View {
    @ViewBuilder func snippetListRowChrome() -> some View {
        if #available(macOS 13, *) {
            self.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            self.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
        }
    }
}

/// The plain list's full-row highlight is not the history card. Turn that highlight off.
private struct SnippetListHighlightDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Disabler() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Disabler)?.clearSelectionHighlight() }

    final class Disabler: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearSelectionHighlight()
        }
        override func layout() {
            super.layout()
            clearSelectionHighlight()
        }
        func clearSelectionHighlight() {
            var cursor: NSView? = self
            while let view = cursor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    table.focusRingType = .none
                    return
                }
                cursor = view.superview
            }
        }
    }
}
