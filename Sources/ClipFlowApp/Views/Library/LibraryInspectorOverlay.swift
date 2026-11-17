import AppKit
import SwiftUI

private enum MarkdownDisplay: String, CaseIterable, Hashable {
    case source
    case preview

    var title: String {
        switch self {
        case .source: "源码"
        case .preview: "预览"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .source: "markdown-source"
        case .preview: "markdown-preview"
        }
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
    var onPastePlainAction: (() -> Void)? = nil
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
    private var showsSpreadsheetText: Bool {
        SpreadsheetClipboard.hasTabularData(item) || item.labels.contains("表格")
    }
    private var tableGrid: SpreadsheetPreviewGrid? {
        guard !item.isSensitive || store.isRevealed(item) else { return nil }
        return SpreadsheetPreview.grid(for: item)
    }
    private var showsTableGrid: Bool {
        guard let tableGrid else { return false }
        return tableGrid.rows.count > 1 || tableGrid.columnCount > 1
    }
    private var heading: String {
        if item.isSensitive && !store.isRevealed(item) { return "受保护的敏感内容" }
        return SpreadsheetPreview.title(for: item)
    }
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
         onPasteAction: (() -> Void)? = nil, onPastePlainAction: (() -> Void)? = nil,
         sourceRectInWindow: CGRect? = nil,
         motion: InspectorMotionProgress? = nil,
         preferMarkdownPreview: Bool = false, onClose: @escaping () -> Void) {
        // Documentation screenshots open Markdown on 预览. The pill is not an AppKit control.
        self.item = item
        _store = ObservedObject(wrappedValue: store)
        self.palette = palette
        self.maxHeight = maxHeight
        self.contentWidth = contentWidth
        self.compactShadow = compactShadow
        self.onPasteAction = onPasteAction
        self.onPastePlainAction = onPastePlainAction
        self.sourceRectInWindow = sourceRectInWindow
        self.motion = motion
        _showsMarkdownPreview = State(initialValue: preferMarkdownPreview)
        self.onClose = onClose
    }

    private let drawerHeaderHeight: CGFloat = 84
    private var drawerFooterHeight: CGFloat {
        if measuredFooterHeight > 1 { return measuredFooterHeight }
        return PlainTextPaste.hasRichText(item) ? 136 : 96
    }
    private var drawerHeight: CGFloat {
        if item.isImage || item.kind == .code || markdownAvailable { return maxHeight }
        if showsTableGrid, let tableGrid { return tableDrawerHeight(for: tableGrid) }
        let font = NSFont.systemFont(ofSize: 13)
        let bounds = (store.displayFullText(for: item) as NSString).boundingRect(
            with: CGSize(width: max(160, contentWidth - 64), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(maxHeight, drawerHeaderHeight + max(64, ceil(bounds.height) + 24) + drawerFooterHeight + 24)
    }
    private var drawerBodyHeight: CGFloat { max(64, drawerHeight - drawerHeaderHeight - drawerFooterHeight - 24) }
    private var previewHeight: CGFloat { drawerBodyHeight }

    /// A short sheet stays about as tall as its rows. A long sheet stops at the pane and scrolls.
    private func tableDrawerHeight(for grid: SpreadsheetPreviewGrid) -> CGFloat {
        let caption: CGFloat = grid.overflowCaption == nil ? 0 : 26
        let gridBlock = CGFloat(grid.rows.count) * 34 + 20 + caption
        let natural = drawerHeaderHeight + gridBlock + drawerFooterHeight + 24
        return min(maxHeight, max(240, natural))
    }

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
                    .allowsHitTesting(frame.contentOpacity > 0.8)
                    .accessibilityHidden(frame.contentOpacity <= 0.8)
                    .frame(width: max(1, contentWidth - 24), alignment: .topLeading)
                    .offset(x: drawer.shellRect.minX + 12, y: drawer.coverTop + 16)
                }
                .frame(width: contentWidth, height: height, alignment: .topLeading)
                // Flatten text into the cover before masking. Without this, button titles
                // stay in a second layer and the live window shows empty pills.
                .compositingGroup()
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
                        Text(heading)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(SpreadsheetPreview.typeLabel(for: item))
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
                let imageHeight = max(64, previewHeight)
                Group {
                    if (!item.isSensitive || store.isRevealed(item)), let url = store.imageURL(for: item) {
                        ZoomableDetailImage(url: url, fillsHeight: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                    } else {
                        ClipThumbnailView(store: store, item: item, height: imageHeight,
                            cornerRadius: ClipFlowLayout.rowRadius,
                            showsDimensionLabel: false, contentMode: .fit, insetPreview: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(height: imageHeight)
            } else if let grid = tableGrid, showsTableGrid {
                SpreadsheetGridView(grid: grid, style: .detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(height: previewHeight)
                    .padding(.bottom, ClipFlowLayout.space8)
                    .background(palette.rowFill,
                        in: RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
            } else if item.kind == .code || markdownAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if markdownAvailable {
                            ClipFlowPillPicker(
                                options: MarkdownDisplay.allCases,
                                selection: Binding(
                                    get: { showsMarkdownPreview ? MarkdownDisplay.preview : .source },
                                    set: { showsMarkdownPreview = $0 == .preview }
                                ),
                                accessibilityTitle: "显示方式",
                                width: 148,
                                height: 28,
                                title: \.title,
                                optionAccessibilityLabel: \.title,
                                accessibilityIdentifier: \.accessibilityIdentifier
                            )
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
                            design: item.kind == .code || showsSpreadsheetText ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: previewHeight)
                .padding(.bottom, ClipFlowLayout.space8)
                .background(palette.rowFill,
                    in: RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous))
            }

    }

    private var offersExcelInsert: Bool {
        ExcelInsertOffer.shouldOffer(item: item, bundleIDs: ExcelInsertContext.currentBundleIDs())
    }

    private var actionSet: InspectorActionSet {
        InspectorCommands.actions(
            pinned: item.pinned,
            canSaveSnippet: SnippetLibrary.canSave(item),
            showsReveal: item.privacy != .standard,
            revealed: store.isRevealed(item),
            hasRichText: PlainTextPaste.hasRichText(item),
            hasOriginalTypes: SpreadsheetClipboard.hasOriginalTypes(item),
            offersExcelInsert: offersExcelInsert
        )
    }

    private var drawerActions: some View {
        let set = actionSet
        return InspectorActionFlow(commands: set.commands, iconClusterCount: set.iconClusterCount) { command in
            commandButton(command, action: command.id == .more ? { showOverflowMenu() } : nil)
                .background(InspectorFrameReader(name: InspectorAnchor.action(command.id)))
        }
        .background(InspectorFrameReader(name: InspectorAnchor.actions))
    }

    private func commandButton(_ command: InspectorCommand, action: (() -> Void)? = nil) -> some View {
        InspectorCommandButton(
            command: command,
            fill: command.isPrimary ? palette.primaryButtonFill : palette.rowFill,
            foreground: command.isPrimary ? .white : Color.primary,
            border: command.isPrimary ? .clear : palette.rowBorder,
            action: {
                if let action { action() } else { perform(command) }
            }
        )
    }

    private func showOverflowMenu() {
        let entries = InspectorCommands.overflowMenu(
            pinned: item.pinned,
            canSaveSnippet: SnippetLibrary.canSave(item),
            hasRichText: PlainTextPaste.hasRichText(item),
            canOpenURL: item.primaryURL != nil,
            canRevealInFinder: InspectorCommands.canRevealInFinder(item),
            hasOriginalTypes: SpreadsheetClipboard.hasOriginalTypes(item),
            offersExcelInsert: offersExcelInsert
        )
        InspectorOverflowMenu.present(entries: entries) { action in
            performOverflow(action)
        }
    }

    private func performOverflow(_ action: InspectorOverflowAction) {
        switch action.id {
        case .copyPlain:
            perform(.init(id: .copyPlain, title: action.title, symbol: action.symbol, accessibilityLabel: action.title))
        case .pastePlain:
            perform(.init(id: .pastePlain, title: action.title, symbol: action.symbol, accessibilityLabel: action.title))
        case .pin:
            store.togglePin(item.id)
        case .saveSnippet:
            store.requestSaveSnippet(fromItemID: item.id)
        case .openURL:
            if let url = item.primaryURL { NSWorkspace.shared.open(url) }
        case .revealInFinder:
            if let url = InspectorCommands.finderURL(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .copyOriginal:
            perform(.init(id: .copyOriginal, title: action.title, symbol: action.symbol, accessibilityLabel: action.title))
        case .insertDown:
            perform(.init(id: .insertDown, title: action.title, symbol: action.symbol, accessibilityLabel: action.title))
        case .insertRight:
            perform(.init(id: .insertRight, title: action.title, symbol: action.symbol, accessibilityLabel: action.title))
        case .delete:
            store.delete(item.id)
            onClose()
        }
    }

    private func perform(_ command: InspectorCommand) {
        switch command.id {
        case .copy:
            let copied = ClipFlowRuntime.shared.copyToClipboard(item)
            copyFeedback = copied ? "已复制到剪贴板" : store.lastCaptureStatus
        case .paste:
            if let onPasteAction { onPasteAction() }
            else { ClipFlowRuntime.shared.paste(item); onClose() }
        case .pin:
            store.togglePin(item.id)
        case .saveSnippet:
            store.requestSaveSnippet(fromItemID: item.id)
        case .reveal:
            store.toggleReveal(item.id)
        case .copyOriginal:
            let copied = ClipFlowRuntime.shared.copyOriginalToClipboard(item)
            copyFeedback = copied ? "已放回剪贴板，未粘贴" : store.lastCaptureStatus
        case .insertDown:
            ClipFlowRuntime.shared.insertIntoExcel(item, shift: .down)
            onClose()
        case .insertRight:
            ClipFlowRuntime.shared.insertIntoExcel(item, shift: .right)
            onClose()
        case .copyPlain:
            let copied = ClipFlowRuntime.shared.copyPlainText(item)
            copyFeedback = copied ? "已复制纯文本到剪贴板" : store.lastCaptureStatus
        case .pastePlain:
            if let onPastePlainAction { onPastePlainAction() }
            else { ClipFlowRuntime.shared.pastePlainText(item); onClose() }
        case .more:
            break
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

