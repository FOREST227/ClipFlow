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
    static let libraryWidth: CGFloat = 620
    static let libraryMaxWidth: CGFloat = 880
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
        let dark = colorScheme == .dark
        let opaque = reduceTransparency || elevated
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(LinearGradient(colors: dark
            ? [Color(red: 0.17, green: 0.19, blue: 0.23).opacity(opaque ? 1 : 0.94),
               Color(red: 0.14, green: 0.16, blue: 0.20).opacity(opaque ? 1 : 0.88)]
            : [Color.white.opacity(reduceTransparency ? 1 : (elevated ? 0.98 : 0.88)),
               Color.white.opacity(reduceTransparency ? 1 : (elevated ? 0.96 : 0.62))],
            startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.strokeBorder(LinearGradient(colors: [
                .white.opacity(dark ? 0.20 : 0.95),
                .white.opacity(dark ? 0.04 : 0.35)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.12 : 0.035), radius: 8, y: 3)
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
            ? [Color(red: 0.843, green: 0.686, blue: 0.486),
               Color(red: 0.694, green: 0.714, blue: 0.835),
               Color(red: 0.345, green: 0.580, blue: 0.871)]
            : [.white, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var tileFill: LinearGradient {
        LinearGradient(colors: usesAppPalette
            ? [Color(red: 0.98, green: 0.95, blue: 0.90),
               Color(red: 0.93, green: 0.96, blue: 0.99),
               Color(red: 0.95, green: 0.93, blue: 0.98)]
            : [Color(red: 0.96, green: 0.72, blue: 0.42), ClipCategory.all.tint],
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, ClipFlowLayout.space12)
            .frame(height: ClipFlowLayout.controlHeight)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : ClipFlowMotion.pressScale)
            .animation(reduceMotion ? nil : ClipFlowMotion.press, value: configuration.isPressed)
    }
}

/// Keep translucency on the floating shell, never on its text or image content.
struct FloatingPanelBackground: View {
    let palette: ClipFlowPalette
    var body: some View {
        AppBackground(palette: palette, restrained: true)
    }
}
