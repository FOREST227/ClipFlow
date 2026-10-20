import SwiftUI

enum ClipFlowLayout {
    static let pageInset: CGFloat = 16
    static let sectionGap: CGFloat = 16
    static let rowGap: CGFloat = 8
    static let surfaceRadius: CGFloat = 16
    static let libraryWidth: CGFloat = 500
    static let settingsWidth: CGFloat = 500
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
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
    }
}

struct ClipFlowBrandMark: View {
    var icon = "cursorarrow.motionlines"
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(red: 0.96, green: 0.72, blue: 0.42), ClipCategory.all.tint],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
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
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PageSummaryHeader<Actions: View, Statistics: View>: View {
    let title: String
    let icon: String
    let actions: Actions
    let statistics: Statistics

    init(title: String, icon: String,
         @ViewBuilder actions: () -> Actions,
         @ViewBuilder statistics: () -> Statistics) {
        self.title = title
        self.icon = icon
        self.actions = actions()
        self.statistics = statistics()
    }

    var body: some View {
        ClipFlowBrandSurface {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ClipFlowBrandMark(icon: icon, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text("ClipFlow 剪流").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) { actions }
                }
                .frame(height: 44)
                HStack(spacing: 8) { statistics }
                    .frame(height: 48)
            }
        }
    }
}

struct PageHeaderButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, ClipFlowTab {
    case general = "通用"
    case privacy = "隐私"
    case sync = "同步"
    var id: Self { self }
    var title: String { rawValue }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .privacy: "lock.shield"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}
