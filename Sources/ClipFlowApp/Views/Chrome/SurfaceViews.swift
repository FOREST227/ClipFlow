import SwiftUI

struct AppBackground: View {
    let palette: ClipFlowPalette
    var restrained = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: restrained
                    ? (colorScheme == .dark
                        ? [Color(red: 0.10, green: 0.11, blue: 0.14), Color(red: 0.11, green: 0.13, blue: 0.16)]
                        : [Color(red: 0.97, green: 0.965, blue: 0.955),
                           Color(red: 0.955, green: 0.97, blue: 0.985),
                           Color(red: 0.965, green: 0.965, blue: 0.98)])
                    : [palette.backgroundStart, palette.backgroundMiddle, palette.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(palette.orbA.opacity(restrained ? 0.45 : 1))
                .frame(width: 420, height: 420)
                .blur(radius: 60)
                .offset(x: -160, y: -80)

            Circle()
                .fill(palette.orbB.opacity(restrained ? 0.45 : 1))
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: 180, y: 140)
        }
    }
}

struct FrostedPanel<Content: View>: View {
    let palette: ClipFlowPalette
    @ViewBuilder var content: Content

    init(palette: ClipFlowPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        content
            .padding(ClipFlowLayout.space16)
            .background(CleanGlassBackground(cornerRadius: ClipFlowLayout.overlayRadius, elevated: true))
    }
}

struct HeaderBadge: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 34, height: 34)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.18))
        )
    }
}

struct HeroSignalPill: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

struct HeaderOverviewCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 34, height: 34)

                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }

                Spacer()

                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct CategoryPill: View {
    static let height: CGFloat = 28
    let category: ClipCategory
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(category.shortTitle).font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            Text("\(count)").monospacedDigit().font(.system(size: 10, weight: .medium))
        }
        .lineLimit(1).fixedSize()
        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.8))
        .padding(.horizontal, ClipFlowLayout.space12)
        .frame(height: Self.height)
        .background(isSelected ? category.solid : Color.primary.opacity(0.05), in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.title)，\(count) 条")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

struct PrivacyRuleRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClipCategory.protected.tint)
                .frame(width: 18, height: 18)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ClipCategory.protected.tint.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MetricCard: View {
    let metric: FlowMetric
    let palette: ClipFlowPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(metric.tint.opacity(0.14))
                        .frame(width: 38, height: 38)

                    Image(systemName: metric.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(metric.tint)
                }

                Spacer(minLength: 10)

                Text(metric.value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(metric.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(metric.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border.opacity(0.55), lineWidth: 1)
        )
    }
}

struct EmptyStateCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

struct EmptyStateBadge: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ClipCategory.pinned.tint)
                .frame(width: 16, height: 16)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ClipCategory.pinned.tint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

struct StepRow: View {
    let index: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(index)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(ClipCategory.pinned.tint)
                )

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
    }
}

struct InfoStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

