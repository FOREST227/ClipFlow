import AppKit
import SwiftUI

// MARK: - Unified 5-Step Typography Scale (tasteskill system.md)

enum ClipFlowType {
    static let sectionTitle: CGFloat = 15
    static let cardTitle: CGFloat = 13
    static let body: CGFloat = 12
    static let meta: CGFloat = 11
    /// Strict minimum font floor across all labels, counts, and keycaps.
    static let mono: CGFloat = 10
}

// MARK: - Unified Folio Button System & Fine-Pointer Hover Layer (tasteskill motion.md)

enum FolioButtonProminence {
    case primary
    case secondary
    case tonalAccent
}

struct FolioButtonStyle: ButtonStyle {
    var prominence: FolioButtonProminence = .secondary
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 11
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        FolioButtonBody(
            configuration: configuration,
            prominence: prominence,
            height: height,
            horizontalPadding: horizontalPadding,
            cornerRadius: cornerRadius
        )
    }
}

private struct FolioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominence: FolioButtonProminence
    let height: CGFloat
    let horizontalPadding: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var baseFill: Color {
        switch prominence {
        case .primary:
            return FolioTheme.primaryAccent(for: colorScheme)
        case .secondary:
            return FolioTheme.recessedWell(for: colorScheme)
        case .tonalAccent:
            return FolioTheme.sageAccent(for: colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
    }

    private var foreground: Color {
        switch prominence {
        case .primary:
            return .white
        case .secondary:
            return Color.primary.opacity(0.88)
        case .tonalAccent:
            return FolioTheme.sageAccent(for: colorScheme)
        }
    }

    private var borderColor: Color {
        switch prominence {
        case .primary:
            return .clear
        case .secondary:
            return isHovered ? FolioTheme.strongHairline(for: colorScheme) : FolioTheme.hairline(for: colorScheme)
        case .tonalAccent:
            return FolioTheme.sageAccent(for: colorScheme).opacity(isHovered ? 0.55 : 0.32)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: ClipFlowType.meta, weight: prominence == .secondary ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(baseFill.opacity(configuration.isPressed ? 0.82 : 1), in: shape)
            .overlay {
                if isHovered && !configuration.isPressed {
                    shape.fill(
                        prominence == .primary
                            ? Color.black.opacity(0.12)
                            : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
                    )
                }
            }
            .overlay(shape.strokeBorder(borderColor, lineWidth: prominence == .primary ? 0 : 1))
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1 : (isHovered ? -1 : 0)))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : ClipFlowMotion.pressScale)
            .contentShape(shape)
            .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? 0.15 : 0.12), value: isHovered)
            .animation(reduceMotion ? nil : ClipFlowMotion.press, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Calm Folio Color Tokens (Warm Rice-Paper Linen & Quiet Graphite)

enum FolioTheme {
    /// Outer gutter behind protruding spine tabs.
    static func spineGutter(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.098, green: 0.106, blue: 0.129) // #191B21
            : Color(red: 0.918, green: 0.902, blue: 0.867) // #EAE6DD
    }

    /// Main inner folio sheet surface — matches the active spine tab so they merge seamlessly.
    static func folioPage(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.125, green: 0.137, blue: 0.165) // #20232A
            : Color(red: 0.980, green: 0.976, blue: 0.961) // #FAF9F5
    }

    /// Recessed tray for Search, Paste Stack, and Time Dial.
    static func recessedWell(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.094, green: 0.102, blue: 0.125) // #181A20
            : Color(red: 0.937, green: 0.925, blue: 0.898) // #EFECE5
    }

    /// Paper card surfaces stepped by Z-depth layer (0 = front card, 1...3 = peeking background cards).
    static func deckCardFill(depth: Int, for scheme: ColorScheme) -> Color {
        if scheme == .dark {
            switch depth {
            case 0: return Color(red: 0.149, green: 0.165, blue: 0.204) // #262A34
            case 1: return Color(red: 0.133, green: 0.149, blue: 0.184) // #22262F
            case 2: return Color(red: 0.118, green: 0.131, blue: 0.163) // #1E212A
            default: return Color(red: 0.106, green: 0.118, blue: 0.147) // #1B1E25
            }
        } else {
            switch depth {
            case 0: return Color.white
            case 1: return Color(red: 0.957, green: 0.949, blue: 0.925) // #F4F2EC
            case 2: return Color(red: 0.929, green: 0.918, blue: 0.886) // #EDEAE2
            default: return Color(red: 0.902, green: 0.886, blue: 0.851) // #E6E2D9
            }
        }
    }

    /// Continuous RGB interpolation of archival paper depth (`0.0 ... 3.0`) so scrolling
    /// through the filing box glides smoothly with ZERO discrete color flashing or strobing.
    static func deckCardFill(continuousDepth: CGFloat, for scheme: ColorScheme) -> Color {
        let t = Double(min(1, max(0, continuousDepth / 3.0)))
        if scheme == .dark {
            let r = 0.149 + (0.106 - 0.149) * t
            let g = 0.165 + (0.118 - 0.165) * t
            let b = 0.204 + (0.147 - 0.204) * t
            return Color(red: r, green: g, blue: b)
        } else {
            let r = 1.000 + (0.902 - 1.000) * t
            let g = 1.000 + (0.886 - 1.000) * t
            let b = 1.000 + (0.851 - 1.000) * t
            return Color(red: r, green: g, blue: b)
        }
    }

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.09)
            : Color(red: 0.863, green: 0.843, blue: 0.800) // #DCD7CC
    }

    static func strongHairline(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.20)
            : Color(red: 0.725, green: 0.698, blue: 0.643) // #B9B2A4
    }

    /// Single unified primary accent (Celadon Sage across both Light & Dark — zero violet/lavender).
    static func primaryAccent(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.239, green: 0.412, blue: 0.349) // #3D6959 (>= 6.2:1 with white text)
            : Color(red: 0.220, green: 0.420, blue: 0.340) // #386B56 (>= 5.8:1 with white text)
    }

    /// Sage ink for labels, badges, and tonal strokes (>= 4.5:1 on folio surfaces).
    static func sageAccent(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.467, green: 0.725, blue: 0.624) // #77B99F
            : Color(red: 0.200, green: 0.400, blue: 0.318) // #336651
    }

    /// Distinct Morandi mineral tints for inactive protruding spine tabs (high legibility in Dark Mode, zero violet).
    static func spineTabFill(for category: ClipCategory?, isSettings: Bool = false, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            if isSettings { return Color(red: 0.133, green: 0.149, blue: 0.188) }
            switch category {
            case .all, .none: return Color(red: 0.149, green: 0.169, blue: 0.212)   // cool graphite
            case .pinned: return Color(red: 0.122, green: 0.220, blue: 0.190)      // celadon sage
            case .text: return Color(red: 0.137, green: 0.188, blue: 0.251)        // porcelain slate
            case .code: return Color(red: 0.235, green: 0.188, blue: 0.125)        // warm amber-ochre
            case .links: return Color(red: 0.114, green: 0.196, blue: 0.271)       // fjord blue
            case .images: return Color(red: 0.110, green: 0.218, blue: 0.231)      // seafoam teal
            case .protected: return Color(red: 0.243, green: 0.137, blue: 0.137)   // terracotta clay
            }
        } else {
            if isSettings { return Color(red: 0.886, green: 0.875, blue: 0.847) }
            switch category {
            case .all, .none: return Color(red: 0.910, green: 0.898, blue: 0.871)
            case .pinned: return Color(red: 0.788, green: 0.835, blue: 0.808) // Morandi celadon
            case .code: return Color(red: 0.878, green: 0.847, blue: 0.788)   // warm sand-ochre
            case .text: return Color(red: 0.835, green: 0.855, blue: 0.878)   // misty porcelain
            case .links: return Color(red: 0.800, green: 0.839, blue: 0.875)  // mineral fjord-blue (no lavender)
            case .images: return Color(red: 0.788, green: 0.835, blue: 0.839) // seafoam mist
            case .protected: return Color(red: 0.871, green: 0.816, blue: 0.804) // muted terracotta
            }
        }
    }

    /// High-contrast mineral accent color for each spine tab's leading edge bar & count ink.
    static func spineTabAccent(for category: ClipCategory?, isSettings: Bool = false, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            if isSettings { return Color(red: 0.620, green: 0.663, blue: 0.741) }
            switch category {
            case .all, .none: return Color(red: 0.643, green: 0.706, blue: 0.796)   // silver-slate
            case .pinned: return Color(red: 0.439, green: 0.784, blue: 0.647)      // bright celadon sage
            case .text: return Color(red: 0.569, green: 0.733, blue: 0.925)        // bright porcelain blue
            case .code: return Color(red: 0.906, green: 0.714, blue: 0.427)        // bright warm ochre
            case .links: return Color(red: 0.443, green: 0.737, blue: 0.933)       // bright fjord azure
            case .images: return Color(red: 0.396, green: 0.796, blue: 0.796)      // bright seafoam
            case .protected: return Color(red: 0.918, green: 0.518, blue: 0.494)   // bright terracotta coral
            }
        } else {
            if isSettings { return Color(red: 0.44, green: 0.43, blue: 0.40) }
            switch category {
            case .all, .none: return Color(red: 0.35, green: 0.37, blue: 0.39)
            case .pinned: return Color(red: 0.20, green: 0.45, blue: 0.35)
            case .text: return Color(red: 0.25, green: 0.40, blue: 0.54)
            case .code: return Color(red: 0.60, green: 0.42, blue: 0.16)
            case .links: return Color(red: 0.18, green: 0.42, blue: 0.62)
            case .images: return Color(red: 0.16, green: 0.46, blue: 0.48)
            case .protected: return Color(red: 0.64, green: 0.26, blue: 0.24)
            }
        }
    }
}

// MARK: - App Icon Resolver & Badge

@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()
    private let cache = NSCache<NSString, NSImage>()
    private var missingIDs = Set<String>()

    private let fallbackBundleIDs: [String: String] = [
        "Xcode": "com.apple.dt.Xcode",
        "Safari": "com.apple.Safari",
        "终端": "com.apple.Terminal",
        "Terminal": "com.apple.Terminal",
        "预览": "com.apple.Preview",
        "Preview": "com.apple.Preview",
        "备忘录": "com.apple.Notes",
        "Notes": "com.apple.Notes",
        "文本编辑": "com.apple.TextEdit",
        "TextEdit": "com.apple.TextEdit",
        "信息": "com.apple.MobileSMS",
        "Messages": "com.apple.MobileSMS",
        "访达": "com.apple.finder",
        "Finder": "com.apple.finder"
    ]

    func icon(bundleID: String?, sourceApp: String) -> NSImage? {
        let resolvedID = (bundleID?.isEmpty == false ? bundleID : nil) ?? fallbackBundleIDs[sourceApp]
        guard let resolvedID else { return nil }
        if let cached = cache.object(forKey: resolvedID as NSString) {
            return cached
        }
        if missingIDs.contains(resolvedID) {
            return nil
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: resolvedID) else {
            missingIDs.insert(resolvedID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        cache.setObject(image, forKey: resolvedID as NSString)
        return image
    }

    func prewarm(items: [ClipboardItem]) {
        var seen = Set<String>()
        for item in items {
            let key = item.sourceBundleID ?? item.sourceApp
            if seen.insert(key).inserted {
                _ = icon(bundleID: item.sourceBundleID, sourceApp: item.sourceApp)
            }
        }
    }
}

struct AppIconBadgeView: View {
    let item: ClipboardItem
    var size: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let nsImage = AppIconResolver.shared.icon(bundleID: item.sourceBundleID, sourceApp: item.sourceApp) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(item.kind.tint.opacity(colorScheme == .dark ? 0.22 : 0.15))
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(item.kind.labelColor(for: colorScheme))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - 5-Minute Sensitive Expiry Countdown Ring

struct ExpiryCountdownRing: View {
    let item: ClipboardItem
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if item.autoExpire, let expiresAt = item.expiresAt {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let remaining = max(0, expiresAt.timeIntervalSince(context.date))
                let total = max(1, expiresAt.timeIntervalSince(item.captureTimestamp))
                let progress = min(1, max(0, remaining / total))
                let label = Self.format(seconds: Int(ceil(remaining)))
                let accent = ClipCategory.protected.labelColor(for: colorScheme)

                if compact {
                    HStack(spacing: 3.5) {
                        ZStack {
                            Circle()
                                .stroke(accent.opacity(0.20), lineWidth: 1.8)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 10, height: 10)

                        Text(label)
                            .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .fixedSize()
                    .accessibilityLabel("剩余 \(label) 过期")
                } else {
                    ZStack {
                        Circle()
                            .stroke(accent.opacity(0.18), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(label)
                            .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 38, height: 38)
                    .accessibilityLabel("剩余 \(label) 自动销毁")
                }
            }
        }
    }

    static func format(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Left Protruding Stationery Spine Index Tabs (Concept 2)

/// Rounded on the leading (outer) edge, flat on the trailing edge where it meets the Folio sheet.
struct FolioSpineTabShape: Shape {
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Three-sided outer border (top, leading, bottom) so an active spine tab merges seamlessly into the page.
struct FolioSpineTabOpenBorder: Shape {
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

struct FolioSpineTabsView: View {
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var navigation: MainWindowNavigation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let spineWidth: CGFloat = 42

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Spacer().frame(height: 38)

            ForEach(ClipCategory.allCases) { category in
                let active = navigation.page == .history && store.selectedCategory == category
                spineButton(
                    title: category.shortTitle,
                    count: store.count(for: category),
                    fill: active
                        ? FolioTheme.folioPage(for: colorScheme)
                        : FolioTheme.spineTabFill(for: category, scheme: colorScheme),
                    accent: FolioTheme.spineTabAccent(for: category, scheme: colorScheme),
                    isSelected: active,
                    accessibilityTitle: "\(category.title)，\(store.count(for: category)) 条"
                ) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                        store.selectedCategory = category
                        navigation.select(.history)
                    }
                }
            }

            Spacer(minLength: 6)

            let snippetsSelected = navigation.page == .snippets
            spineButton(
                title: "片段",
                count: store.snippets.count,
                fill: snippetsSelected
                    ? FolioTheme.folioPage(for: colorScheme)
                    : FolioTheme.spineTabFill(for: .pinned, scheme: colorScheme),
                accent: FolioTheme.spineTabAccent(for: .pinned, scheme: colorScheme),
                isSelected: snippetsSelected,
                accessibilityTitle: "常用片段，\(store.snippets.count) 个"
            ) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                    navigation.select(.snippets)
                }
            }

            let settingsSelected = navigation.page == .settings
            spineButton(
                title: "设置",
                count: nil,
                icon: "gearshape",
                fill: settingsSelected
                    ? FolioTheme.folioPage(for: colorScheme)
                    : FolioTheme.spineTabFill(for: nil, isSettings: true, scheme: colorScheme),
                accent: FolioTheme.spineTabAccent(for: nil, isSettings: true, scheme: colorScheme),
                isSelected: settingsSelected,
                accessibilityTitle: "偏好设置"
            ) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                    navigation.select(.settings)
                }
            }

            Spacer().frame(height: 28)
        }
        .frame(width: Self.spineWidth)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("活页书口分类折签")
    }

    private func spineButton(
        title: String,
        count: Int?,
        icon: String? = nil,
        fill: Color,
        accent: Color,
        isSelected: Bool,
        accessibilityTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        FolioSpineTabItem(
            title: title,
            count: count,
            icon: icon,
            fill: fill,
            accent: accent,
            isSelected: isSelected,
            accessibilityTitle: accessibilityTitle,
            action: action
        )
    }
}

private struct FolioSpineTabItem: View {
    let title: String
    let count: Int?
    let icon: String?
    let fill: Color
    let accent: Color
    let isSelected: Bool
    let accessibilityTitle: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let isDark = colorScheme == .dark
        let titleColor: Color = {
            if isSelected {
                return isDark ? Color.white : Color.primary
            }
            if isHovered {
                return isDark ? Color.white.opacity(0.96) : Color.primary
            }
            return isDark ? Color.white.opacity(0.84) : ClipFlowPalette.secondaryText(for: colorScheme)
        }()
        let countColor: Color = {
            if isDark {
                return isSelected ? accent : accent.opacity(0.88)
            }
            return isSelected ? accent : ClipFlowPalette.secondaryText(for: colorScheme).opacity(0.82)
        }()

        Button(action: action) {
            VStack(spacing: 2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: ClipFlowType.meta, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(titleColor)
                }
                Text(title)
                    .font(.system(size: ClipFlowType.meta, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: ClipFlowType.mono, weight: isSelected ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(countColor)
                }
            }
            .padding(.leading, isSelected ? 2 : 0)
            .frame(width: isSelected ? FolioSpineTabsView.spineWidth : (isHovered ? FolioSpineTabsView.spineWidth - 3 : FolioSpineTabsView.spineWidth - 5), height: 42)
            .background(FolioSpineTabShape(radius: 9).fill(fill))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(accent)
                        .frame(width: 3, height: 22)
                        .padding(.leading, 3)
                }
            }
            .overlay {
                if isHovered && !isSelected {
                    FolioSpineTabShape(radius: 9)
                        .fill(Color.primary.opacity(isDark ? 0.08 : 0.04))
                }
            }
            .overlay(
                FolioSpineTabOpenBorder(radius: 9)
                    .stroke(
                        isSelected
                            ? (isDark ? accent.opacity(0.65) : FolioTheme.strongHairline(for: colorScheme))
                            : (isHovered ? FolioTheme.strongHairline(for: colorScheme) : (isDark ? accent.opacity(0.24) : FolioTheme.hairline(for: colorScheme))),
                        lineWidth: 1
                    )
            )
            // Overlap the Folio sheet's 1pt leading border when active so tab + page join seamlessly.
            .offset(x: isSelected ? 1.5 : 0)
            .contentShape(FolioSpineTabShape(radius: 9))
            .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? 0.15 : 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Sequential Paste Queue Tray ("顺序粘贴 · ① → ② → ③")

struct PasteStackTrayView: View {
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var pasteStack: PasteStackState
    let onPasteNext: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let queued = pasteStack.queuedItems(from: store.items)
        if !queued.isEmpty || pasteStack.autoCollectEnabled {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: pasteStack.autoCollectEnabled ? "tray.and.arrow.down.fill" : "square.stack.3d.down.right")
                        .font(.system(size: ClipFlowType.meta, weight: .semibold))
                        .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                    Text("顺序粘贴")
                        .font(.system(size: ClipFlowType.meta, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.88))
                }
                .fixedSize()

                if queued.isEmpty {
                    Text("自动加入中：新复制的内容将按 ①→②→③ 排队")
                        .font(.system(size: ClipFlowType.meta))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                    Button {
                        withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                            pasteStack.autoCollectEnabled = false
                        }
                    } label: {
                        Text("关闭自动加入")
                    }
                    .buttonStyle(FolioButtonStyle(
                        prominence: .tonalAccent,
                        height: 24,
                        horizontalPadding: 9,
                        cornerRadius: 7
                    ))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(queued.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 5) {
                                    Text("\(index + 1)")
                                        .font(.system(size: ClipFlowType.mono, weight: .bold, design: .monospaced))
                                        .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                                        .frame(width: 15, height: 15)
                                        .background(FolioTheme.sageAccent(for: colorScheme).opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    Text(Self.shortLabel(for: item, store: store))
                                        .font(.system(size: ClipFlowType.meta, weight: .medium))
                                        .lineLimit(1)
                                        .frame(maxWidth: 108)
                                    Button {
                                        withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                                            pasteStack.remove(item.id)
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: ClipFlowType.mono - 1, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("移出排队")
                                }
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .background(FolioTheme.deckCardFill(depth: 0, for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))

                                if index + 1 < queued.count {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: ClipFlowType.mono, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                            pasteStack.autoCollectEnabled.toggle()
                        }
                    } label: {
                        Image(systemName: pasteStack.autoCollectEnabled ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                            .font(.system(size: ClipFlowType.meta, weight: .semibold))
                            .foregroundStyle(pasteStack.autoCollectEnabled ? FolioTheme.sageAccent(for: colorScheme) : ClipFlowPalette.secondaryText(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .help(pasteStack.autoCollectEnabled ? "关闭自动加入" : "开启自动加入")

                    Button {
                        withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                            pasteStack.clear()
                        }
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: ClipFlowType.body))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空排队")

                    // Tonal-accent secondary prominence so the screen keeps strictly ONE filled primary button ("粘贴 ↩").
                    Button(action: onPasteNext) {
                        HStack(spacing: 4) {
                            Text("粘贴下一条")
                            Text("↩").font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                        }
                    }
                    .buttonStyle(FolioButtonStyle(
                        prominence: .tonalAccent,
                        height: 26,
                        horizontalPadding: 10,
                        cornerRadius: 7
                    ))
                    .help("粘贴第 1 条并自动切到下一条")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
                    .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    static func shortLabel(for item: ClipboardItem, store: ClipFlowStore) -> String {
        if item.isSensitive && !store.isRevealed(item) {
            return "敏感记录"
        }
        if item.isImage {
            return item.title
        }
        let first = ClipboardCardSummary.plainFirstLine(of: store.displayFullText(for: item))
        return first.isEmpty ? item.title : first
    }
}

/// Compact subheader trigger shown only when the Paste Queue tray is collapsed (empty & auto-collect off).
struct PasteStackSubheaderToggle: View {
    @ObservedObject var pasteStack: PasteStackState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if pasteStack.queuedIDs.isEmpty && !pasteStack.autoCollectEnabled {
            Button {
                withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                    pasteStack.autoCollectEnabled = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: ClipFlowType.mono, weight: .semibold))
                        .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                    Text("顺序粘贴")
                        .font(.system(size: ClipFlowType.meta, weight: .medium))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("开启顺序粘贴：自动将新复制的内容按 ①→②→③ 排队依次粘贴")
        }
    }
}

// MARK: - Subtle Tactile Keycap Badge

struct TactileKeycap: View {
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(FolioTheme.deckCardFill(depth: 0, for: colorScheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.06), radius: 0, x: 0, y: 1)
    }
}
