import SwiftUI

protocol ClipFlowTab: Hashable {
    var title: String { get }
    var icon: String { get }
}

/// Shared visual treatment for page navigation and the settings subgroups.
struct ClipFlowTabBar<Tab: ClipFlowTab>: View {
    let options: [Tab]
    @Binding var selection: Tab
    let accessibilityTitle: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    @ViewState private var hovered: Tab?
    @FocusState private var focused: Tab?

    private var accent: Color { ClipCategory.all.tint }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selection == option ? accent : Color.secondary)
                        Text(option.title)
                            .font(.system(size: 12, weight: selection == option ? .semibold : .medium))
                            .foregroundStyle(selection == option ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background {
                        if selection == option {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(
                                    colors: colorScheme == .dark
                                        ? [accent.opacity(0.25), accent.opacity(0.12)]
                                        : [.white.opacity(0.96), accent.opacity(0.10)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.35 : 0.2), lineWidth: 1))
                                .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.07), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "selection", in: indicator)
                        } else if hovered == option {
                            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(focused == option ? accent.opacity(0.7) : .clear, lineWidth: 2)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: option)
                .focusEffectDisabled()
                .onHover { hovered = $0 ? option : nil }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.88), value: selection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .onMoveCommand { direction in
            guard let current = options.firstIndex(of: focused ?? selection), !options.isEmpty else { return }
            let next: Int
            switch direction {
            case .left: next = max(0, current - 1)
            case .right: next = min(options.count - 1, current + 1)
            default: return
            }
            selection = options[next]
            focused = options[next]
        }
    }
}
