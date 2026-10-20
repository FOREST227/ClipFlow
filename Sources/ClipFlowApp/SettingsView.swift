import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var draft: SettingsDraft
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                AppBackground(palette: palette)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 16) {
                PageSummaryHeader(title: "设置", icon: "slider.horizontal.3") {
                    EmptyView()
                } statistics: {
                    CompactStatusPill(title: "监听", value: store.capturePaused ? "已暂停" : "运行中",
                        icon: "waveform", tint: store.capturePaused ? .orange : .green)
                    CompactStatusPill(title: "自动保护", value: store.autoProtectSecrets ? "开启" : "关闭",
                        icon: "lock.shield", tint: ClipCategory.protected.tint)
                    CompactStatusPill(title: "开机启动", value: store.launchAtLogin ? "已启用" : "未启用",
                        icon: "power", tint: ClipCategory.all.tint)
                    CompactStatusPill(title: "文稿同步", value: store.iCloudSyncStatusValue,
                        icon: "folder", tint: store.iCloudSyncTint)
                }
                ClipFlowTabBar(options: SettingsSection.allCases, selection: $draft.section,
                    accessibilityTitle: "设置分类")

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = store.historyLoadError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12)).foregroundStyle(ClipCategory.protected.tint)
                        }
                        switch draft.section {
                        case .general: generalSettings
                        case .privacy: privacySettings
                        case .sync: syncSettings
                        }
                    }
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 6) {
                    Circle().fill(store.capturePaused ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(store.capturePaused ? "剪贴监听已暂停" : "剪贴监听运行中")
                    Spacer()
                    Text("更改即时生效，排除规则需保存")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(ClipFlowLayout.pageInset)
            .frame(maxWidth: ClipFlowLayout.settingsWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: ClipFlowLayout.settingsWidth)
        .frame(minHeight: 600, idealHeight: 640)
        .onDisappear { store.endShortcutRecording() }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            LayoutSurface {
                VStack(alignment: .leading, spacing: 12) {
                    Label("外观", systemImage: "paintpalette.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ClipCategory.quickPaste.tint)
                    ClipFlowTabBar(options: ClipFlowAppearance.allCases, selection: $store.appearanceMode,
                        accessibilityTitle: "外观模式")
                    Text("即时生效 · 跟随系统时自动适配 macOS 外观")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LayoutSurface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("全局快捷键", systemImage: "keyboard")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ClipCategory.all.tint)
                        Spacer()
                        Button("恢复默认") { store.setQuickPasteShortcut(.default) }
                            .font(.system(size: 11))
                            .buttonStyle(.borderless)
                            .disabled(store.isRecordingShortcut)
                            .help("恢复为 ⌥V")
                    }
                    HStack(spacing: 12) {
                        Text("快速粘贴").font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        ShortcutRecorder(store: store).frame(width: 176, height: 36)
                    }
                    Text(store.isRecordingShortcut ? "按下新组合键，Esc 取消" : "点击组合键修改 · 自动保存 · Esc 取消")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = store.shortcutError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(ClipCategory.protected.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LayoutSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Label("启动与运行", systemImage: "power.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ClipCategory.all.tint)
                    SettingsToggleCard(icon: "pause.fill", tint: ClipCategory.all.tint,
                        title: "暂停监听", detail: "暂停记录新内容，已有历史仍可使用。",
                        isOn: $store.capturePaused, showsDivider: true)
                    SettingsToggleCard(icon: "power", tint: ClipCategory.all.tint,
                        title: "开机自动启动", detail: "登录 macOS 后自动运行剪流。",
                        isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }),
                        showsDivider: true)
                    SettingsToggleCard(icon: "menubar.rectangle", tint: ClipCategory.all.tint,
                        title: "启动时打开菜单栏面板", detail: "开启时启动或再次打开 App 会展开菜单栏面板；关闭时打开剪贴历史。",
                        isOn: Binding(get: { store.launchToStatusBar }, set: { store.setLaunchToStatusBar($0) }))
                }
            }
        }
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            LayoutSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Label("敏感内容", systemImage: "lock.shield.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ClipCategory.protected.tint)
                    SettingsToggleCard(icon: "lock.shield", tint: ClipCategory.protected.tint,
                        title: "自动保护疑似敏感内容", detail: "识别验证码、令牌等内容并应用隐私策略。",
                        isOn: $store.autoProtectSecrets, showsDivider: true)
                    SettingsToggleCard(icon: "clock", tint: ClipCategory.protected.tint,
                        title: "5 分钟后自动删除", detail: "按复制时间计算，置顶也会过期。重新开启会清理已超时记录。",
                        isOn: $store.sensitiveAutoExpireEnabled)
                    Text("关闭自动删除后，敏感内容仍遮罩显示、仅本地保存。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LayoutSurface {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(title: "排除应用", detail: "每行一个 Bundle ID，来自这些应用的复制内容不会被记录。")
                    TextEditor(text: $draft.excludedAppsText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackgroundHiddenCompat()
                        .padding(8).frame(height: 136)
                        .background(palette.inputFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border, lineWidth: 1))
                        .accessibilityLabel("排除应用 Bundle ID")
                    HStack {
                        Button("恢复默认") {
                            store.resetExcludedAppsToDefaults()
                            draft.excludedAppsText = store.excludedBundleIDs.joined(separator: "\n")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("保存规则") { store.updateExcludedApps(from: draft.excludedAppsText) }
                            .buttonStyle(DenseClipButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                    }
                }
            }
        }
    }

    private var syncSettings: some View {
        LayoutSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("文稿目录同步", systemImage: "folder.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ClipCategory.smartStacks.tint)
                    Spacer()
                    Text(store.iCloudSyncStatusValue).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.iCloudSyncTint)
                }
                SettingsToggleCard(icon: "folder", tint: ClipCategory.smartStacks.tint,
                    title: "同步普通历史", detail: "将普通文本与图片镜像到“文稿/ClipFlow”。",
                    isOn: Binding(get: { store.iCloudSyncEnabled }, set: { store.setICloudSyncEnabled($0) }))
                Divider()
                Text(store.iCloudSyncDetail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("受保护内容始终保留在本机", systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(ClipCategory.protected.tint)
            }
        }
    }
}
