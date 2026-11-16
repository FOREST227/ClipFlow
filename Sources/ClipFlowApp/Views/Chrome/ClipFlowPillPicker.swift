import SwiftUI

/// The pill segmented control used for appearance, history length, and inspector display.
struct ClipFlowPillPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var accessibilityTitle: String
    var width: CGFloat
    var height: CGFloat = 32
    var title: (Option) -> String
    var icon: (Option) -> String? = { _ in nil }
    var help: (Option) -> String = { _ in "" }
    var optionAccessibilityLabel: (Option) -> String = { _ in "" }
    var accessibilityIdentifier: (Option) -> String? = { _ in nil }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                optionButton(option)
            }
        }
        .padding(3)
        .frame(width: width, height: height)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .animation(reduceMotion ? nil : ClipFlowMotion.fade, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private func optionButton(_ option: Option) -> some View {
        let selected = selection == option
        let spoken = optionAccessibilityLabel(option)
        let label = spoken.isEmpty ? title(option) : spoken
        let tip = help(option)
        return Button {
            guard selection != option else { return }
            selection = option
        } label: {
            HStack(spacing: 4) {
                if let symbol = icon(option) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                }
                Text(title(option))
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected
                ? ClipCategory.all.labelColor(for: colorScheme)
                : ClipFlowPalette.secondaryText(for: colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(ClipCategory.all.tint.opacity(0.13))
                        .matchedGeometryEffect(id: "pill", in: highlight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(tip.isEmpty ? title(option) : tip)
        .accessibilityLabel(label)
        .modifier(PillAccessibilityIdentifier(identifier: accessibilityIdentifier(option)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct PillAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
