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
            // Calm Warm-Graphite Folio Companion (#191B21 -> #20232A -> #262A34)
            return ClipFlowPalette(
                backgroundStart: Color(red: 0.098, green: 0.106, blue: 0.129),
                backgroundMiddle: Color(red: 0.114, green: 0.125, blue: 0.153),
                backgroundEnd: Color(red: 0.102, green: 0.114, blue: 0.137),
                orbA: Color(red: 0.365, green: 0.522, blue: 0.459).opacity(0.08),
                orbB: Color(red: 0.345, green: 0.486, blue: 0.620).opacity(0.08),
                border: Color.white.opacity(0.09),
                shadow: Color.black.opacity(0.32),
                softFill: Color.white.opacity(0.06),
                rowFill: Color(red: 0.149, green: 0.165, blue: 0.200),
                selectedRowFill: Self.darkSelectedRowFill,
                rowBorder: Color.white.opacity(0.09),
                inputFill: Color(red: 0.094, green: 0.102, blue: 0.125),
                primaryButtonFill: FolioTheme.primaryAccent(for: .dark),
                secondaryButtonFill: Color.white.opacity(0.08)
            )
        }

        // Warm Rice-Paper Linen & Celadon Sage Folio (#F2EFE9 -> #FAF9F5 -> #FFFFFF)
        return ClipFlowPalette(
            backgroundStart: Color(red: 0.949, green: 0.937, blue: 0.914),
            backgroundMiddle: Color(red: 0.965, green: 0.957, blue: 0.937),
            backgroundEnd: Color(red: 0.941, green: 0.929, blue: 0.902),
            orbA: Color(red: 0.322, green: 0.475, blue: 0.400).opacity(0.06),
            orbB: Color(red: 0.722, green: 0.620, blue: 0.490).opacity(0.07),
            border: Self.searchBorder,
            shadow: Color.black.opacity(0.07),
            softFill: Color.white.opacity(0.80),
            rowFill: Color(red: 0.996, green: 0.994, blue: 0.988),
            selectedRowFill: Color(red: 0.922, green: 0.945, blue: 0.933),
            rowBorder: Color(red: 0.855, green: 0.835, blue: 0.792),
            inputFill: Color(red: 0.937, green: 0.925, blue: 0.898),
            primaryButtonFill: CategoryInk.solid(.all),
            secondaryButtonFill: Color(red: 0.937, green: 0.925, blue: 0.898)
        )
    }

    /// Warm stone stroke for light-mode folio surfaces.
    static let searchBorder = Color(red: 0.843, green: 0.824, blue: 0.780)
    /// Dark rows lift calmly toward warm slate so selection is a soft fill.
    static let darkSelectedRowFill = Color(red: 0.188, green: 0.208, blue: 0.255)

    /// Body and status copy under 14pt. Light `#5C5C5C` is >= 6.0:1 on rice-paper; dark keeps system secondary label.
    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(nsColor: .secondaryLabelColor)
            : Color(red: 92.0 / 255, green: 92.0 / 255, blue: 92.0 / 255)
    }

    /// Listening sentence on linen, >= 5.2:1.
    static let listeningStatus = Color(red: 0.14, green: 0.42, blue: 0.31)
    /// Paused sentence on linen, >= 5.0:1.
    static let pausedStatus = Color(red: 0.58, green: 0.32, blue: 0.08)

    static func listeningStatus(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.56, green: 0.82, blue: 0.71) : listeningStatus
    }

    static func pausedStatus(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.94, green: 0.73, blue: 0.47) : pausedStatus
    }

    static func detailShellColors(for colorScheme: ColorScheme) -> (top: Color, bottom: Color) {
        if colorScheme == .dark {
            return (Color(red: 0.149, green: 0.165, blue: 0.204), Color(red: 0.125, green: 0.137, blue: 0.169))
        }
        return (Color(red: 0.992, green: 0.988, blue: 0.976), Color(red: 0.957, green: 0.949, blue: 0.925))
    }

    /// Cover lip samples the shell gradient instead of a third hardcoded gray.
    static func inspectorCover(for colorScheme: ColorScheme) -> Color {
        detailShellColors(for: colorScheme).bottom
    }

    /// Solid sheet drawn over the list when drawer overlay is presented.
    static func inspectorScrim(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.92)
            : Color(red: 0.93, green: 0.915, blue: 0.885).opacity(0.92)
    }
}

/// Low-saturation Morandi mineral inks. `solid` guarantees >= 4.5:1 contrast with white text.
enum CategoryInk {
    static func wash(_ category: ClipCategory) -> Color {
        switch category {
        case .all: Color(red: 0.322, green: 0.475, blue: 0.400)      // Celadon Sage (#527966)
        case .pinned: Color(red: 0.722, green: 0.545, blue: 0.290)   // Warm Sand Ochre
        case .text: Color(red: 0.380, green: 0.470, blue: 0.565)     // Misty Slate
        case .code: Color(red: 0.560, green: 0.450, blue: 0.290)     // Warm Bronze Ochre
        case .links: Color(red: 0.345, green: 0.467, blue: 0.635)    // Fjord Blue
        case .images: Color(red: 0.330, green: 0.565, blue: 0.525)    // Seafoam Mineral
        case .protected: Color(red: 0.722, green: 0.420, blue: 0.322) // Terracotta Clay (#B86B52)
        }
    }

    static func solid(_ category: ClipCategory) -> Color {
        switch category {
        case .all: Color(red: 0.22, green: 0.42, blue: 0.34)
        case .pinned: Color(red: 0.56, green: 0.36, blue: 0.12)
        case .text: Color(red: 0.26, green: 0.35, blue: 0.44)
        case .code: Color(red: 0.44, green: 0.34, blue: 0.20)
        case .links: Color(red: 0.24, green: 0.36, blue: 0.56)
        case .images: Color(red: 0.16, green: 0.44, blue: 0.42)
        case .protected: Color(red: 0.64, green: 0.26, blue: 0.22)
        }
    }

    static func brightLabel(_ category: ClipCategory) -> Color {
        switch category {
        case .all: Color(red: 0.62, green: 0.82, blue: 0.73)
        case .pinned: Color(red: 0.94, green: 0.78, blue: 0.52)
        case .text: Color(red: 0.74, green: 0.82, blue: 0.92)
        case .code: Color(red: 0.88, green: 0.78, blue: 0.62)
        case .links: Color(red: 0.70, green: 0.78, blue: 0.96)
        case .images: Color(red: 0.58, green: 0.84, blue: 0.80)
        case .protected: Color(red: 0.94, green: 0.64, blue: 0.56)
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
                background: "#1c1f27", foreground: "#dce1ea",
                keyword: "#8eb4d9", string: "#8fc2a9", comment: "#7e8796",
                number: "#deb488", title: "#86aed6", attribute: "#89c0bf",
                typeName: "#d9be88", meta: "#d9949a", link: "#86aed6", quote: "#a0aab8")
        }
        return Colors(
            background: "#f6f4ee", foreground: "#2c2b28",
            keyword: "#4a6b5b", string: "#3b6e52", comment: "#5C6B7A",
            number: "#9c5e35", title: "#3a5a82", attribute: "#306e72",
            typeName: "#826425", meta: "#a64c55", link: "#3a5a82", quote: "#66625a")
    }
}
