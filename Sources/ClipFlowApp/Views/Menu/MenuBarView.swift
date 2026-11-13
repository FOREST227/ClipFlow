import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipFlowStore
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuPanelHeader(store: store)
            VStack(spacing: 0) {
                statusToggle("剪贴板监听", icon: "waveform", tint: ClipCategory.all.tint,
                    isOn: Binding(get: { !store.capturePaused }, set: { store.capturePaused = !$0 }))
                    .help("关闭后暂停记录新内容，已有历史仍可使用")
                Divider()
                statusToggle("敏感内容保护", icon: "lock.shield", tint: ClipCategory.protected.tint,
                    isOn: $store.autoProtectSecrets)
                    .help("自动识别验证码、令牌等疑似敏感内容")
                Divider()
                statusToggle("敏感内容 5 分钟过期", icon: "clock", tint: ClipCategory.protected.tint,
                    isOn: $store.sensitiveAutoExpireEnabled)
                    .help("按复制时间计算，置顶也会过期；重新开启将清理已超时的敏感记录")
                Divider()
                statusToggle("开机自动启动", icon: "power", tint: ClipCategory.all.tint,
                    isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(ClipCategory.images.tint).frame(width: 16)
                    Text("文稿同步")
                    Spacer()
                    Text(store.iCloudSyncStatusValue).foregroundStyle(store.iCloudSyncTint)
                    Toggle("文稿同步", isOn: Binding(get: { store.iCloudSyncEnabled },
                        set: { store.setICloudSyncEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel("启用文稿同步")
                }
                .font(.system(size: 11)).frame(height: 34)
                .help(store.iCloudSyncDetail)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(CleanGlassBackground(cornerRadius: 14))

            if store.accessibilityTrusted == false {
                VStack(alignment: .leading, spacing: 8) {
                    Text("自动粘贴需要辅助功能权限。未授权时会改为复制到剪贴板，请在目标应用中手动粘贴。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置") {
                        _ = AccessibilityTrust.openSystemSettings()
                    }
                    .buttonStyle(MenuFooterActionStyle(fill: ClipCategory.protected.tint.opacity(0.16)))
                    .help("系统设置 → 隐私与安全性 → 辅助功能")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(CleanGlassBackground(cornerRadius: 14))
            }

            HStack(spacing: 8) {
                Button("快速粘贴") {
                    AppNavigationCenter.shared.dismissMenuBarPopover?()
                    ClipFlowRuntime.shared.showHUD()
                }
                .buttonStyle(MenuFooterActionStyle(fill: ClipCategory.all.tint.opacity(0.13)))
                .help("打开快速粘贴面板（\(store.quickPasteShortcut.displayName)）")
                Button("历史记录") { AppNavigationCenter.shared.openLibrary() }
                    .buttonStyle(MenuFooterActionStyle(fill: Color.primary.opacity(0.045)))
                Button("设置") { AppNavigationCenter.shared.openSettings() }
                    .buttonStyle(MenuFooterActionStyle(fill: Color.primary.opacity(0.045)))
                Spacer(minLength: 0)
                Menu {
                    Button("重启 ClipFlow") { ClipFlowRuntime.shared.restartApplication() }
                    Button("退出 ClipFlow") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "power").frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("电源操作")
                .help("重启或退出 ClipFlow")
            }
            Text(store.statusSummary).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).help(store.statusSummary)
        }
        .padding(16)
        // The popover takes its height from this content.
        .frame(width: ClipFlowLayout.menuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                FloatingPanelBackground(palette: palette)
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }
            .allowsHitTesting(false)
        }
    }

    private func statusToggle(_ title: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .frame(height: 34)
    }
}

struct MenuPanelHeader: View {
    @ObservedObject var store: ClipFlowStore
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("ClipFlow 剪流").font(.system(size: 14, weight: .bold, design: .rounded))
                Label(store.capturePaused ? "监听已暂停" : "正在监听", systemImage: store.capturePaused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(store.capturePaused ? Color.orange : Color.green)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.items.count) 条历史").font(.system(size: 11, weight: .medium)).monospacedDigit()
                Text("\(store.quickPasteShortcut.displayName) 呼出").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 4)
    }
}

struct MenuSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
            Spacer()
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
    }
}

struct MenuStatPill: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0.11)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.95))

                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.58), tint.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.38), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
        )
        .shadow(color: tint.opacity(0.10), radius: 8, x: 0, y: 4)
    }
}

struct MenuEmptyStateCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ClipCategory.images.tint)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

struct MenuCompactActionLabel: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 28, height: 28)

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
    }
}

struct MenuCompactButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = Color.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

struct MenuFooterActionStyle: ButtonStyle {
    let fill: Color
    var height: CGFloat = 28
    var fontSize: CGFloat = 11
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.65 : 0.85))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct MenuTileButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = Color.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(configuration.isPressed ? 0.988 : 1)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(10)
            .scaleEffect(configuration.isPressed ? 0.988 : 1)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

