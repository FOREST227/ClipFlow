import SwiftUI

enum ClipFlowLayout {
    static let pageInset: CGFloat = 16
    static let sectionGap: CGFloat = 16
    static let rowGap: CGFloat = 8
    static let surfaceRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let controlHeight: CGFloat = 32
    static let libraryWidth: CGFloat = 460
    static let settingsWidth: CGFloat = libraryWidth
    static let menuWidth: CGFloat = 360
    static let menuHeight: CGFloat = 600
}

struct LayoutSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(ClipFlowLayout.pageInset)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ClipFlowLayout.surfaceRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ClipFlowLayout.surfaceRadius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
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

struct ClipFlowBrandSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(
                        colors: [ClipCategory.quickPaste.tint.opacity(0.12), ClipCategory.all.tint.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct CompactStatusPill: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius))
    }
}

struct ClipFlowActionButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: ClipFlowLayout.controlHeight)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

/// Keep translucency on the floating shell, never on its text or image content.
struct FloatingPanelBackground: View {
    let palette: ClipFlowPalette
    var tintOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Rectangle().fill(.regularMaterial)
            .overlay {
                AppBackground(palette: palette)
                    .opacity(reduceTransparency ? 1 : tintOpacity)
            }
    }
}
