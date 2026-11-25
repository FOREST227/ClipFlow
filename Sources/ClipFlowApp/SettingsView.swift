import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable, ClipFlowTab {
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
    var subtitle: String {
        switch self {
        case .general: "外观、历史条数、快捷键与运行方式"
        case .privacy: "敏感内容保护与应用排除规则"
        case .sync: "在设备之间同步普通历史和常用片段"
        }
    }
}

struct SettingsView: View {
    var showsBackground = true
    var reservesTrafficLights = false
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var draft: SettingsDraft
    var onSelectHistory: (() -> Void)? = nil
    var onToggleEdgeDock: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sectionNamespace

    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }

    var body: some View {
        ZStack {
            if showsBackground {
                FolioTheme.folioPage(for: colorScheme)
                    .ignoresSafeArea()
            }
            VStack(alignment: .leading, spacing: 14) {
                // Folio Top Bar aligned with traffic lights
                HStack(spacing: 10) {
                    if reservesTrafficLights {
                        Spacer().frame(width: 60)
                    }

                    Text("偏好设置")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    HStack(spacing: 2) {
                        ForEach(SettingsCategory.allCases) { category in
                            let selected = draft.section == category
                            Button {
                                guard draft.section != category else { return }
                                let oldIdx = SettingsCategory.allCases.firstIndex(of: draft.section) ?? 0
                                let newIdx = SettingsCategory.allCases.firstIndex(of: category) ?? 0
                                draft.movesForward = newIdx > oldIdx
                                store.endShortcutRecording()
                                withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                                    draft.section = category
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: category.icon)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(category.rawValue)
                                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                }
                                .foregroundStyle(selected ? Color.primary : ClipFlowPalette.secondaryText(for: colorScheme))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(FolioTheme.deckCardFill(depth: 0, for: colorScheme))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                                            )
                                            .matchedGeometryEffect(id: "settingsTab", in: sectionNamespace)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(category.rawValue)设置")
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                    .padding(3)
                    .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                    )

                    if let onToggleEdgeDock {
                        Button(action: onToggleEdgeDock) {
                            Image(systemName: "sidebar.trailing")
                                .font(.system(size: ClipFlowType.meta, weight: .medium))
                                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        }
                        .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 30, horizontalPadding: 9, cornerRadius: 9))
                        .help("收起至屏幕右侧书签耳")
                    }
                }

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
                    insertion: .offset(y: draft.movesForward ? 8 : -8).combined(with: .opacity),
                    removal: .opacity))
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(reduceMotion ? nil : ClipFlowMotion.pageSwitch, value: draft.section)

                HStack(spacing: 6) {
                    Circle().fill(store.capturePaused ? Color.orange : FolioTheme.sageAccent(for: colorScheme)).frame(width: 6, height: 6)
                    Text(store.capturePaused ? "剪贴监听已暂停" : "剪贴监听运行中")
                        .foregroundStyle(store.capturePaused
                            ? ClipFlowPalette.pausedStatus(for: colorScheme)
                            : ClipFlowPalette.listeningStatus(for: colorScheme))
                    Spacer()
                    Text(settingsFooter)
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                }
                .font(.system(size: 10))
            }
            .padding(.horizontal, 16)
            .padding(.top, reservesTrafficLights ? 8 : 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { store.endShortcutRecording() }
        .onChangeBackward(of: historyLimitPromptKey) { draft.refreshHistoryLimitPrompt(in: store) }
    }

    private var settingsFooter: String {
        if draft.section == .general, draft.pendingHistoryLimit != nil {
            return "降低保留条数需确认后才会删除记录"
        }
        if draft.section == .privacy {
            return "敏感内容即时生效，排除规则需保存"
        }
        return "更改即时生效"
    }

    private var historyLimitPromptKey: String {
        "\(store.historyItemLimit)-\(store.items.count)-\(draft.pendingHistoryLimit ?? -1)"
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsListGroup(title: "外观、视图与快捷键") {
                SettingsListRow(title: "外观模式") {
                    AppearanceModeControl(selection: $store.appearanceMode)
                }
                Divider().padding(.horizontal, 12)
                SettingsListRow(title: "默认历史视图", detail: "可在叠卡盒与平铺清单之间随时切换") {
                    LibraryViewModeControl(selection: $store.libraryViewMode)
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
            SettingsListGroup(title: "历史") {
                SettingsListRow(title: "历史保留条数", detail: "未置顶记录的保留上限。置顶内容不计入，也不会被清理。") {
                    HistoryLimitControl(
                        selection: draft.pendingHistoryLimit ?? store.historyItemLimit,
                        onSelect: { draft.requestHistoryLimit($0, in: store) }
                    )
                }
                if let pendingHistoryLimit = draft.pendingHistoryLimit {
                    let removalCount = HistoryRetention.removalCount(in: store.items, limit: pendingHistoryLimit)
                    Divider().padding(.horizontal, 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(HistoryRetention.confirmationMessage(removalCount: removalCount))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ClipCategory.protected.labelColor(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("history-limit-warning")
                        HStack(spacing: 16) {
                            Spacer(minLength: 0)
                            Button(HistoryRetention.cancelButtonTitle) {
                                draft.cancelHistoryLimitChange()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("history-limit-cancel")
                            .accessibilityLabel("取消调整历史保留条数")
                            Button(HistoryRetention.confirmButtonTitle, role: .destructive) {
                                draft.confirmHistoryLimitChange(in: store)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(ClipCategory.protected.labelColor(for: colorScheme))
                            .accessibilityIdentifier("history-limit-confirm")
                            .accessibilityLabel("确认删除超出的历史记录")
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .accessibilityElement(children: .contain)
                }
            }
            SettingsListGroup(title: "启动与运行") {
                SettingsListRow(title: SharedSettingsCopy.recordClipboard, detail: SharedSettingsCopy.recordClipboardDetail) {
                    settingsToggle(SharedSettingsCopy.recordClipboard,
                        isOn: SharedSettingsCopy.recording(isPaused: $store.capturePaused))
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
        VStack(alignment: .leading, spacing: 18) {
            SettingsListGroup(title: "敏感内容") {
                SettingsListRow(title: SharedSettingsCopy.protectSecrets, detail: SharedSettingsCopy.protectSecretsDetail) {
                    settingsToggle(SharedSettingsCopy.protectSecrets, isOn: $store.autoProtectSecrets)
                }
                Divider().padding(.horizontal, 12)
                SettingsListRow(title: SharedSettingsCopy.expireSecrets, detail: SharedSettingsCopy.expireSecretsDetail) {
                    settingsToggle(SharedSettingsCopy.expireSecrets, isOn: $store.sensitiveAutoExpireEnabled)
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
                SettingsListRow(title: SharedSettingsCopy.syncPlainHistory, detail: "将普通文本、图片和常用片段镜像到“文稿/ClipFlow”") {
                    settingsToggle(SharedSettingsCopy.syncPlainHistory, isOn: Binding(get: { store.iCloudSyncEnabled }, set: { store.setICloudSyncEnabled($0) }))
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
            Label("受保护内容与敏感片段始终保留在本机", systemImage: "lock.shield")
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
                .background(CleanGlassBackground(cornerRadius: ClipFlowLayout.rowRadius, elevated: true))
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

private struct HistoryLimitControl: View {
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ClipFlowPillPicker(
            options: HistoryRetention.choices,
            selection: Binding(get: { selection }, set: { onSelect($0) }),
            accessibilityTitle: "历史保留条数",
            width: 232,
            title: { "\($0)" },
            help: { "保留 \($0) 条" },
            optionAccessibilityLabel: { "\($0) 条" },
            accessibilityIdentifier: { "history-limit-\($0)" }
        )
    }
}

private struct AppearanceModeControl: View {
    @Binding var selection: ClipFlowAppearance

    var body: some View {
        ClipFlowPillPicker(
            options: Array(ClipFlowAppearance.allCases),
            selection: $selection,
            accessibilityTitle: "外观模式",
            width: 216,
            title: \.title,
            icon: { $0 == .system ? nil : $0.icon },
            help: \.title,
            optionAccessibilityLabel: \.title
        )
    }
}

private struct LibraryViewModeControl: View {
    @Binding var selection: LibraryViewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                let selected = selection == mode
                Button {
                    guard selection != mode else { return }
                    selection = mode
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon).font(.system(size: 10, weight: .semibold))
                        Text(mode.label).font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? Color.primary : ClipFlowPalette.secondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(FolioTheme.deckCardFill(depth: 0, for: colorScheme))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))
                                .matchedGeometryEffect(id: "libraryViewMode", in: highlight)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.label)视图")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .frame(width: 144, height: 32)
        .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))
        .animation(reduceMotion ? nil : ClipFlowMotion.fade, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("默认历史视图")
    }
}

private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
}
