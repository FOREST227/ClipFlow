import SwiftUI

enum ClipFlowLayout {
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24

    static let pageInset: CGFloat = space16
    static let sectionGap: CGFloat = space16
    static let rowGap: CGFloat = space8
    /// In-window surfaces use the row step. Floating shells use `overlayRadius`.
    static let surfaceRadius: CGFloat = rowRadius
    static let controlRadius: CGFloat = 10
    static let rowRadius: CGFloat = 14
    static let overlayRadius: CGFloat = 22
    static let controlHeight: CGFloat = 32
    static let libraryWidth: CGFloat = 700
    static let libraryMinWidth: CGFloat = 620
    static let libraryMaxWidth: CGFloat = 960
    static let libraryHeight: CGFloat = 780
    static let libraryMinHeight: CGFloat = 560
    static let settingsWidth: CGFloat = libraryWidth
    static let menuWidth: CGFloat = 360
}

struct CleanGlassBackground: View {
    var cornerRadius: CGFloat = ClipFlowLayout.surfaceRadius
    var elevated = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(elevated ? FolioTheme.deckCardFill(depth: 0, for: colorScheme) : FolioTheme.folioPage(for: colorScheme))
            .overlay(shape.strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

/// Detail overlays need a distinct floating shell, separate from the flat page cards.
struct DetailGlassBackground: View {
    var cornerRadius: CGFloat = ClipFlowLayout.overlayRadius
    var compactShadow = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = colorScheme == .dark
        let shell = ClipFlowPalette.detailShellColors(for: dark ? .dark : .light)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(LinearGradient(colors: [shell.top, shell.bottom],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(shape.strokeBorder(LinearGradient(colors: [
            .white.opacity(dark ? 0.32 : 0.85), .white.opacity(dark ? 0.08 : 0.26)
        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: .black.opacity(compactShadow ? 0.12 : (dark ? 0.32 : 0.16)),
            radius: compactShadow ? 6 : 24, y: compactShadow ? 3 : 12)
        .shadow(color: .black.opacity(compactShadow ? 0 : (dark ? 0.12 : 0.05)), radius: 4, y: 2)
        .allowsHitTesting(false)
    }
}

struct LayoutSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(ClipFlowLayout.pageInset)
            .background(CleanGlassBackground())
    }
}

struct ClipFlowBrandMark: View {
    var icon = "cursorarrow.motionlines"
    var size: CGFloat = 36
    var usesAppPalette = false

    private var symbolFill: LinearGradient {
        LinearGradient(colors: usesAppPalette
            ? [Color(red: 0.22, green: 0.42, blue: 0.34),
               Color(red: 0.28, green: 0.49, blue: 0.41)]
            : [.white, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var tileFill: LinearGradient {
        LinearGradient(colors: usesAppPalette
            ? [Color(red: 0.94, green: 0.95, blue: 0.92),
               Color(red: 0.89, green: 0.92, blue: 0.89)]
            : [Color(red: 0.32, green: 0.48, blue: 0.40), ClipCategory.all.tint],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(symbolFill)
            .frame(width: size, height: size)
            .background(
                tileFill,
                in: RoundedRectangle(cornerRadius: size * 0.3)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct ClipFlowActionButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        ClipFlowActionButtonBody(configuration: configuration, fill: fill, foreground: foreground)
    }
}

private struct ClipFlowActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let foreground: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, ClipFlowLayout.space12)
            .frame(height: ClipFlowLayout.controlHeight)
            .background(fill.opacity(configuration.isPressed ? 0.78 : 1), in: shape)
            .overlay {
                if isHovered && !configuration.isPressed {
                    shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06))
                }
            }
            .overlay(shape.strokeBorder(FolioTheme.hairline(for: colorScheme).opacity(isHovered ? 1 : 0.65), lineWidth: 1))
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1 : (isHovered ? -1 : 0)))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : ClipFlowMotion.pressScale)
            .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? 0.15 : 0.12), value: isHovered)
            .animation(reduceMotion ? nil : ClipFlowMotion.press, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

/// Keep translucency on the floating shell, never on its text or image content.
struct FloatingPanelBackground: View {
    let palette: ClipFlowPalette
    var body: some View {
        AppBackground(palette: palette, restrained: true)
    }
}
