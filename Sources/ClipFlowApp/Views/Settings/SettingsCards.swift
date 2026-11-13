import SwiftUI

struct IntegrationRow: View {
    let integrations: [IntegrationPill]
    let palette: ClipFlowPalette

    var body: some View {
        FrostedPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("系统级集成")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("原生联动与权限能力")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(integrations) { integration in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(integration.tint.opacity(0.16))
                                    .frame(width: 34, height: 34)

                                Image(systemName: integration.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(integration.tint)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(integration.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(integration.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(palette.softFill)
                        )
                    }
                }
            }
        }
    }
}


struct SettingsStatusPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.13))
        )
    }
}

struct SettingsSectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsToggleCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var showsDivider = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 10)

            if showsDivider {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.leading, 30)
            }
        }
    }
}

