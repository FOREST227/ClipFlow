import SwiftUI

struct QuickPastePanelSearchRow: View {
    @Binding var query: String
    let scope: QuickPasteScope
    let snippetMatchCount: Int
    let palette: ClipFlowPalette
    let onScope: (QuickPasteScope) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)

                TextField(scope == .history ? "搜索最近内容" : "搜索片段", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityLabel(scope == .history ? "搜索最近内容" : "搜索片段")
            }
            .padding(.horizontal, ClipFlowLayout.space12)
            .frame(height: ClipFlowLayout.controlHeight)
            .background(palette.inputFill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1))

            QuickPasteScopeBar(scope: scope, snippetMatchCount: snippetMatchCount, palette: palette, onSelect: onScope)
                .fixedSize()
        }
    }
}
