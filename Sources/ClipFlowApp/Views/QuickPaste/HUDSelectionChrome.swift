import SwiftUI

/// Selection repaints a lightweight background, never the hosted row's content.
struct HUDSelectionChrome: View {
    let itemID: UUID
    let selection: HistorySelection
    let tint: Color
    @ViewState private var isSelected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
            .fill(isSelected ? palette.selectedRowFill : palette.rowFill)
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .fill(isSelected ? tint.opacity(0.16) : .clear))
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.65) : palette.rowBorder,
                    lineWidth: isSelected ? 1.5 : 1))
            .animation(reduceMotion ? nil : ClipFlowMotion.rowSelection, value: isSelected)
            .onReceive(selection.$itemID.map { $0 == itemID }.removeDuplicates()) {
                if isSelected != $0 { isSelected = $0 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
