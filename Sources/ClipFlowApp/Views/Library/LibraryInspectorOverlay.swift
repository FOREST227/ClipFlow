import AppKit
import SwiftUI

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
    @ViewState private var measuredFooterHeight: CGFloat = 0

    // Explicit API: Swift 6.2 gives the synthesized memberwise initializer
    // private access because of the stored DynamicProperty preferences.
    init(item: ClipboardItem, store: ClipFlowStore, palette: ClipFlowPalette,
         maxHeight: CGFloat, contentWidth: CGFloat = 438, compactShadow: Bool = false,
         onPasteAction: (() -> Void)? = nil, sourceRectInWindow: CGRect? = nil,
         motion: InspectorMotionProgress? = nil, onClose: @escaping () -> Void) {
        self.item = item
        _store = ObservedObject(wrappedValue: store)
        self.palette = palette
        self.maxHeight = maxHeight
        self.contentWidth = contentWidth
        self.compactShadow = compactShadow
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
            let transform = InspectorShellTransform.resolve(progress: frame.progress,
                sourceRectInWindow: sourceRectInWindow, destinationRectInWindow: destination,
                reduceMotion: reduceMotion)
            let coverRect = CGRect(x: drawer.shellRect.minX, y: drawer.coverTop,
                width: drawer.shellRect.width, height: drawer.coverHeight)
            let coverOpacity = reduceMotion ? frame.progress : min(1, frame.progress / 0.10)

            return ZStack(alignment: .topLeading) {
                DetailGlassBackground(cornerRadius: ClipFlowLayout.overlayRadius, compactShadow: compactShadow)
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
                    .opacity(frame.contentOpacity)
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
        .opacity(sourceRectInWindow == nil || destinationRectInWindow.width > 0 ? 1 : 0)
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
            showsInfo = false; copyFeedback = nil; showsMarkdownPreview = false; codeLanguage = "自动识别"
        }
    }

    private var drawerHeader: some View {
            HStack(alignment: .top, spacing: ClipFlowLayout.space12) {
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
            if item.isImage {
                let shape = LibraryImageShape.resolve(width: item.imageWidth, height: item.imageHeight)
                let columnWidth = max(120, contentWidth - 40)
                let pixelWidth = max(1, item.imageWidth ?? Double(columnWidth))
                let pixelHeight = max(1, item.imageHeight ?? Double(columnWidth))
                let naturalHeight = columnWidth * pixelHeight / pixelWidth
                let cap = DetailImageLayout.previewHeight(shape: shape, availableHeight: drawerHeight, expandedInfo: showsInfo)
                let imageHeight = min(previewHeight, max(64, min(cap, naturalHeight)))
                VStack(alignment: .leading, spacing: ClipFlowLayout.space8) {
                    if (!item.isSensitive || store.isRevealed(item)), let url = store.imageURL(for: item) {
                        ZoomableDetailImage(url: url)
                            .frame(maxWidth: .infinity)
                            .frame(height: imageHeight, alignment: .top)
                            .clipShape(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                    } else {
                        ClipThumbnailView(store: store, item: item, height: imageHeight,
                            cornerRadius: ClipFlowLayout.rowRadius,
                            showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    }
                    if let dimensions = item.imageDimensionText {
                        Text(dimensions).font(.system(size: 10))
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.bottom, ClipFlowLayout.space8)
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
                        .clipShape(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                        .padding(.bottom, ClipFlowLayout.space8)
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
                .padding(.bottom, ClipFlowLayout.space8)
                .background(textColorScheme == .dark ? palette.inputFill : Color.white,
                    in: RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
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
            .font(.system(size: 11)).foregroundStyle(ClipFlowPalette.secondaryText(for: textColorScheme))
    }

    private var headerMetadata: String {
        var labels = [item.sourceApp, item.timeLabel]
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

