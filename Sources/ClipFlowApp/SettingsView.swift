import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "通用"
    case privacy = "隐私"
    case sync = "同步"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .privacy: "lock.shield"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "外观、快捷键与运行方式"
        case .privacy: "敏感内容保护与应用排除规则"
        case .sync: "在设备之间同步普通历史"
        }
    }
}

struct SettingsView: View {
    var showsBackground = true
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var draft: SettingsDraft
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }

    var body: some View {
        ZStack {
            if showsBackground {
                GeometryReader { proxy in
                    AppBackground(palette: palette, restrained: true)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.section.rawValue)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityLabel("\(draft.section.rawValue)。\(draft.section.subtitle)")
                    }
                    .padding(.horizontal, 2)
                    SoftEdgeScrollView {
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
                    .id(draft.section)
                    .transition(.asymmetric(
                        insertion: .offset(y: draft.movesForward ? 10 : -10).combined(with: .opacity),
                        removal: .opacity))
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(reduceMotion ? nil : ClipFlowMotion.pageSwitch, value: draft.section)

                HStack(spacing: 6) {
                    Circle().fill(store.capturePaused ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(store.capturePaused ? "剪贴监听已暂停" : "剪贴监听运行中")
                        .foregroundStyle(store.capturePaused
                            ? ClipFlowPalette.pausedStatus(for: colorScheme)
                            : ClipFlowPalette.listeningStatus(for: colorScheme))
                    Spacer()
                    Text(draft.section == .privacy ? "敏感内容即时生效，排除规则需保存" : "更改即时生效")
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                }
                .font(.system(size: 10))
            }
            .padding(ClipFlowLayout.pageInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { store.endShortcutRecording() }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsListGroup(title: "外观与快捷键") {
                SettingsListRow(title: "外观模式") {
                    AppearanceModeControl(selection: $store.appearanceMode)
                }
                Divider().padding(.horizontal, 12)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("快速粘贴").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 6) {
                            Text(store.isRecordingShortcut ? "Esc 取消" : "点击组合键修改")
                                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            Text("·").foregroundStyle(.tertiary)
                            Button("恢复默认") { store.setQuickPasteShortcut(.default) }
                                .buttonStyle(.borderless).disabled(store.isRecordingShortcut)
                                .accessibilityLabel("恢复默认快速粘贴快捷键")
                        }
                        .font(.system(size: 10))
                    }
                    Spacer(minLength: 0)
                    ShortcutRecorder(store: store).frame(width: 144, height: 32)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                if let error = store.shortcutError {
                    Text(QuotedCopy.keepingQuotesIntact(error)).font(.system(size: 10)).foregroundStyle(ClipCategory.protected.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                        .accessibilityLabel("快捷键错误：\(error)")
                }
            }
            SettingsListGroup(title: "启动与运行") {
                SettingsListRow(title: "暂停监听", detail: "暂停记录新内容，已有历史仍可使用") {
                    settingsToggle("暂停监听", isOn: $store.capturePaused)
                }
                Divider().padding(.horizontal, 12)
                SettingsListRow(title: "开机自动启动", detail: store.launchAtLoginDetail) {
                    settingsToggle("开机自动启动", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                }
                if store.accessibilityTrusted == false {
                    Divider().padding(.horizontal, 12)
                    SettingsListRow(title: "辅助功能", detail: "自动粘贴需要这项权限。未授权时改为复制到剪贴板，可在目标应用手动粘贴。") {
                        Button("打开系统设置") {
                            _ = AccessibilityTrust.openSystemSettings()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("打开系统设置")
                        .accessibilityHint("辅助功能隐私设置")
                    }
                }
            }
        }
    }

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsListGroup(title: "敏感内容") {
                SettingsListRow(title: "自动保护疑似敏感内容", detail: "识别验证码、令牌等内容并应用隐私策略") {
                    settingsToggle("自动保护疑似敏感内容", isOn: $store.autoProtectSecrets)
                }
                Divider().padding(.horizontal, 12)
                SettingsListRow(title: "5 分钟后自动删除", detail: "按复制时间计算，置顶也会过期") {
                    settingsToggle("5 分钟后自动删除", isOn: $store.sensitiveAutoExpireEnabled)
                }
            }
            Text("关闭自动删除后，敏感内容仍遮罩显示、仅本地保存。重新开启会清理已超时记录。")
                .font(.system(size: 11))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            SettingsListGroup(title: "排除应用") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(QuotedCopy.keepingQuotesIntact("每行一个 Bundle ID，来自这些应用的内容不会被记录。钥匙串、系统密码和常见密码管理器始终排除，即使没有写在这里。"))
                        .font(.system(size: 11))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    RuleTextEditor(text: $draft.excludedAppsText)
                        .frame(height: RuleTextEditor.viewportHeight())
                        .padding(8)
                        .background(palette.inputFill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
                        .accessibilityLabel("排除应用 Bundle ID")
                        .accessibilityHint("可上下滚动，查看其余 Bundle ID。")
                        .onChangeBackward(of: draft.excludedAppsText) { draft.noteExclusionEdits() }
                    if let exclusionError = draft.exclusionError {
                        Text(exclusionError)
                            .font(.system(size: 11))
                            .foregroundStyle(ClipCategory.protected.labelColor(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("排除规则错误")
                    }
                    HStack {
                        Button("恢复默认") { draft.resetExcludedApps(in: store) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("恢复默认排除规则")
                        Spacer()
                        Button("保存规则") { draft.saveExcludedApps(into: store) }
                            .buttonStyle(ClipFlowActionButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                            .accessibilityLabel("保存排除规则")
                    }
                }.padding(12)
            }
        }
    }

    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsListGroup(title: "文稿目录同步") {
                SettingsListRow(title: "同步普通历史", detail: "将普通文本与图片镜像到“文稿/ClipFlow”") {
                    settingsToggle("同步普通历史", isOn: Binding(get: { store.iCloudSyncEnabled }, set: { store.setICloudSyncEnabled($0) }))
                }
                Divider().padding(.horizontal, 12)
                SettingsListRow(title: "同步状态") {
                    Text(store.iCloudSyncStatusValue).font(.system(size: 12))
                        .foregroundStyle(store.iCloudSyncTint(for: colorScheme))
                        .accessibilityLabel("同步状态：\(store.iCloudSyncStatusValue)")
                }
            }
            Text(QuotedCopy.keepingQuotesIntact(store.iCloudSyncDetail)).font(.system(size: 11))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(store.iCloudSyncDetail)
            Label("受保护内容始终保留在本机", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(ClipCategory.protected.tint)
        }
    }
}

private struct SettingsListGroup<Content: View>: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .padding(.horizontal, 4)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(CleanGlassBackground(cornerRadius: ClipFlowLayout.rowRadius))
        }
    }
}

private struct SettingsListRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let detail {
                    Text(QuotedCopy.keepingQuotesIntact(detail)).font(.system(size: 10))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 42)
    }
}

private struct AppearanceModeControl: View {
    @Binding var selection: ClipFlowAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClipFlowAppearance.allCases) { mode in
                Button {
                    guard selection != mode else { return }
                    selection = mode
                } label: {
                    HStack(spacing: 4) {
                        if mode != .system {
                            Image(systemName: mode.icon).font(.system(size: 10, weight: .medium))
                        }
                        Text(mode.title).font(.system(size: 11, weight: selection == mode ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selection == mode
                        ? ClipCategory.all.labelColor(for: colorScheme)
                        : ClipFlowPalette.secondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if selection == mode {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(ClipCategory.all.tint.opacity(0.13))
                                .matchedGeometryEffect(id: "appearance", in: highlight)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
            }
        }
        .padding(3)
        .frame(width: 216, height: 32)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .animation(reduceMotion ? nil : ClipFlowMotion.fade, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("外观模式")
    }
}

private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
}
