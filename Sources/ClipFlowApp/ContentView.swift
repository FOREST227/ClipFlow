import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    var showsBackground = true
    var showsPermissionOverlay = true
    @ObservedObject var store: ClipFlowStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isPageEnabled
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }
    @StateObject private var inspector: InspectorPresentation

    init(showsBackground: Bool = true, showsPermissionOverlay: Bool = true,
         store: ClipFlowStore, inspector: InspectorPresentation? = nil) {
        self.showsBackground = showsBackground
        self.showsPermissionOverlay = showsPermissionOverlay
        self.store = store
        _inspector = StateObject(wrappedValue: inspector ??
            InspectorPresentation(driver: AppKitInspectorAnimationDriver()))
    }

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
                    LibraryView(store: store, palette: palette,
                        onInspectFrom: { item, source in toggleLibraryInspector(for: item, source: source) }) { item in
                        toggleLibraryInspector(for: item)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(ClipFlowLayout.pageInset)
                .frame(width: min(1100, proxy.size.width), height: proxy.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: permissionOverlayActive ? ClipFlowMotion.backgroundDefocusRadius : 0)
                .modifier(InspectorBackdropMotion(motion: inspector.motion))
                .disabled(overlayActive)
                .accessibilityHidden(overlayActive)

                if permissionOverlayActive {
                    Color.black.opacity(0.18).ignoresSafeArea().zIndex(9)
                } else if inspector.blocksBackground {
                    InspectorScrim(motion: inspector.motion, opacity: 0.18) {
                        inspector.dismiss(reduceMotion: reduceMotion)
                    }
                    .ignoresSafeArea().zIndex(9)
                }

                if let inspectingItem {
                    let cardWidth = min(620, proxy.size.width - 24)
                    let tallImage = inspectingItem.isImage && LibraryImageShape.resolve(
                        width: inspectingItem.imageWidth, height: inspectingItem.imageHeight) == .portrait
                    LibraryInspectorOverlay(
                        item: inspectingItem,
                        store: store,
                        palette: palette,
                        maxHeight: tallImage ? max(200, proxy.size.height - 32)
                            : min(max(proxy.size.height - 32, 420), 760),
                        contentWidth: cardWidth,
                        onPasteAction: {
                            inspector.dismiss(reduceMotion: reduceMotion) {
                                guard let current = store.item(withID: inspectingItem.id) else { return }
                                ClipFlowRuntime.shared.paste(current)
                            }
                        },
                        sourceRectInWindow: inspector.snapshot.sourceRectInWindow,
                        motion: inspector.motion
                    ) {
                        inspector.dismiss(reduceMotion: reduceMotion)
                    }
                    .frame(width: cardWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .zIndex(10)
                }

                if showsPermissionOverlay, let permissionReport = store.startupPermissionReport {
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
        .background(
            InspectorEscapeHandler(onEscape: {
                guard isPageEnabled, inspector.blocksBackground,
                      store.startupPermissionReport == nil else { return false }
                inspector.dismiss(reduceMotion: reduceMotion)
                return true
            }, onWindowInactive: { inspector.reset() }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .onChangeBackward(of: store.items) {
            inspector.invalidateIfMissing(availableIDs: Set(store.items.filter { !$0.isExpired() }.map(\.id)))
        }
        .onChangeBackward(of: isPageEnabled) {
            if !isPageEnabled { inspector.reset() }
        }
        .onChangeBackward(of: store.startupPermissionReport != nil) {
            if store.startupPermissionReport != nil { inspector.reset() }
        }
        .onDisappear { inspector.reset() }
    }

    private var inspectingItem: ClipboardItem? {
        guard let id = inspector.snapshot.itemID else { return nil }
        return store.item(withID: id)
    }

    private var permissionOverlayActive: Bool {
        showsPermissionOverlay && store.startupPermissionReport != nil
    }

    private var overlayActive: Bool {
        inspector.blocksBackground || permissionOverlayActive
    }

    private func toggleLibraryInspector(for item: ClipboardItem, source: InspectorSourceAnchor? = nil) {
        store.select(item)
        if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
            inspector.dismiss(reduceMotion: reduceMotion)
        } else {
            inspector.open(itemID: item.id, reduceMotion: reduceMotion, source: source)
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
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)? = nil
    let onInspectItem: (ClipboardItem) -> Void

    var body: some View {
        LayoutSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.selectedCategory.title).font(.system(size: 15, weight: .semibold))
                    Text("\(store.filteredItems.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("右键查看详情").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(role: .destructive) { store.clearHistory() } label: {
                        Label("清空未置顶历史", systemImage: "trash")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .padding(.leading, 8)
                    .disabled(!store.items.contains(where: { !$0.pinned }))
                    .help("清空所有未置顶历史，保留置顶条目；不限于当前筛选结果")
                }
                Divider()
                if store.filteredItems.isEmpty {
                    EmptyLibraryView(store: store, palette: palette)
                        .frame(maxWidth: .infinity)
                        .frame(height: LibraryCardLayout.viewportHeight)
                } else {
                    SoftEdgeScrollView(showsEdgeEffects: false) {
                        // Fixed card heights and an independent selection layer allow
                        // offscreen content to stay unloaded without selection relayout.
                        LazyVStack(spacing: LibraryCardLayout.spacing) {
                            ForEach(store.filteredItems) { item in
                                LibraryInteractiveCard(item: item, store: store,
                                    displayedSnippet: store.displaySnippet(for: item), palette: palette,
                                    onInspectFrom: { source in
                                        if let onInspectFrom { onInspectFrom(item, source) }
                                        else { onInspectItem(item) }
                                    }, onSelect: { store.select(item) },
                                    onInspect: { onInspectItem(item) })
                                .frame(maxWidth: .infinity)
                                .frame(height: LibraryCardLayout.height(for: item.kind))
                            }
                        }
                    }
                    .frame(height: LibraryCardLayout.viewportHeight)
                }
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
    @Environment(\.isEnabled) private var isEnabled
    let item: ClipboardItem
    let store: ClipFlowStore
    let displayedSnippet: String
    let palette: ClipFlowPalette
    var onInspectFrom: ((InspectorSourceAnchor) -> Void)? = nil
    let onSelect: () -> Void
    let onInspect: () -> Void

    func makeNSView(context: Context) -> LibraryInteractiveHostingView {
        let view = LibraryInteractiveHostingView()
        view.interactionEnabled = isEnabled
        view.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        view.update(
            rootView: AnyView(
                ClipboardCard(
                    item: item,
                    displayedSnippet: displayedSnippet,
                    palette: palette,
                    store: store
                )
            ),
            selectionView: AnyView(LibrarySelectionChrome(itemID: item.id,
                selection: store.historySelection, tint: item.kind.tint, palette: palette)),
            onSelect: onSelect,
            onInspect: InspectorSourceAnchor.callback(for: view, fallback: onInspect, anchored: onInspectFrom)
        )
        return view
    }

    func updateNSView(_ nsView: LibraryInteractiveHostingView, context: Context) {
        nsView.interactionEnabled = isEnabled
        nsView.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        nsView.update(
            rootView: AnyView(
                ClipboardCard(
                    item: item,
                    displayedSnippet: displayedSnippet,
                    palette: palette,
                    store: store
                )
            ),
            selectionView: AnyView(LibrarySelectionChrome(itemID: item.id,
                selection: store.historySelection, tint: item.kind.tint, palette: palette)),
            onSelect: onSelect,
            onInspect: InspectorSourceAnchor.callback(for: nsView, fallback: onInspect, anchored: onInspectFrom)
        )
    }
}

final class LibraryInteractiveHostingView: ClipboardRowHitView {
    private(set) var contentRevision = 0
    private let selectionHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var onSelect: () -> Void = {}
    private var onInspect: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        selectionHostingView.translatesAutoresizingMaskIntoConstraints = false
        selectionHostingView.wantsLayer = true
        selectionHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(selectionHostingView)
        NSLayoutConstraint.activate([
            selectionHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionHostingView.topAnchor.constraint(equalTo: topAnchor),
            selectionHostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

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
        selectionView: AnyView? = nil,
        onSelect: @escaping () -> Void,
        onInspect: @escaping () -> Void
    ) {
        contentRevision += 1
        hostingView.rootView = rootView
        if let selectionView { selectionHostingView.rootView = selectionView }
        self.onSelect = onSelect
        self.onInspect = onInspect
    }

    override func mouseDown(with event: NSEvent) {
        guard !redirectLeftClickIfNeeded(event) else { return }
        onSelect()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        onInspect()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        if event.buttonNumber == 2 {
            onInspect()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionEnabled else { return nil }
        onInspect()
        return nil
    }
}

struct LibraryInspectorOverlay: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    let maxHeight: CGFloat
    var contentWidth: CGFloat = 438
    var compactShadow = false
    var onPasteAction: (() -> Void)? = nil
    var sourceRectInWindow: CGRect? = nil
    var motion: InspectorMotionProgress? = nil
    @ViewState private var destinationRectInWindow: CGRect = .zero
    let onClose: () -> Void
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }
    private var reduceTransparency: Bool { motionPreferences.reduceTransparency }
    @Environment(\.colorScheme) private var textColorScheme
    @ViewState private var showsMarkdownPreview = false
    @ViewState private var codeLanguage = "自动识别"
    private var markdownAvailable: Bool {
        (!item.isSensitive || store.isRevealed(item)) && DetailTextFormat.isMarkdown(store.displayFullText(for: item))
    }
    @ViewState private var showsInfo = false
    @ViewState private var copyFeedback: String?

    private let drawerHeaderHeight: CGFloat = 84
    private var drawerFooterHeight: CGFloat {
        124 + (showsInfo ? 72 : 0) + (item.isSensitive ? 22 : 0) + (copyFeedback == nil ? 0 : 20)
    }
    private var drawerHeight: CGFloat {
        if item.isImage || item.kind == .code || markdownAvailable { return maxHeight }
        let font = NSFont.systemFont(ofSize: 13)
        let bounds = (store.displayFullText(for: item) as NSString).boundingRect(
            with: CGSize(width: max(160, contentWidth - 64), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(maxHeight, drawerHeaderHeight + max(64, ceil(bounds.height) + 24) + drawerFooterHeight + 24)
    }
    private var drawerBodyHeight: CGFloat { max(64, drawerHeight - drawerHeaderHeight - drawerFooterHeight - 24) }
    private var previewHeight: CGFloat { item.isImage ? max(64, drawerBodyHeight - 24) : drawerBodyHeight }

    var body: some View {
        // Build rich content and measure text once per content/state change, not per animation tick.
        let height = drawerHeight
        let bodyHeight = max(64, height - drawerHeaderHeight - drawerFooterHeight - 24)
        let footerHeight = drawerFooterHeight
        let header = drawerHeader
        let preview = drawerPreview
        let actions = drawerActions
        let info = drawerInfo
        let summary = drawerSourceSummary
        return InspectorMotionSurface(motion: motion ?? .settled, reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency) { frame in
            let destination = CGRect(x: destinationRectInWindow.minX, y: destinationRectInWindow.minY,
                width: contentWidth, height: height)
            let drawer = InspectorDrawerLayout.resolve(progress: frame.progress,
                sourceRectInWindow: sourceRectInWindow, destinationRectInWindow: destination,
                footerHeight: footerHeight, reduceMotion: reduceMotion)
            let coverRect = CGRect(x: drawer.shellRect.minX, y: drawer.coverTop,
                width: drawer.shellRect.width, height: drawer.coverHeight)
            let coverOpacity = reduceMotion ? frame.progress : min(1, frame.progress / 0.10)

            return ZStack(alignment: .topLeading) {
                DetailGlassBackground(cornerRadius: 22, compactShadow: compactShadow)
                    .frame(width: drawer.shellRect.width, height: drawer.shellRect.height)
                    .position(x: drawer.shellRect.midX, y: drawer.shellRect.midY)
                    .opacity(coverOpacity)

                ZStack(alignment: .topLeading) {
                    header
                        .padding(20)
                        .frame(width: contentWidth, alignment: .topLeading)
                        .opacity(frame.chromeOpacity)
                    VStack(alignment: .leading, spacing: 8) { preview }
                        .frame(width: max(1, contentWidth - 40), height: bodyHeight, alignment: .top)
                        .opacity(frame.contentOpacity)
                        .offset(x: 20, y: drawerHeaderHeight + frame.contentOffsetY)
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
                .mask(Path(roundedRect: drawer.shellRect, cornerRadius: 22))

                ZStack(alignment: .topLeading) {
                    InspectorDrawerCoverShape(lipDepth: drawer.lipDepth)
                        .path(in: coverRect)
                        .fill(textColorScheme == .dark
                            ? Color(red: 0.19, green: 0.21, blue: 0.25)
                            : Color(red: 0.85, green: 0.90, blue: 0.96))
                    VStack(alignment: .leading, spacing: 8) {
                        summary
                        Group {
                            if item.isSensitive {
                                Label(item.autoExpire ? "仅本地保存 · 复制 5 分钟后过期" : "受保护内容 · 仅本地保存", systemImage: "lock.shield")
                                    .font(.system(size: 10)).foregroundStyle(item.kind.tint)
                            }
                            actions
                            if let copyFeedback {
                                Text(copyFeedback).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).help(copyFeedback)
                            }
                            info
                        }
                        .opacity(frame.contentOpacity)
                        .allowsHitTesting(frame.contentOpacity >= 0.99)
                        .accessibilityHidden(frame.contentOpacity < 0.99)
                    }
                    .frame(width: max(1, contentWidth - 24), alignment: .topLeading)
                    .offset(x: drawer.shellRect.minX + 12, y: drawer.coverTop + 16)
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
                .mask(InspectorDrawerCoverShape(lipDepth: drawer.lipDepth).path(in: coverRect))
                .opacity(coverOpacity)
            }
        }
        .frame(width: contentWidth, height: height, alignment: .topLeading)
        .opacity(sourceRectInWindow == nil || destinationRectInWindow.width > 0 ? 1 : 0)
        .background(InspectorFrameReader { rect in
            if destinationRectInWindow != rect { destinationRectInWindow = rect }
        })
        .onChangeBackward(of: item.id) {
            showsInfo = false; copyFeedback = nil; showsMarkdownPreview = false; codeLanguage = "自动识别"
        }
    }

    private var drawerSymbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .secret: "lock.shield"
        case .image: "photo.on.rectangle"
        }
    }

    private var drawerSourceSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: drawerSymbol)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(item.kind.tint)
                .frame(width: 26, height: 26)
                .background(item.kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isSensitive && !store.isRevealed(item) ? "受保护的敏感内容" : item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(item.sourceApp).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 22, height: 26)
            }
            .buttonStyle(.plain).help("收起详情").accessibilityLabel("收起详情")
        }
        .frame(height: 28)
    }

    private var drawerHeader: some View {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.kind.label).font(.system(size: 16, weight: .semibold))
                    Text(headerMetadata)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).help(headerMetadata)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain).background(InspectorFrameReader(name: "ClipFlowInspector.close")).help("关闭详情").accessibilityLabel("关闭详情")
            }
    }

    @ViewBuilder private var drawerPreview: some View {
            if item.isImage {
                if (!item.isSensitive || store.isRevealed(item)), let url = store.imageURL(for: item) {
                    ZoomableDetailImage(url: url)
                        .frame(height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ClipThumbnailView(store: store, item: item, height: previewHeight, cornerRadius: 12,
                        showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                }
                if let dimensions = item.imageDimensionText {
                    Text(dimensions).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if item.kind == .code || markdownAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if markdownAvailable {
                            Picker("显示方式", selection: $showsMarkdownPreview) {
                                Text("源码").tag(false)
                                Text("预览").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                        }
                        Spacer(minLength: 4)
                        if !showsMarkdownPreview {
                            Picker("代码语言", selection: $codeLanguage) {
                                ForEach(DetailTextFormat.languages, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(maxWidth: 130)
                        }
                    }
                    DetailTextRenderer(text: store.displayFullText(for: item),
                        markdown: showsMarkdownPreview,
                        language: markdownAvailable && item.kind != .code && codeLanguage == "自动识别" ? "markdown" : codeLanguage,
                        dark: textColorScheme == .dark)
                        .frame(height: max(64, previewHeight - 32))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                SoftEdgeScrollView(showsEdgeEffects: false) {
                    Text(store.displayFullText(for: item))
                        .font(.system(size: item.kind == .code ? 12 : 13, weight: .regular,
                            design: item.kind == .code ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: previewHeight)
                .background(textColorScheme == .dark ? palette.inputFill : Color.white, in: RoundedRectangle(cornerRadius: 12))
            }

    }

    private var drawerActions: some View {
            HStack(spacing: 8) {
                Button("复制") {
                    let copied = ClipFlowRuntime.shared.copyToClipboard(item)
                    copyFeedback = copied ? "已复制到剪贴板" : store.lastCaptureStatus
                }
                .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
                Button("粘贴") {
                    if let onPasteAction { onPasteAction() }
                    else { ClipFlowRuntime.shared.paste(item); onClose() }
                }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                    .background(InspectorFrameReader(name: "ClipFlowInspector.paste"))
                Button { store.togglePin(item.id) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin").frame(width: 14)
                }
                .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
                .help(item.pinned ? "取消置顶" : "置顶条目")
                .accessibilityLabel(item.pinned ? "取消置顶" : "置顶条目")
                if item.privacy != .standard {
                    Button(store.isRevealed(item) ? "隐藏" : "显示") { store.toggleReveal(item.id) }
                        .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
                }
                Spacer(minLength: 0)
                Menu {
                    if let url = item.primaryURL {
                        Button("访问链接") { NSWorkspace.shared.open(url) }
                    }
                    Button("删除条目", role: .destructive) { store.delete(item.id); onClose() }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("更多操作")
            }
    }

    private var drawerInfo: some View {
            DisclosureGroup("更多信息", isExpanded: $showsInfo) {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("隐私级别", value: item.privacy.label)
                    infoRow("存储方式", value: item.localOnly ? "仅本地保存" : "普通本地历史")
                    infoRow("保留策略", value: item.autoExpire ? "复制 5 分钟后删除" : "手动清理")
                }
                .font(.system(size: 11)).padding(.top, 8)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var headerMetadata: String {
        var labels = [item.sourceApp, item.timeLabel]
        for label in item.labels where !label.isEmpty && !labels.contains(label) {
            labels.append(label)
        }
        return labels.joined(separator: " · ")
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value) }
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
                    Image(systemName: "folder").foregroundStyle(ClipCategory.smartStacks.tint).frame(width: 16)
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
            Spacer(minLength: 0)
            Text(store.statusSummary).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).help(store.statusSummary)
        }
        .padding(16)
        .frame(width: ClipFlowLayout.menuWidth, height: ClipFlowLayout.menuHeight)
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
                .fill(palette.orbA.opacity(restrained ? 0.18 : 1))
                .frame(width: 420, height: 420)
                .blur(radius: 60)
                .offset(x: -420, y: -180)

            Circle()
                .fill(palette.orbB.opacity(restrained ? 0.18 : 1))
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
            .background(CleanGlassBackground(cornerRadius: 28, elevated: true))
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

/// A separate hosting surface keeps highlight animation out of image/text layout.
struct LibrarySelectionChrome: View {
    let itemID: ClipboardItem.ID
    let selection: HistorySelection
    let tint: Color
    let palette: ClipFlowPalette
    @ViewState private var isSelected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(isSelected ? palette.softFill : palette.rowFill)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.22 : 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? tint.opacity(0.65) : palette.rowBorder,
                    lineWidth: isSelected ? 1.5 : 1))
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: 3)
                    .opacity(isSelected ? 1 : 0)
                    .padding(.vertical, 18).padding(.leading, 9)
            }
            .animation(reduceMotion ? nil : ClipFlowMotion.rowSelection, value: isSelected)
            .onReceive(selection.$itemID.map { $0 == itemID }.removeDuplicates()) {
                if isSelected != $0 { isSelected = $0 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let displayedSnippet: String
    let palette: ClipFlowPalette
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        VStack(alignment: .leading, spacing: item.kind == .image || item.kind == .code ? 6 : 3) {
            metadata
            if item.isImage {
                imageContent
            } else if item.kind == .code {
                Text(String(store.displayFullText(for: item).prefix(1200)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(5).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(itemTint.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                tags
            } else {
                Text(displayedSnippet)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                tags
            }
        }
        // Reserve the selection rail's gutter even when not selected.
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: LibraryCardLayout.height(for: item.kind), alignment: .top)

    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(item.sourceApp).lineLimit(1)
            Text(item.kind.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(itemTint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(itemTint.opacity(0.1), in: Capsule())
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.quickPaste.tint) }
            Spacer(minLength: 4)
            Text(item.timeLabel).lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .frame(height: 16)
    }

    @ViewBuilder private var imageContent: some View {
        let shape = LibraryImageShape.resolve(width: item.imageWidth, height: item.imageHeight)
        if shape == .landscape {
            ClipThumbnailView(store: store, item: item, height: 88, cornerRadius: 8,
                showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
            HStack {
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text("横向").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                ClipThumbnailView(store: store, item: item, height: 104, cornerRadius: 8,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    .frame(width: shape == .portrait ? 76 : 104)
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    tags
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tags: some View {
        HStack(spacing: 6) {
            Text(item.labels.filter { $0 != item.sourceApp }.prefix(2).joined(separator: " · "))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isSensitive {
                Label(item.privacy.label, systemImage: "lock.fill")
                    .foregroundStyle(item.privacy.color).lineLimit(1)
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .frame(height: 12)
    }

    private var itemTint: Color {
        item.kind.tint
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
    let rowFill: Color
    let selectedRowFill: Color
    let rowBorder: Color
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
                rowFill: Color(red: 0.18, green: 0.20, blue: 0.25),
                selectedRowFill: Color(red: 0.18, green: 0.20, blue: 0.25),
                rowBorder: Color.white.opacity(0.15),
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
            rowFill: Color(red: 0.965, green: 0.969, blue: 0.975),
            selectedRowFill: Color(red: 0.935, green: 0.95, blue: 0.975),
            rowBorder: Color(red: 0.65, green: 0.70, blue: 0.78).opacity(0.40),
            inputFill: Color.white.opacity(0.82),
            primaryButtonFill: Color(red: 0.30, green: 0.59, blue: 0.92),
            secondaryButtonFill: Color.white.opacity(0.74)
        )
    }
}
