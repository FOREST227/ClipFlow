import AppKit
import SwiftUI

struct LibraryInspectorOverlay: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    let maxHeight: CGFloat
    var contentWidth: CGFloat = 438
    var compactShadow = false
    var useBinderExtractMotion = false
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
    @ViewState private var measuredFooterHeight: CGFloat = 0
    @ViewState private var confirmsDelete = false

    private var unifiedWellColor: Color {
        textColorScheme == .dark
            ? Color(red: 0.110, green: 0.122, blue: 0.153)
            : Color(red: 0.965, green: 0.957, blue: 0.933)
    }

    private var unifiedWellNSColor: NSColor {
        textColorScheme == .dark
            ? NSColor(srgbRed: 0.110, green: 0.122, blue: 0.153, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1)
    }

    // Explicit API: Swift 6.2 gives the synthesized memberwise initializer
    // private access because of the stored DynamicProperty preferences.
    init(item: ClipboardItem, store: ClipFlowStore, palette: ClipFlowPalette,
         maxHeight: CGFloat, contentWidth: CGFloat = 438, compactShadow: Bool = false,
         useBinderExtractMotion: Bool = false,
         onPasteAction: (() -> Void)? = nil, sourceRectInWindow: CGRect? = nil,
         motion: InspectorMotionProgress? = nil, onClose: @escaping () -> Void) {
        self.item = item
        _store = ObservedObject(wrappedValue: store)
        self.palette = palette
        self.maxHeight = maxHeight
        self.contentWidth = contentWidth
        self.compactShadow = compactShadow
        self.useBinderExtractMotion = useBinderExtractMotion
        self.onPasteAction = onPasteAction
        self.sourceRectInWindow = sourceRectInWindow
        self.motion = motion
        self.onClose = onClose
    }

    private let drawerHeaderHeight: CGFloat = 84
    private var drawerFooterHeight: CGFloat {
        measuredFooterHeight > 1 ? measuredFooterHeight : 96
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
        return InspectorMotionSurface(motion: motion ?? .settled, reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency) { frame in
            let destination = CGRect(x: destinationRectInWindow.minX, y: destinationRectInWindow.minY,
                width: contentWidth, height: height)
            // Lay the shell out at its final size. Motion is a scale and offset, not a layout pass.
            let drawer = InspectorDrawerLayout.resolve(progress: 1,
                sourceRectInWindow: sourceRectInWindow, destinationRectInWindow: destination,
                footerHeight: footerHeight, reduceMotion: true)
            let p = min(1, max(0, frame.progress))
            let easeOut = 1 - pow(1 - p, 3)
            let transform: InspectorShellTransform = useBinderExtractMotion
                ? InspectorShellTransform(
                    scaleX: reduceMotion ? 1 : (0.945 + 0.055 * easeOut),
                    scaleY: reduceMotion ? 1 : (0.945 + 0.055 * easeOut),
                    offset: CGSize(width: 0, height: reduceMotion ? 0 : 48 * (1 - easeOut))
                )
                : InspectorShellTransform.resolve(progress: frame.progress,
                    sourceRectInWindow: sourceRectInWindow, destinationRectInWindow: destination,
                    reduceMotion: reduceMotion)
            let coverRect = CGRect(x: drawer.shellRect.minX, y: drawer.coverTop,
                width: drawer.shellRect.width, height: drawer.coverHeight)
            let coverOpacity = useBinderExtractMotion
                ? (reduceMotion ? p : min(1, p * 3.0))
                : (reduceMotion ? frame.progress : min(1, frame.progress / 0.10))
            let headerOpacity = useBinderExtractMotion ? coverOpacity : frame.chromeOpacity
            let bodyOpacity = useBinderExtractMotion ? coverOpacity : frame.contentOpacity
            let bodyOffsetY = useBinderExtractMotion ? 0 : frame.contentOffsetY

            return ZStack(alignment: .topLeading) {
                DetailGlassBackground(cornerRadius: ClipFlowLayout.overlayRadius, compactShadow: compactShadow)
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipFlowLayout.overlayRadius, style: .continuous)
                            .strokeBorder(FolioTheme.primaryAccent(for: textColorScheme).opacity(0.45), lineWidth: 1.25)
                    )
                    .frame(width: drawer.shellRect.width, height: drawer.shellRect.height)
                    .position(x: drawer.shellRect.midX, y: drawer.shellRect.midY)
                    .opacity(coverOpacity)

                ZStack(alignment: .topLeading) {
                    header
                        .padding(20)
                        .frame(width: contentWidth, alignment: .topLeading)
                        .opacity(headerOpacity)
                    VStack(alignment: .leading, spacing: 8) { preview }
                        .frame(width: max(1, contentWidth - 40), height: bodyHeight, alignment: .top)
                        .opacity(bodyOpacity)
                        .offset(x: 20, y: drawerHeaderHeight + bodyOffsetY)
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
                .mask(Path(roundedRect: drawer.shellRect, cornerRadius: ClipFlowLayout.overlayRadius))

                ZStack(alignment: .topLeading) {
                    InspectorDrawerCoverShape(lipDepth: drawer.lipDepth)
                        .path(in: coverRect)
                        .fill(ClipFlowPalette.inspectorCover(for: textColorScheme))
                    VStack(alignment: .leading, spacing: ClipFlowLayout.space8) {
                        if item.isSensitive {
                            Label(item.autoExpire ? "仅本地保存 · 复制 5 分钟后过期" : "受保护内容 · 仅本地保存", systemImage: "lock.shield")
                                .font(.system(size: 10)).foregroundStyle(item.kind.labelColor(for: textColorScheme))
                        }
                        actions
                        if let copyFeedback {
                            Text(copyFeedback).font(.system(size: 10))
                                .foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme))
                                .lineLimit(1).help(copyFeedback)
                        }
                        info
                    }
                    .padding(.bottom, ClipFlowLayout.space8)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: InspectorFooterHeightKey.self, value: proxy.size.height + ClipFlowLayout.space16)
                    })
                    .opacity(bodyOpacity)
                    .allowsHitTesting(frame.contentOpacity >= 0.99)
                    .accessibilityHidden(frame.contentOpacity < 0.99)
                    .frame(width: max(1, contentWidth - 24), alignment: .topLeading)
                    .offset(x: drawer.shellRect.minX + 12, y: drawer.coverTop + 16)
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
                .mask(InspectorDrawerCoverShape(lipDepth: drawer.lipDepth).path(in: coverRect))
                .opacity(coverOpacity)
            }
            .scaleEffect(x: transform.scaleX, y: transform.scaleY, anchor: .center)
            .offset(x: transform.offset.width, y: transform.offset.height)
        }
        .frame(width: contentWidth, height: height, alignment: .topLeading)
        .opacity(useBinderExtractMotion || sourceRectInWindow == nil || destinationRectInWindow.width > 0 ? 1 : 0)
        .background(InspectorFrameReader { rect in
            // Ignore transforms that only move the visual shell; the layout frame is the destination.
            if destinationRectInWindow != rect { destinationRectInWindow = rect }
        })
        .onPreferenceChange(InspectorFooterHeightKey.self) { next in
            let rounded = ceil(next)
            if rounded > 1, abs(rounded - measuredFooterHeight) > 0.5 {
                measuredFooterHeight = rounded
            }
        }
        .onChangeBackward(of: item.id) {
            showsInfo = false; copyFeedback = nil; showsMarkdownPreview = false; codeLanguage = "自动识别"; confirmsDelete = false
        }
        .confirmationDialog("删除这条剪贴卡片？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除卡片", role: .destructive) {
                store.delete(item.id)
                onClose()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(item.title)」将被永久移除，此操作不能撤销。")
        }
    }

    private var drawerHeader: some View {
            HStack(alignment: .top, spacing: ClipFlowLayout.space12) {
                AppIconBadgeView(item: item, size: 28)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: ClipFlowLayout.space4) {
                    HStack(spacing: ClipFlowLayout.space8) {
                        Text(item.isSensitive && !store.isRevealed(item) ? "受保护的敏感内容" : item.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(item.kind.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.kind.labelColor(for: textColorScheme))
                            .padding(.horizontal, ClipFlowLayout.space8)
                            .padding(.vertical, ClipFlowLayout.space4)
                            .background(item.kind.tint.opacity(0.12), in: Capsule())
                    }
                    Text(headerMetadata)
                        .font(.system(size: 11))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme))
                        .lineLimit(2).help(headerMetadata)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain).background(InspectorFrameReader(name: "ClipFlowInspector.close")).help("关闭详情").accessibilityLabel("关闭详情")
            }
    }

    @ViewBuilder private var drawerPreview: some View {
            let displayText = item.isImage ? "" : store.displayFullText(for: item)
            let preRendered: PreRenderedCode? = (!item.isImage && (!item.isSensitive || store.isRevealed(item)))
                ? DetailTextPrewarmer.shared.cached(for: item, text: displayText, language: codeLanguage)
                : nil

            if item.isImage {
                let imageHeight = max(140, drawerBodyHeight - 8)
                Group {
                    if (!item.isSensitive || store.isRevealed(item)), let url = store.imageURL(for: item) {
                        ZoomableDetailImage(
                            url: url,
                            placeholder: store.cachedImagePreview(for: item),
                            canvasBackground: unifiedWellNSColor
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                                .strokeBorder(FolioTheme.hairline(for: textColorScheme), lineWidth: 1)
                        )
                    } else {
                        ClipThumbnailView(store: store, item: item, height: imageHeight,
                            cornerRadius: ClipFlowLayout.rowRadius,
                            showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    let rendererHeight = max(64, previewHeight - 32)
                    ZStack(alignment: .topLeading) {
                        // Instant 0ms pre-rendered native underlay eliminates any WebView boot flash
                        if let preRendered, showsMarkdownPreview, let blocks = preRendered.markdownBlocks, !blocks.isEmpty {
                            NativeMarkdownDocumentView(blocks: blocks, dark: textColorScheme == .dark)
                                .padding(14)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else if let preRendered {
                            Text(textColorScheme == .dark ? preRendered.dark : preRendered.light)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .lineSpacing(4)
                                .padding(14)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        DetailTextRenderer(text: displayText,
                            markdown: showsMarkdownPreview,
                            language: markdownAvailable && item.kind != .code && codeLanguage == "自动识别" ? "markdown" : codeLanguage,
                            dark: textColorScheme == .dark)
                    }
                    .frame(height: rendererHeight)
                    .background(unifiedWellColor)
                    .clipShape(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                            .strokeBorder(FolioTheme.hairline(for: textColorScheme), lineWidth: 1)
                    )
                    .padding(.bottom, ClipFlowLayout.space8)
                }
            } else {
                SoftEdgeScrollView(showsEdgeEffects: false) {
                    Text(displayText)
                        .font(.system(size: 13, weight: .regular))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(height: previewHeight)
                .background(unifiedWellColor, in: RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                        .strokeBorder(FolioTheme.hairline(for: textColorScheme), lineWidth: 1)
                )
            }
    }

    private var drawerActions: some View {
            let isQueued = store.pasteStack.contains(item.id)
            return HStack(spacing: 8) {
                Button("复制") {
                    let copied = ClipFlowRuntime.shared.copyToClipboard(item)
                    copyFeedback = copied ? "已复制到剪贴板" : store.lastCaptureStatus
                }
                .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 28, horizontalPadding: 12))
                Button("粘贴") {
                    if let onPasteAction { onPasteAction() }
                    else { ClipFlowRuntime.shared.paste(item); onClose() }
                }
                .buttonStyle(FolioButtonStyle(prominence: .primary, height: 28, horizontalPadding: 14))
                .background(InspectorFrameReader(name: "ClipFlowInspector.paste"))
                Button { store.togglePin(item.id) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(item.pinned ? ClipCategory.pinned.labelColor(for: textColorScheme) : Color.primary.opacity(0.82))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 28, horizontalPadding: 0))
                .help(item.pinned ? "取消置顶" : "置顶条目")
                .accessibilityLabel(item.pinned ? "取消置顶" : "置顶条目")
                Button { store.pasteStack.toggle(item.id) } label: {
                    Image(systemName: isQueued ? "checkmark" : "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(FolioButtonStyle(prominence: isQueued ? .tonalAccent : .secondary, height: 28, horizontalPadding: 0))
                .help(isQueued ? "移出顺序粘贴" : "加入顺序粘贴")
                if item.privacy != .standard {
                    Button(store.isRevealed(item) ? "隐藏" : "显示") { store.toggleReveal(item.id) }
                        .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 28, horizontalPadding: 10))
                }
                if let url = item.primaryURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "safari").frame(width: 28, height: 28)
                    }
                    .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 28, horizontalPadding: 0))
                    .help("访问链接")
                }
                Spacer(minLength: 0)
                Button {
                    confirmsDelete = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 28, horizontalPadding: 0))
                .help("删除条目")
                .accessibilityLabel("删除条目")
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
            .font(.system(size: 11)).foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme))
    }

    private var headerMetadata: String {
        var labels = [item.sourceApp, item.timeLabel]
        if let dim = item.imageDimensionText, !labels.contains(dim) {
            labels.append(dim)
        }
        for label in item.labels where !label.isEmpty && !labels.contains(label) {
            labels.append(label)
        }
        return labels.joined(separator: " · ")
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme)); Spacer(); Text(value) }
    }
}

private struct InspectorFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

