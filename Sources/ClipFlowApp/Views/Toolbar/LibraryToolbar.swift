import SwiftUI

struct HeaderView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容、来源或标签", text: $store.searchText).textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(palette.inputFill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius).strokeBorder(palette.border, lineWidth: 1))
        }
    }
}

/// One row of filters; the selected one carries its category tint.
struct CategoryFilterBar: View {
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ClipCategory.allCases) { category in
                Button {
                    withAnimation(ClipFlowMotion.selection) { store.selectedCategory = category }
                } label: {
                    CategoryPill(category: category, count: store.count(for: category),
                        isSelected: store.selectedCategory == category)
                }
                .buttonStyle(.plain)
                .help(category.subtitle)
            }
            Spacer(minLength: 0)
        }
        .frame(height: CategoryPill.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("内容筛选")
    }
}

