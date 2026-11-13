import SwiftUI

struct FlexiblePillRow: View {
    let items: [String]
    let tint: Color

    var body: some View {
        HorizontalViewThatFits {
            HStack(spacing: 8) {
                rowContent
            }
        } second: {
            VStack(alignment: .leading, spacing: 8) {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        ForEach(items, id: \.self) { item in
            Text(item)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                )
        }
    }
}

struct KindBadge: View {
    let kind: ClipboardKind
    let tint: Color

    var body: some View {
        Text(kind.label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

struct SmallBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

struct ClipButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = Color.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

struct ClipFlowPalette {
    let backgroundStart: Color
    let backgroundMiddle: Color
    let backgroundEnd: Color
    let orbA: Color
    let orbB: Color
    let border: Color
    let shadow: Color
    let softFill: Color
    let rowFill: Color
    let selectedRowFill: Color
    let rowBorder: Color
    let inputFill: Color
    let primaryButtonFill: Color
    let secondaryButtonFill: Color

    static func resolve(for colorScheme: ColorScheme) -> ClipFlowPalette {
        if colorScheme == .dark {
            return ClipFlowPalette(
                backgroundStart: Color(red: 0.09, green: 0.10, blue: 0.14),
                backgroundMiddle: Color(red: 0.12, green: 0.14, blue: 0.18),
                backgroundEnd: Color(red: 0.09, green: 0.12, blue: 0.16),
                orbA: Color(red: 0.83, green: 0.55, blue: 0.28).opacity(0.28),
                orbB: Color(red: 0.25, green: 0.58, blue: 0.88).opacity(0.24),
                border: Color.white.opacity(0.14),
                shadow: Color.black.opacity(0.34),
                softFill: Color.white.opacity(0.09),
                rowFill: Color(red: 0.18, green: 0.20, blue: 0.25),
                selectedRowFill: Color(red: 0.18, green: 0.20, blue: 0.25),
                rowBorder: Color.white.opacity(0.15),
                inputFill: Color.white.opacity(0.12),
                primaryButtonFill: Color(red: 0.30, green: 0.59, blue: 0.92),
                secondaryButtonFill: Color.white.opacity(0.10)
            )
        }

        return ClipFlowPalette(
            backgroundStart: Color(red: 0.98, green: 0.95, blue: 0.90),
            backgroundMiddle: Color(red: 0.93, green: 0.96, blue: 0.99),
            backgroundEnd: Color(red: 0.95, green: 0.93, blue: 0.98),
            orbA: Color(red: 0.98, green: 0.80, blue: 0.47).opacity(0.38),
            orbB: Color(red: 0.40, green: 0.73, blue: 0.95).opacity(0.22),
            border: Color.white.opacity(0.7),
            shadow: Color.black.opacity(0.10),
            softFill: Color.white.opacity(0.66),
            rowFill: Color(red: 0.965, green: 0.969, blue: 0.975),
            selectedRowFill: Color(red: 0.935, green: 0.95, blue: 0.975),
            rowBorder: Color(red: 0.65, green: 0.70, blue: 0.78).opacity(0.40),
            inputFill: Color.white.opacity(0.82),
            primaryButtonFill: Color(red: 0.30, green: 0.59, blue: 0.92),
            secondaryButtonFill: Color.white.opacity(0.74)
        )
    }
}
