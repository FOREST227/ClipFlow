import SwiftUI

struct QuickPasteSnippetSection: View {
    let snippets: [SavedSnippet]
    let query: String
    let selection: HistorySelection
    let onPaste: (SavedSnippet) -> Void
    let onPastePlain: (SavedSnippet) -> Void

    var body: some View {
        if snippets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "还没有常用片段" : "没有匹配的片段")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "在历史里选择“存为片段”，或到主窗口的片段页新建。片段不会被历史条数清掉。"
                    : "试试其他关键词，或切回历史。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: QuickPasteCardLayout.viewportHeight, alignment: .top)
        } else {
            QuickPasteSnippetList(snippets: snippets, selection: selection,
                onSelect: { selection.itemID = $0.id },
                onPaste: onPaste,
                onPastePlain: onPastePlain)
                .frame(height: QuickPasteCardLayout.viewportHeight)
        }
    }
}
