import AppKit
import SwiftUI

struct ContentView: View {
    var showsBackground = true
    @ObservedObject var store: ClipFlowStore
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var inspectingItemID: ClipboardItem.ID?

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)

        GeometryReader { proxy in
            ZStack {
                if showsBackground {
                    AppBackground(palette: palette)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }

                VStack(spacing: ClipFlowLayout.sectionGap) {
                    HeaderView(store: store, palette: palette)
                    SidebarView(store: store, palette: palette)
                    LibraryView(store: store, palette: palette) { item in
                        toggleLibraryInspector(for: item)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(ClipFlowLayout.pageInset)
                .frame(width: min(1100, proxy.size.width), height: proxy.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: overlayActive ? ClipFlowMotion.backgroundDefocusRadius : 0)

                if overlayActive {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture {
                            if inspectingItem != nil {
                                withAnimation(ClipFlowMotion.overlay) {
                                    inspectingItemID = nil
                                }
                            }
                        }
                        .zIndex(9)
                }

                if let inspectingItem {

                    LibraryInspectorOverlay(
                        item: inspectingItem,
                        store: store,
                        palette: palette,
                        maxHeight: min(max(proxy.size.height - 96, 420), 760)
                    ) {
                        withAnimation(ClipFlowMotion.overlay) {
                            inspectingItemID = nil
                        }
                    }
                    .frame(width: min(620, proxy.size.width - 48))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 48)
                    .transition(ClipFlowMotion.overlayTransition)
                    .zIndex(10)
                }

                if let permissionReport = store.startupPermissionReport {
                    StartupPermissionOverlay(
                        report: permissionReport,
                        palette: palette,
                        onDismiss: {
                            withAnimation(ClipFlowMotion.overlay) {
                                store.dismissStartupPermissionReport()
                            }
                        },
                        onRefresh: {
                            store.rerunPermissionCheck()
                        },
                        onRequestAccessibility: {
                            store.requestAccessibilityPermissionPrompt()
                        }
                    )
                    .frame(width: min(560, proxy.size.width - 48))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 48)
                    .transition(ClipFlowMotion.overlayTransition)
                    .zIndex(11)
                }
            }
        }
    }

    private var inspectingItem: ClipboardItem? {
        guard let inspectingItemID else { return nil }
        return store.item(withID: inspectingItemID)
    }

    private var overlayActive: Bool {
        inspectingItem != nil || store.startupPermissionReport != nil
    }

    private func toggleLibraryInspector(for item: ClipboardItem) {
        withAnimation(ClipFlowMotion.overlay) {
            store.select(item)
            inspectingItemID = inspectingItemID == item.id ? nil : item.id
        }
    }
}

struct StartupPermissionOverlay: View {
    let report: ClipFlowPermissionReport
    let palette: ClipFlowPalette
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onRequestAccessibility: () -> Void

    var body: some View {
        FrostedPanel(palette: palette) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill((report.needsAttention ? ClipCategory.protected.tint : ClipCategory.smartStacks.tint).opacity(0.16))
                                .frame(width: 42, height: 42)

                            Image(systemName: report.needsAttention ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(report.needsAttention ? ClipCategory.protected.tint : ClipCategory.smartStacks.tint)
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
                                .fill(Color.white.opacity(0.54))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(palette.border.opacity(0.64), lineWidth: 1)
                        )
                    }
                }

                HStack(spacing: 10) {
                    Button("继续使用", action: onDismiss)
                        .buttonStyle(ClipButtonStyle(fill: palette.secondaryButtonFill))

                    Button("重新检测", action: onRefresh)
                        .buttonStyle(ClipButtonStyle(fill: palette.secondaryButtonFill))

                    if report.items.contains(where: { $0.title == "辅助功能" && $0.status == .needsAttention }) {
                        Button("请求辅助功能权限", action: onRequestAccessibility)
                            .buttonStyle(ClipButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                    }
                }
            }
        }
    }
}

struct HeaderView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容、来源或标签", text: $store.searchText).textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
            }
            .font(.system(size: 13))
            .padding(12)
            .background(palette.inputFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border, lineWidth: 1))
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 8)], spacing: 8) {
            ForEach(ClipCategory.allCases) { category in
                Button {
                    withAnimation(ClipFlowMotion.selection) { store.selectedCategory = category }
                } label: {
                    CategoryRow(category: category, count: store.count(for: category), isSelected: store.selectedCategory == category)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    let onInspectItem: (ClipboardItem) -> Void

    var body: some View {
        LayoutSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.selectedCategory.title).font(.system(size: 15, weight: .semibold))
                    Text("\(store.filteredItems.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("右键查看详情").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                if store.filteredItems.isEmpty {
                    EmptyLibraryView(store: store, palette: palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(store.filteredItems) { item in
                                LibraryInteractiveCard(item: item, store: store,
                                    isSelected: store.selectedItem?.id == item.id,
                                    displayedSnippet: store.displaySnippet(for: item), palette: palette) {
                                    withAnimation(ClipFlowMotion.selection) { store.select(item) }
                                } onInspect: { onInspectItem(item) }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: .infinity)
                }
                Divider()
                Text(store.statusSummary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct EmptyLibraryView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text(store.items.isEmpty ? "从一次复制开始" : "没有匹配的内容")
                .font(.system(size: 16, weight: .semibold))
            Text(store.items.isEmpty
                ? "复制文字或图片后会出现在这里。\n按 \(store.quickPasteShortcut.displayName) 可随时快速回贴。"
                : "试试其他关键词，或切换到全部内容。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !store.items.isEmpty {
                Button("查看全部内容") { store.searchText = ""; store.selectedCategory = .all }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
            }
        }
        .padding(24)
    }
}

struct LibraryInteractiveCard: NSViewRepresentable {
    let item: ClipboardItem
    let store: ClipFlowStore
    let isSelected: Bool
    let displayedSnippet: String
    let palette: ClipFlowPalette
    let onSelect: () -> Void
    let onInspect: () -> Void

    func makeNSView(context: Context) -> LibraryInteractiveHostingView {
        let view = LibraryInteractiveHostingView()
        view.update(
            rootView: AnyView(
                ClipboardCard(
                    item: item,
                    isSelected: isSelected,
                    displayedSnippet: displayedSnippet,
                    palette: palette,
                    store: store
                )
            ),
            onSelect: onSelect,
            onInspect: onInspect
        )
        return view
    }

    func updateNSView(_ nsView: LibraryInteractiveHostingView, context: Context) {
        nsView.update(
            rootView: AnyView(
                ClipboardCard(
                    item: item,
                    isSelected: isSelected,
                    displayedSnippet: displayedSnippet,
                    palette: palette,
                    store: store
                )
            ),
            onSelect: onSelect,
            onInspect: onInspect
        )
    }
}

final class LibraryInteractiveHostingView: NSView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var onSelect: () -> Void = {}
    private var onInspect: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: AnyView,
        onSelect: @escaping () -> Void,
        onInspect: @escaping () -> Void
    ) {
        hostingView.rootView = rootView
        self.onSelect = onSelect
        self.onInspect = onInspect
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    override func rightMouseDown(with event: NSEvent) {
        onInspect()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onInspect()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onInspect()
        return nil
    }
}

struct LibraryInspectorOverlay: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    let maxHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("条目信息")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Text(item.title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(item.sourceApp) · \(item.timeLabel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                KindBadge(kind: item.kind, tint: tint)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PreviewPanel(
                        item: item,
                        displayedText: store.displayFullText(for: item),
                        palette: palette,
                        store: store
                    )

                    HorizontalViewThatFits {
                        HStack(spacing: 10) {
                            actionButtons
                        }
                    } second: {
                        VStack(alignment: .leading, spacing: 10) {
                            actionButtons
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("信息摘要")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)

                        PrivacyFactRow(title: "隐私级别", value: item.privacy.label, tint: item.privacy.color)
                        PrivacyFactRow(
                            title: "存储方式",
                            value: item.localOnly ? "仅本地保存" : "普通本地历史",
                            tint: item.localOnly ? ClipCategory.protected.tint : ClipCategory.smartStacks.tint
                        )
                        PrivacyFactRow(
                            title: "保留策略",
                            value: item.autoExpire ? "复制 5 分钟后删除" : "手动清理",
                            tint: item.autoExpire ? ClipCategory.quickPaste.tint : ClipCategory.all.tint
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("建议粘贴位置")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)

                        FlexiblePillRow(items: item.pasteTargets, tint: ClipCategory.links.tint)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("归类说明")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.secondary)

                        Text(groupingReason)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                    }
                }
            }
        }
        .padding(20)
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 28, x: 0, y: 18)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            ClipFlowRuntime.shared.paste(item)
            onClose()
        } label: {
            DetailActionLabel(title: "立即粘贴", icon: "arrow.up.doc.fill", tint: ClipCategory.quickPaste.tint)
        }
        .buttonStyle(.plain)

        Button {
            store.togglePin(item.id)
        } label: {
            DetailActionLabel(title: item.pinned ? "取消置顶" : "加入快贴", icon: "pin.fill", tint: ClipCategory.smartStacks.tint)
        }
        .buttonStyle(.plain)

        if item.privacy != .standard {
            Button {
                store.toggleReveal(item.id)
            } label: {
                DetailActionLabel(
                    title: store.isRevealed(item) ? "隐藏内容" : "显示内容",
                    icon: store.isRevealed(item) ? "eye.slash.fill" : "eye.fill",
                    tint: item.privacy.color
                )
            }
            .buttonStyle(.plain)
        }

        Button(role: .destructive) {
            store.delete(item.id)
            onClose()
        } label: {
            DetailActionLabel(title: "删除", icon: "trash.fill", tint: Color.red)
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        switch item.kind {
        case .text: ClipCategory.all.tint
        case .code: ClipCategory.code.tint
        case .link: ClipCategory.links.tint
        case .secret: ClipCategory.protected.tint
        case .image: ClipCategory.smartStacks.tint
        }
    }

    private var groupingReason: String {
        if item.kind == .image {
            return "已识别为图片内容，会保留缩略预览和尺寸信息，方便再次回贴。"
        }
        if item.kind == .code {
            return "已识别为代码或命令内容，因为文本里出现了明显的开发语法和终端特征。"
        }
        if item.kind == .secret || item.privacy != .standard {
            return "已进入保护分组，因为这条内容看起来像验证码、密钥或高风险敏感信息。"
        }
        if item.kind == .link {
            return "已识别为链接内容，因为系统检测到了可直接打开的网址。"
        }
        return "已保留在通用文本分组，因为它更像常规复制内容，不属于链接、代码或敏感项。"
    }
}

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

struct MenuBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    @ObservedObject var store: ClipFlowStore
    @ViewState private var inspectingItemID: UUID?

    var body: some View {
        let recentItems = store.recentItems
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                MenuPanelHeader(store: store)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("最近内容").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("查看全部") { AppNavigationCenter.shared.openLibrary() }
                            .font(.system(size: 11)).buttonStyle(.borderless)
                            .help("打开剪贴历史主窗口")
                    }
                    Text(store.menuQuickPasteModeEnabled ? "单击复制 · 双击快贴 · 右键查看" : "单击复制 · 右键查看详情")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if recentItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 24, weight: .light))
                        Text("复制的内容会出现在这里")
                        Text("文字、链接和图片都可以")
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(recentItems) { item in
                                MenuInteractiveRecentRow(item: item, snippet: store.displaySnippet(for: item),
                                    store: store, quickPasteModeEnabled: store.menuQuickPasteModeEnabled,
                                    onActivate: { ClipFlowRuntime.shared.copyToClipboard(item) },
                                    onQuickPaste: { ClipFlowRuntime.shared.paste(item) },
                                    onInspect: { toggleMenuInspector(for: item) })
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: .infinity)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("双击快贴", isOn: Binding(
                            get: { store.menuQuickPasteModeEnabled },
                            set: { if $0 != store.menuQuickPasteModeEnabled { store.toggleMenuQuickPasteMode() } }
                        ))
                        .toggleStyle(.switch).controlSize(.mini)
                        .fixedSize()
                        .help("开启后双击条目直接粘贴；关闭后单击仅复制")
                        Spacer(minLength: 12)
                        Button { AppNavigationCenter.shared.openSettings() } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        .buttonStyle(MenuFooterActionStyle(fill: Color.primary.opacity(0.045)))
                        .help("打开设置")
                        Menu {
                            Button("清空未置顶历史", role: .destructive) { store.clearHistory() }
                            Divider()
                            Button("重启 ClipFlow") { ClipFlowRuntime.shared.restartApplication() }
                            Button("退出 ClipFlow") { NSApp.terminate(nil) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("更多操作")
                        .help("更多操作")
                    }
                    .font(.system(size: 11, weight: .medium)).controlSize(.small)
                    .frame(height: 28)
                    Text(store.statusSummary)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(store.statusSummary)
                }
            }
            .allowsHitTesting(inspectingItem == nil)
            .blur(radius: inspectingItem == nil ? 0 : ClipFlowMotion.backgroundDefocusRadius)

            if let inspectingItem {
                HUDInspectorOverlay(item: inspectingItem, store: store,
                    onClose: { withAnimation(ClipFlowMotion.overlay) { inspectingItemID = nil } },
                    onPaste: {
                        withAnimation(ClipFlowMotion.overlay) { inspectingItemID = nil }
                        ClipFlowRuntime.shared.paste(inspectingItem)
                    })
                    .transition(ClipFlowMotion.overlayTransition)
            }
        }
        .padding(16)
        .frame(width: ClipFlowLayout.menuWidth, height: ClipFlowLayout.menuHeight)
        .background {
            GeometryReader { proxy in
                FloatingPanelBackground(palette: palette, tintOpacity: 0.9)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .allowsHitTesting(false)
        }
    }

    private var inspectingItem: ClipboardItem? {
        guard let inspectingItemID else { return nil }
        return store.item(withID: inspectingItemID)
    }

    private func toggleMenuInspector(for item: ClipboardItem) {
        withAnimation(ClipFlowMotion.overlay) {
            inspectingItemID = inspectingItemID == item.id ? nil : item.id
        }
    }
}

struct MenuPanelHeader: View {
    @ObservedObject var store: ClipFlowStore
    var body: some View {
        ClipFlowBrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ClipFlow 剪流").font(.system(size: 16, weight: .bold, design: .rounded))
                        Label(store.capturePaused ? "监听已暂停" : "正在监听", systemImage: store.capturePaused ? "pause.circle.fill" : "record.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(store.capturePaused ? Color.orange : Color.green)
                    }
                    Spacer(minLength: 4)
                    Button(store.capturePaused ? "恢复" : "暂停") { store.capturePaused.toggle() }
                        .font(.system(size: 11)).buttonStyle(.borderless)
                }
                HStack(spacing: 6) {
                    CompactStatusPill(title: "历史", value: "\(store.items.count)", icon: "square.stack.3d.up", tint: ClipCategory.all.tint)
                    CompactStatusPill(title: "隐私", value: "\(store.protectedCount)", icon: "lock.shield", tint: ClipCategory.protected.tint)
                    CompactStatusPill(title: "呼出", value: store.quickPasteShortcut.displayName, icon: "cursorarrow.rays", tint: ClipCategory.quickPaste.tint)
                }
            }
        }
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
                .foregroundStyle(ClipCategory.smartStacks.tint)

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

struct MenuRecentClipRow: View {
    let item: ClipboardItem
    let snippet: String
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.isImage ? item.title : snippet)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(item.isImage ? 1 : 2)

                    Spacer(minLength: 8)

                    Text(item.timeLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                if !item.isImage {
                    Text(item.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                if item.isImage {
                    ClipThumbnailView(
                        store: store,
                        item: item,
                        height: 82,
                        cornerRadius: 12,
                        showsDimensionLabel: false,
                        contentMode: .fit,
                        insetPreview: true
                    )
                }

                Text(item.sourceApp)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
            }

            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color {
        switch item.kind {
        case .text: ClipCategory.all.tint
        case .code: ClipCategory.code.tint
        case .link: ClipCategory.links.tint
        case .secret: ClipCategory.protected.tint
        case .image: ClipCategory.smartStacks.tint
        }
    }

    private var iconName: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .code: "terminal"
        case .link: "link"
        case .secret: "lock.fill"
        case .image: "photo.stack.fill"
        }
    }
}

struct MenuInteractiveRecentRow: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    let item: ClipboardItem
    let snippet: String
    let store: ClipFlowStore
    let quickPasteModeEnabled: Bool
    let onActivate: () -> Void
    let onQuickPaste: () -> Void
    let onInspect: () -> Void

    func makeNSView(context: Context) -> MenuInteractiveRecentHostingView {
        let view = MenuInteractiveRecentHostingView()
        view.update(
            rootView: AnyView(
                MenuRecentClipRow(item: item, snippet: snippet, store: store)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(palette.softFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
            ),
            quickPasteModeEnabled: quickPasteModeEnabled,
            onActivate: onActivate,
            onQuickPaste: onQuickPaste,
            onInspect: onInspect
        )
        return view
    }

    func updateNSView(_ nsView: MenuInteractiveRecentHostingView, context: Context) {
        nsView.update(
            rootView: AnyView(
                MenuRecentClipRow(item: item, snippet: snippet, store: store)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(palette.softFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
            ),
            quickPasteModeEnabled: quickPasteModeEnabled,
            onActivate: onActivate,
            onQuickPaste: onQuickPaste,
            onInspect: onInspect
        )
    }
}

final class MenuInteractiveRecentHostingView: NSView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var quickPasteModeEnabled = false
    private var onActivate: () -> Void = {}
    private var onQuickPaste: () -> Void = {}
    private var onInspect: () -> Void = {}
    private var pendingSingleClickWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: AnyView,
        quickPasteModeEnabled: Bool,
        onActivate: @escaping () -> Void,
        onQuickPaste: @escaping () -> Void,
        onInspect: @escaping () -> Void
    ) {
        hostingView.rootView = rootView
        self.quickPasteModeEnabled = quickPasteModeEnabled
        self.onActivate = onActivate
        self.onQuickPaste = onQuickPaste
        self.onInspect = onInspect
    }

    override func mouseDown(with event: NSEvent) {
        pendingSingleClickWorkItem?.cancel()

        guard quickPasteModeEnabled else {
            onActivate()
            return
        }

        if event.clickCount >= 2 {
            onQuickPaste()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.onActivate()
        }
        pendingSingleClickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipFlowMotion.doubleClickDelay, execute: workItem)
    }

    override func rightMouseDown(with event: NSEvent) {
        onInspect()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onInspect()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onInspect()
        return nil
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.65 : 0.85))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
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
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
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
                    .padding(.leading, 48)
            }
        }
    }
}

struct AppBackground: View {
    let palette: ClipFlowPalette

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundStart, palette.backgroundMiddle, palette.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(palette.orbA)
                .frame(width: 420, height: 420)
                .blur(radius: 60)
                .offset(x: -420, y: -180)

            Circle()
                .fill(palette.orbB)
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: 420, y: 180)
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
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
            .shadow(color: palette.shadow, radius: 28, x: 0, y: 18)
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

struct CategoryRow: View {
    let category: ClipCategory
    let count: Int
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(category.tint)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [category.tint.opacity(0.22), category.tint.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
            Text(category.title).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)").monospacedDigit().font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(category.tint.opacity(isSelected ? 0.16 : 0.06), in: Capsule())
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isSelected ? category.tint : Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(isSelected ? category.tint.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? category.tint.opacity(0.3) : .clear, lineWidth: 1))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                .foregroundStyle(ClipCategory.quickPaste.tint)
                .frame(width: 16, height: 16)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ClipCategory.quickPaste.tint.opacity(0.14))
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
                        .fill(ClipCategory.quickPaste.tint)
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

struct ClipThumbnailView: View {
    @ObservedObject var store: ClipFlowStore
    let item: ClipboardItem
    let height: CGFloat
    var cornerRadius: CGFloat = 20
    var showsDimensionLabel: Bool = true
    var contentMode: ContentMode = .fill
    var insetPreview: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.10))

            previewContent

            if showsDimensionLabel, let dimension = item.imageDimensionText {
                Text(dimension)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var previewContent: some View {
        if !store.isRevealed(item) {
            previewPlaceholder(
                title: "图片预览已隐藏",
                icon: "lock.fill",
                tint: item.privacy.color
            )
        } else if let image = store.imagePreview(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(insetPreview ? 8 : 0)
        } else {
            previewPlaceholder(
                title: "图片不可用",
                icon: "photo.badge.exclamationmark",
                tint: ClipCategory.protected.tint
            )
        }
    }

    private func previewPlaceholder(title: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.16), Color.black.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let isSelected: Bool
    let displayedSnippet: String
    let palette: ClipFlowPalette
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.isImage {
                ClipThumbnailView(store: store, item: item, height: 64, cornerRadius: 8,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    .frame(width: 72)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(item.sourceApp).lineLimit(1)
                    KindBadge(kind: item.kind, tint: itemTint)
                    if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.quickPaste.tint) }
                    Spacer(minLength: 4)
                    Text(item.timeLabel).lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(item.isImage ? item.title : displayedSnippet)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(Array(item.labels.filter { $0 != item.sourceApp }.prefix(2)), id: \.self) { label in
                        Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(itemTint.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if item.isSensitive {
                        Label(item.privacy.label, systemImage: "lock.fill")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(item.privacy.color)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(item.privacy.color.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(isSelected ? itemTint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .background(palette.softFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isSelected ? itemTint.opacity(0.4) : palette.border.opacity(0.5), lineWidth: 1))
    }

    private var itemTint: Color {
        switch item.kind {
        case .text: ClipCategory.all.tint
        case .code: ClipCategory.code.tint
        case .link: ClipCategory.links.tint
        case .secret: ClipCategory.protected.tint
        case .image: ClipCategory.smartStacks.tint
        }
    }
}

struct PreviewPanel: View {
    let item: ClipboardItem
    let displayedText: String
    let palette: ClipFlowPalette
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.sourceApp)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text(item.timeLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            if item.isImage {
                VStack(alignment: .leading, spacing: 12) {
                    ClipThumbnailView(
                        store: store,
                        item: item,
                        height: 260,
                        cornerRadius: 22,
                        contentMode: .fit,
                        insetPreview: true
                    )

                    Text(displayedText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(palette.softFill)
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(displayedText)
                        .font(.system(size: item.kind == .code ? 12 : 14, weight: .medium, design: item.kind == .code ? .monospaced : .rounded))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(palette.softFill)
                        )

                    if let linkURL = item.primaryURL {
                        Button {
                            NSWorkspace.shared.open(linkURL)
                        } label: {
                            Label("访问链接", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ClipButtonStyle(fill: ClipCategory.links.tint.opacity(0.14), foreground: ClipCategory.links.tint))
                    }
                }
            }
        }
    }
}

struct DetailActionLabel: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

struct PrivacyFactRow: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                )
        }
    }
}

struct FlexiblePillRow: View {
    let items: [String]
    let tint: Color

    var body: some View {
        HorizontalViewThatFits {
            HStack(spacing: 8) {
                rowContent
            }
        } second: {
            VStack(alignment: .leading, spacing: 8) {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        ForEach(items, id: \.self) { item in
            Text(item)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                )
        }
    }
}

struct KindBadge: View {
    let kind: ClipboardKind
    let tint: Color

    var body: some View {
        Text(kind.label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

struct SmallBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

struct ClipButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = Color.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

struct ClipFlowPalette {
    let backgroundStart: Color
    let backgroundMiddle: Color
    let backgroundEnd: Color
    let orbA: Color
    let orbB: Color
    let border: Color
    let shadow: Color
    let softFill: Color
    let inputFill: Color
    let primaryButtonFill: Color
    let secondaryButtonFill: Color

    static func resolve(for colorScheme: ColorScheme) -> ClipFlowPalette {
        if colorScheme == .dark {
            return ClipFlowPalette(
                backgroundStart: Color(red: 0.09, green: 0.10, blue: 0.14),
                backgroundMiddle: Color(red: 0.12, green: 0.14, blue: 0.18),
                backgroundEnd: Color(red: 0.09, green: 0.12, blue: 0.16),
                orbA: Color(red: 0.83, green: 0.55, blue: 0.28).opacity(0.28),
                orbB: Color(red: 0.25, green: 0.58, blue: 0.88).opacity(0.24),
                border: Color.white.opacity(0.14),
                shadow: Color.black.opacity(0.34),
                softFill: Color.white.opacity(0.09),
                inputFill: Color.white.opacity(0.12),
                primaryButtonFill: Color(red: 0.30, green: 0.59, blue: 0.92),
                secondaryButtonFill: Color.white.opacity(0.10)
            )
        }

        return ClipFlowPalette(
            backgroundStart: Color(red: 0.98, green: 0.95, blue: 0.90),
            backgroundMiddle: Color(red: 0.93, green: 0.96, blue: 0.99),
            backgroundEnd: Color(red: 0.95, green: 0.93, blue: 0.98),
            orbA: Color(red: 0.98, green: 0.80, blue: 0.47).opacity(0.38),
            orbB: Color(red: 0.40, green: 0.73, blue: 0.95).opacity(0.22),
            border: Color.white.opacity(0.7),
            shadow: Color.black.opacity(0.10),
            softFill: Color.white.opacity(0.66),
            inputFill: Color.white.opacity(0.82),
            primaryButtonFill: Color(red: 0.30, green: 0.59, blue: 0.92),
            secondaryButtonFill: Color.white.opacity(0.74)
        )
    }
}
