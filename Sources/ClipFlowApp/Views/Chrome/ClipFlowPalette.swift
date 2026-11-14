import AppKit
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
            .scaleEffect(configuration.isPressed ? ClipFlowMotion.pressScale : 1)
            .background(
                RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
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
                selectedRowFill: Self.darkSelectedRowFill,
                rowBorder: Color.white.opacity(0.15),
                inputFill: Color.white.opacity(0.12),
                primaryButtonFill: CategoryInk.solid(.all),
                secondaryButtonFill: Color.white.opacity(0.10)
            )
        }

        return ClipFlowPalette(
            backgroundStart: Color(red: 0.98, green: 0.95, blue: 0.90),
            backgroundMiddle: Color(red: 0.93, green: 0.96, blue: 0.99),
            backgroundEnd: Color(red: 0.95, green: 0.93, blue: 0.98),
            orbA: Color(red: 0.98, green: 0.80, blue: 0.47).opacity(0.38),
            orbB: Color(red: 0.40, green: 0.73, blue: 0.95).opacity(0.22),
            border: Self.searchBorder,
            shadow: Color.black.opacity(0.10),
            softFill: Color.white.opacity(0.66),
            rowFill: Color(red: 0.965, green: 0.969, blue: 0.975),
            selectedRowFill: Color(red: 0.935, green: 0.95, blue: 0.975),
            rowBorder: Color(red: 0.65, green: 0.70, blue: 0.78).opacity(0.40),
            inputFill: Color.white.opacity(0.82),
            primaryButtonFill: CategoryInk.solid(.all),
            secondaryButtonFill: Color.white.opacity(0.74)
        )
    }

    /// Opaque light-mode search stroke. White at 70% on cream is about 1.05:1.
    static let searchBorder = Color(red: 0.72, green: 0.75, blue: 0.80)
    /// Dark rows lift 6% toward white so selection is a fill, not only a stroke.
    static let darkSelectedRowFill = Color(red: 0.2292, green: 0.248, blue: 0.295)

    /// Body and status copy under 14pt. Light `#5C5C5C` is 6.2:1 on cream; dark keeps the system secondary label.
    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(nsColor: .secondaryLabelColor)
            : Color(red: 92.0 / 255, green: 92.0 / 255, blue: 92.0 / 255)
    }

    /// Listening sentence on cream, about 5.4:1. The 6pt status dot can stay system green.
    static let listeningStatus = Color(red: 0.10, green: 0.45, blue: 0.28)
    /// Paused sentence. System orange on cream is about 2.1:1.
    static let pausedStatus = Color(red: 0.62, green: 0.32, blue: 0.04)

    /// The light-mode inks disappear on the dark settings background. Keep those values and lift the sentence in dark mode.
    static func listeningStatus(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.55, green: 0.88, blue: 0.70) : listeningStatus
    }

    static func pausedStatus(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.74, blue: 0.45) : pausedStatus
    }

    static func detailShellColors(for colorScheme: ColorScheme) -> (top: Color, bottom: Color) {
        if colorScheme == .dark {
            return (Color(red: 0.17, green: 0.19, blue: 0.23), Color(red: 0.14, green: 0.16, blue: 0.20))
        }
        return (Color(red: 0.96, green: 0.975, blue: 0.99), Color(red: 0.91, green: 0.935, blue: 0.97))
    }

    /// Cover lip samples the shell gradient instead of a third hardcoded gray.
    static func inspectorCover(for colorScheme: ColorScheme) -> Color {
        detailShellColors(for: colorScheme).bottom
    }

    /// Solid sheet drawn over the list. Its opacity animates; the list itself is not blurred.
    static func inspectorScrim(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.06, green: 0.07, blue: 0.09)
            : Color(red: 0.93, green: 0.925, blue: 0.91)
    }
}

/// Decorative washes stay light. `solid` is the deepened color for white text and light-mode labels.
/// Dark-mode capsule text uses `brightLabel` so it is not the same darkened ink.
enum CategoryInk {
    static func wash(_ category: ClipCategory) -> Color {
        switch category {
        case .all: Color(red: 0.34, green: 0.58, blue: 0.95)
        case .pinned: Color(red: 0.92, green: 0.58, blue: 0.23)
        case .text: Color(red: 0.36, green: 0.52, blue: 0.72)
        case .code: Color(red: 0.58, green: 0.46, blue: 0.85)
        case .links: Color(red: 0.36, green: 0.40, blue: 0.84)
        case .images: Color(red: 0.39, green: 0.72, blue: 0.68)
        case .protected: Color(red: 0.83, green: 0.35, blue: 0.31)
        }
    }

    static func solid(_ category: ClipCategory) -> Color {
        switch category {
        case .all: Color(red: 0.15, green: 0.40, blue: 0.78)
        case .pinned: Color(red: 0.72, green: 0.32, blue: 0.08)
        case .text: Color(red: 0.22, green: 0.36, blue: 0.54)
        case .code: Color(red: 0.40, green: 0.28, blue: 0.68)
        case .links: wash(.links)
        case .images: Color(red: 0.12, green: 0.48, blue: 0.44)
        case .protected: Color(red: 0.70, green: 0.22, blue: 0.20)
        }
    }

    static func brightLabel(_ category: ClipCategory) -> Color {
        switch category {
        case .all: Color(red: 0.62, green: 0.78, blue: 1)
        case .pinned: Color(red: 1, green: 0.78, blue: 0.45)
        case .text: Color(red: 0.75, green: 0.86, blue: 1)
        case .code: Color(red: 0.82, green: 0.74, blue: 1)
        case .links: Color(red: 0.72, green: 0.78, blue: 1)
        case .images: Color(red: 0.55, green: 0.90, blue: 0.84)
        case .protected: Color(red: 1, green: 0.62, blue: 0.58)
        }
    }

    static func label(_ category: ClipCategory, colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? brightLabel(category) : solid(category)
    }
}

enum ClipFlowSyntax {
    struct Colors: Equatable {
        var background: String
        var foreground: String
        var keyword: String
        var string: String
        var comment: String
        var number: String
        var title: String
        var attribute: String
        var typeName: String
        var meta: String
        var link: String
        var quote: String
    }

    static func colors(dark: Bool) -> Colors {
        if dark {
            return Colors(
                background: "#262b34", foreground: "#d9e0eb",
                keyword: "#c4a0ff", string: "#9ad5ad", comment: "#8e9bab",
                number: "#efbb86", title: "#91b8ff", attribute: "#8ed2d2",
                typeName: "#e6c482", meta: "#f399a4", link: "#91b8ff", quote: "#aab6c7")
        }
        return Colors(
            background: "#ffffff", foreground: "#263244",
            keyword: "#8554b5", string: "#327b53", comment: "#5C6B7A",
            number: "#ad6431", title: "#3569c8", attribute: "#287d85",
            typeName: "#92701e", meta: "#bc5263", link: "#3569c8", quote: "#61718a")
    }
}
