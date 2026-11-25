import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ClipFlowStore
    @ObservedObject private var pasteStack: PasteStackState
    @ViewState private var copiedQuickID: UUID?
    @ViewState private var hoveredQuickID: UUID?
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }

    init(store: ClipFlowStore) {
        self.store = store
        _pasteStack = ObservedObject(wrappedValue: store.pasteStack)
    }

    private var quickPinnedOrRecent: [ClipboardItem] {
        Array(store.quickPasteItems.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            MenuPanelHeader(store: store)

            // Paste Stack + Quick Copy Folio Strip
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.down.right")
                        .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                        .frame(width: 16)
                    Text("顺序粘贴")
                        .font(.system(size: ClipFlowType.meta, weight: .medium))
                    if !pasteStack.queuedIDs.isEmpty {
                        Text("\(pasteStack.queuedIDs.count) 条排队")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                            .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(FolioTheme.sageAccent(for: colorScheme).opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Spacer(minLength: 6)
                    Toggle("顺序粘贴", isOn: $pasteStack.autoCollectEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .frame(height: 34)

                if !quickPinnedOrRecent.isEmpty {
                    Divider()
                    VStack(spacing: 4) {
                        ForEach(Array(quickPinnedOrRecent.enumerated()), id: \.element.id) { idx, item in
                            let isCopied = copiedQuickID == item.id
                            let isHovered = hoveredQuickID == item.id
                            Button {
                                if ClipFlowRuntime.shared.copyToClipboard(item) {
                                    withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                                        copiedQuickID = item.id
                                    }
                                    let id = item.id
                                    Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                                        if copiedQuickID == id { copiedQuickID = nil }
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    AppIconBadgeView(item: item, size: 16)
                                    Text(PasteStackTrayView.shortLabel(for: item, store: store))
                                        .font(.system(size: ClipFlowType.meta, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if isCopied {
                                        Text("✓ 已复制")
                                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                                            .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                                    } else if item.autoExpire && item.expiresAt != nil {
                                        ExpiryCountdownRing(item: item, compact: true)
                                    } else {
                                        TactileKeycap(label: "⌘\(idx + 1)")
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(
                                            isCopied
                                                ? FolioTheme.sageAccent(for: colorScheme).opacity(0.12)
                                                : (isHovered ? FolioTheme.recessedWell(for: colorScheme) : Color.clear)
                                        )
                                )
                                .contentShape(Rectangle())
                                .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? 0.15 : 0.12), value: isHovered)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                hoveredQuickID = hovering ? item.id : (hoveredQuickID == item.id ? nil : hoveredQuickID)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, ClipFlowLayout.space12)
            .padding(.vertical, ClipFlowLayout.space4)
            .background(CleanGlassBackground(cornerRadius: ClipFlowLayout.rowRadius, elevated: true))

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
                    .help(store.launchAtLoginDetail)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(ClipCategory.images.tint).frame(width: 16)
                    Text("文稿同步")
                    Spacer()
                    Text(store.iCloudSyncStatusValue).foregroundStyle(store.iCloudSyncTint(for: colorScheme))
                    Toggle("文稿同步", isOn: Binding(get: { store.iCloudSyncEnabled },
                        set: { store.setICloudSyncEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("启用文稿同步")
                }
                .font(.system(size: 11)).frame(height: 34)
                .help(QuotedCopy.keepingQuotesIntact(store.iCloudSyncDetail))
            }
            .padding(.horizontal, ClipFlowLayout.space12).padding(.vertical, ClipFlowLayout.space4)
            .background(CleanGlassBackground(cornerRadius: ClipFlowLayout.rowRadius, elevated: true))

            if store.accessibilityTrusted == false {
                VStack(alignment: .leading, spacing: 8) {
                    Text("自动粘贴需要辅助功能权限。未授权时会改为复制到剪贴板，请在目标应用中手动粘贴。")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开系统设置") {
                        _ = AccessibilityTrust.openSystemSettings()
                    }
                    .buttonStyle(MenuFooterActionStyle(fill: ClipCategory.protected.tint.opacity(0.16)))
                    .help("系统设置 → 隐私与安全性 → 辅助功能")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(CleanGlassBackground(cornerRadius: ClipFlowLayout.rowRadius, elevated: true))
            }

            HStack(spacing: 8) {
                Button("快速粘贴") {
                    AppNavigationCenter.shared.dismissMenuBarPopover?()
                    ClipFlowRuntime.shared.showHUD()
                }
                .buttonStyle(MenuFooterActionStyle(fill: palette.primaryButtonFill, foreground: .white))
                .help("打开快速粘贴面板（\(store.quickPasteShortcut.displayName)）")
                Button("活页夹") { AppNavigationCenter.shared.openLibrary() }
                    .buttonStyle(MenuFooterActionStyle(fill: palette.secondaryButtonFill))
                Button("设置") { AppNavigationCenter.shared.openSettings() }
                    .buttonStyle(MenuFooterActionStyle(fill: palette.secondaryButtonFill))
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
            Text(store.statusSummary).font(.system(size: ClipFlowType.mono))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .lineLimit(1).help(store.statusSummary)
        }
        .padding(16)
        .frame(width: ClipFlowLayout.menuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(FolioTheme.folioPage(for: colorScheme))
    }

    private func statusToggle(_ title: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .frame(height: 34)
    }
}

struct MenuPanelHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("ClipFlow 剪流")
                    .font(.system(size: ClipFlowType.cardTitle, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.capturePaused ? Color.orange : FolioTheme.sageAccent(for: colorScheme))
                        .frame(width: 7, height: 7)
                    Text(store.capturePaused ? "监听已暂停" : "正在监听 · \(store.items.count) 张纸卡")
                        .foregroundStyle(store.capturePaused
                            ? ClipFlowPalette.pausedStatus(for: colorScheme)
                            : ClipFlowPalette.listeningStatus(for: colorScheme))
                }
                .font(.system(size: ClipFlowType.meta, weight: .medium))
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ShortcutGlyphLayout.text(for: store.quickPasteShortcut, pointSize: 10, weight: .semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))
            .accessibilityLabel("\(store.quickPasteShortcut.displayName) 呼出")
        }
        .padding(.horizontal, 2)
    }
}

struct MenuFooterActionStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = Color.primary.opacity(0.85)
    var height: CGFloat = ClipFlowLayout.controlHeight
    var fontSize: CGFloat = 12
    var cornerRadius: CGFloat = ClipFlowLayout.controlRadius

    func makeBody(configuration: Configuration) -> some View {
        MenuFooterActionBody(configuration: configuration, fill: fill, foreground: foreground,
            height: height, fontSize: fontSize, cornerRadius: cornerRadius)
    }
}

private struct MenuFooterActionBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let foreground: Color
    let height: CGFloat
    let fontSize: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, ClipFlowLayout.space12)
            .frame(height: height)
            .background(fill.opacity(configuration.isPressed ? 0.78 : 1), in: shape)
            .overlay {
                if isHovered && !configuration.isPressed {
                    shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06))
                }
            }
            .overlay(shape.strokeBorder(FolioTheme.hairline(for: colorScheme).opacity(isHovered ? 1 : 0.65), lineWidth: 1))
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1 : (isHovered ? -1 : 0)))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : ClipFlowMotion.pressScale)
            .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? 0.15 : 0.12), value: isHovered)
            .animation(reduceMotion ? nil : ClipFlowMotion.press, value: configuration.isPressed)
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }
}
