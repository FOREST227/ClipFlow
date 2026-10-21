import SwiftUI

protocol ClipFlowTab: Hashable {
    var title: String { get }
    var icon: String { get }
}

enum ClipFlowTabStyle {
    case segmented, integrated, compact
}

/// Shared navigation behavior with distinct page, section and option treatments.
struct ClipFlowTabBar<Tab: ClipFlowTab>: View {
    let options: [Tab]
    @Binding var selection: Tab
    let accessibilityTitle: String
    var style: ClipFlowTabStyle = .segmented
    private var integrated: Bool { style == .integrated }
    private var compact: Bool { style == .compact }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    @ViewState private var hovered: Tab?
    @FocusState private var focused: Tab?

    private var accent: Color { ClipCategory.all.tint }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                if compact && option != options.first {
                    Rectangle().fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 10)
                        .accessibilityHidden(true)
                }
                Button {
                    guard selection != option else { return }
                    selection = option
                } label: {
                    HStack(spacing: 8) {
                        if integrated {
                            ClipFlowBrandMark(icon: option.icon, size: 28, usesAppPalette: true)
                                .opacity(selection == option ? 1 : 0.65)
                                .scaleEffect(reduceMotion || selection == option ? 1 : 0.94)
                        } else if !compact {
                            Image(systemName: option.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selection == option ? accent : Color.secondary)
                        }
                        Text(option.title)
                            .font(integrated
                                ? .system(size: 15, weight: .bold, design: .rounded)
                                : .system(size: 12, weight: selection == option ? .semibold : .medium))
                            .foregroundStyle(selection == option ? (compact ? accent : Color.primary) : (compact && hovered == option ? Color.primary : Color.secondary))
                            .lineLimit(1)
                    }
                    .frame(height: integrated ? 40 : 32)
                    .overlay(alignment: .bottom) {
                        if integrated && selection == option {
                            Capsule().fill(accent).frame(width: 24, height: 2)
                                .matchedGeometryEffect(id: "selection", in: indicator)
                        }
                    }
                    .padding(.horizontal, compact ? 20 : 12)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .background {
                        if compact {
                            Color.clear
                        } else if integrated {
                            if hovered == option {
                                RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.04))
                            }
                        } else if selection == option {
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
                .focusEffectDisabledCompat()
                .onHover { hovered = $0 ? option : nil }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .padding(style == .segmented ? 4 : 0)
        .background(Color.primary.opacity(style == .segmented ? (colorScheme == .dark ? 0.07 : 0.04) : 0), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(style == .segmented ? 0.06 : 0), lineWidth: 1))
        .animation(reduceMotion ? nil : (integrated ? ClipFlowMotion.tabSelection : .easeOut(duration: 0.2)), value: selection)
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
