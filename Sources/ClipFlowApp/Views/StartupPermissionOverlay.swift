import SwiftUI

struct StartupPermissionOverlay: View {
    let report: ClipFlowPermissionReport
    let palette: ClipFlowPalette
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onRequestAccessibility: () -> Void
    let onOpenAccessibilitySettings: () -> Void

    var body: some View {
        FrostedPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill((report.needsAttention ? ClipCategory.protected.tint : ClipCategory.images.tint).opacity(0.16))
                                .frame(width: 42, height: 42)

                            Image(systemName: report.needsAttention ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(report.needsAttention ? ClipCategory.protected.tint : ClipCategory.images.tint)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.title)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            Text(report.message)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(spacing: 10) {
                    ForEach(report.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(item.status.tint.opacity(0.14))
                                    .frame(width: 38, height: 38)

                                Image(systemName: item.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(item.status.tint)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title)
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Text(item.status.label)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(item.status.tint)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(item.status.tint.opacity(0.14))
                                        )
                                }

                                Text(item.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(palette.softFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(palette.border.opacity(0.64), lineWidth: 1)
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button("继续使用", action: onDismiss)
                            .buttonStyle(ClipButtonStyle(fill: palette.secondaryButtonFill))

                        Button("重新检测", action: onRefresh)
                            .buttonStyle(ClipButtonStyle(fill: palette.secondaryButtonFill))
                    }

                    if report.items.contains(where: { $0.title == "辅助功能" && $0.status == .needsAttention }) {
                        HStack(spacing: 10) {
                            Button("打开系统设置", action: onOpenAccessibilitySettings)
                                .buttonStyle(ClipButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                                .help("系统设置 → 隐私与安全性 → 辅助功能")
                            Button("请求辅助功能权限", action: onRequestAccessibility)
                                .buttonStyle(ClipButtonStyle(fill: palette.secondaryButtonFill))
                        }
                    }
                }
            }
        }
    }
}
