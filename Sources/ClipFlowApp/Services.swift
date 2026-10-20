import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

private struct CapturedImagePayload {
    let data: Data
    let size: CGSize
}

private extension NSImage {
    func clipFlowPNGPayload() -> CapturedImagePayload? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        return CapturedImagePayload(data: pngData, size: size)
    }
}

private enum QuickPastePanelLayout {
    static let panelWidth: CGFloat = ClipFlowLayout.menuWidth
    static let panelHeight: CGFloat = 520
    static let cornerRadius: CGFloat = 24
    static let anchorOffset: CGFloat = 18
    static let screenInset: CGFloat = 12
}

@MainActor
final class ClipFlowRuntime: NSObject {
    static let shared = ClipFlowRuntime()

    let store = ClipFlowStore.shared

    private let clipboardMonitor: ClipboardMonitor
    private let pasteService: PasteService
    private lazy var hudController = QuickPastePanelController(store: store) { [weak self] item in
        self?.paste(item)
    } onOpenLibrary: { [weak self] in
        self?.openLibrary()
    }
    private lazy var hotKeyController = HotKeyController { [weak self] in
        guard self?.store.isRecordingShortcut == false else { return }
        self?.toggleHUD()
    }

    private var appActivationObserver: NSObjectProtocol?
    private var started = false
    private var lastExternalApp: NSRunningApplication?

    override private init() {
        clipboardMonitor = ClipboardMonitor(store: store)
        pasteService = PasteService(store: store)
        super.init()
        pasteService.monitor = clipboardMonitor
    }

    func start() {
        guard !started else { return }
        started = true

        store.start()
        observeFrontmostApp()
        clipboardMonitor.start()
        store.registerShortcut = { [weak self] shortcut in
            guard let self else { return "快捷键服务已停止" }
            return self.hotKeyController.register(shortcut)
        }
        store.suspendShortcut = { [weak self] in self?.hotKeyController.stop() }
        store.shortcutError = hotKeyController.register(store.quickPasteShortcut)
        store.purgeExpired()
        store.lastCaptureStatus = store.capturePaused ? "已暂停剪贴监听" : "正在监听系统剪贴板"
    }

    func toggleHUD() {
        hudController.toggle(anchorAt: NSEvent.mouseLocation, preferredTarget: lastExternalApp)
    }

    func showHUD() {
        hudController.show(anchorAt: NSEvent.mouseLocation, preferredTarget: lastExternalApp)
    }

    func hideHUD() {
        hudController.hide()
    }

    func paste(_ item: ClipboardItem) {
        hudController.hide()
        pasteService.paste(item, preferredTarget: lastExternalApp)
    }

    func copyToClipboard(_ item: ClipboardItem) {
        pasteService.copyToClipboard(item)
    }

    func openLibrary() {
        hudController.hide()
        // The dedicated controller activates the correct window. Choosing an
        // arbitrary NSApp window afterwards could bring Settings back in front.
        AppNavigationCenter.shared.openLibraryWindow?()
    }

    func restartApplication() {
        guard let appURL = relaunchBundleURL() else {
            store.lastCaptureStatus = "无法定位应用包，暂时不能重启"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]

        do {
            try process.run()
            store.lastCaptureStatus = "正在重启 ClipFlow"
            DispatchQueue.main.asyncAfter(deadline: .now() + ClipFlowMotion.relaunchDelay) {
                NSApp.terminate(nil)
            }
        } catch {
            store.lastCaptureStatus = "重启失败，请稍后再试"
        }
    }

    private func observeFrontmostApp() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }

            Task { @MainActor [weak self] in
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self?.lastExternalApp = app
                }
            }
        }
    }

    private func relaunchBundleURL() -> URL? {
        let candidates = [Bundle.main.bundleURL, Bundle.main.executableURL].compactMap { $0 }

        for candidate in candidates {
            let path = candidate.path

            if path.hasSuffix(".app") {
                return candidate
            }

            if let range = path.range(of: ".app/") {
                return URL(fileURLWithPath: "\(path[..<range.lowerBound]).app")
            }
        }

        return nil
    }
}

@MainActor
final class ClipboardMonitor {
    private let store: ClipFlowStore
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: ClipFlowStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: ClipFlowMotion.clipboardPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        timer.tolerance = ClipFlowMotion.clipboardPollTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func ignoreCurrentPasteboardUpdate() {
        lastChangeCount = pasteboard.changeCount
    }

    func poll(sourceApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        store.purgeExpired()
        if store.capturePaused {
            lastChangeCount = pasteboard.changeCount
            return
        }

        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let frontmostApp = sourceApplication
        let sourceBundleID = frontmostApp?.bundleIdentifier

        if (sourceBundleID != nil && sourceBundleID == Bundle.main.bundleIdentifier) || store.isExcluded(bundleID: sourceBundleID) {
            return
        }

        if let imagePayload = imagePayloadFromPasteboard() {
            store.ingestCopiedImage(
                imagePayload.data,
                size: imagePayload.size,
                sourceApp: frontmostApp?.localizedName ?? "未知应用",
                sourceBundleID: sourceBundleID
            )
            return
        }

        guard let text = pasteboard.string(forType: .string) else { return }

        store.ingestCopiedText(
            text,
            sourceApp: frontmostApp?.localizedName ?? "未知应用",
            sourceBundleID: sourceBundleID
        )
    }

    private func imagePayloadFromPasteboard() -> CapturedImagePayload? {
        if let image = NSImage(pasteboard: pasteboard),
           let payload = image.clipFlowPNGPayload() {
            return payload
        }

        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           fileURLs.count == 1,
           let fileURL = fileURLs.first,
           let type = UTType(filenameExtension: fileURL.pathExtension),
           type.conforms(to: .image),
           let image = NSImage(contentsOf: fileURL),
           let payload = image.clipFlowPNGPayload() {
            return payload
        }

        return nil
    }
}

@MainActor
final class PasteService {
    private let store: ClipFlowStore
    weak var monitor: ClipboardMonitor?

    init(store: ClipFlowStore) {
        self.store = store
    }

    func paste(_ item: ClipboardItem, preferredTarget: NSRunningApplication?) {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard restore(item, to: pasteboard) else {
            store.lastCaptureStatus = item.isImage ? "图片资源不可用，请重新复制一次" : "恢复剪贴内容失败"
            return
        }

        let targetApp = preferredTarget ?? NSWorkspace.shared.frontmostApplication
        targetApp?.activate(options: [.activateAllWindows])

        guard requestAccessibilityIfNeeded() else {
            store.lastCaptureStatus = "已复制回剪贴板。请在系统设置中允许 ClipFlow 使用辅助功能后再试。"
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + ClipFlowMotion.pasteActivationDelay) {
            self.sendPasteShortcut()
        }

        store.lastCaptureStatus = "已粘贴到 \(targetApp?.localizedName ?? "前台应用")"
    }

    func copyToClipboard(_ item: ClipboardItem) {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard restore(item, to: pasteboard) else {
            store.lastCaptureStatus = item.isImage ? "图片资源不可用，请重新复制一次" : "复制到剪贴板失败"
            return
        }

        store.lastCaptureStatus = "已复制到剪贴板，可在目标输入框中手动粘贴"
    }

    private func restore(_ item: ClipboardItem, to pasteboard: NSPasteboard) -> Bool {
        if item.isImage {
            guard let imageData = store.imageData(for: item),
                  let image = NSImage(data: imageData) else {
                return false
            }

            if pasteboard.writeObjects([image]) {
                return true
            }

            return pasteboard.setData(imageData, forType: .png)
        }

        return pasteboard.setString(item.fullText, forType: .string)
    }

    private func requestAccessibilityIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func sendPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeV: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

@MainActor
final class QuickPastePanelController: NSObject, NSWindowDelegate {
    private let store: ClipFlowStore
    private let onPaste: (ClipboardItem) -> Void
    private let onOpenLibrary: () -> Void
    private var panel: QuickPastePanel?

    init(store: ClipFlowStore, onPaste: @escaping (ClipboardItem) -> Void, onOpenLibrary: @escaping () -> Void) {
        self.store = store
        self.onPaste = onPaste
        self.onOpenLibrary = onOpenLibrary
    }

    func toggle(anchorAt mouseLocation: CGPoint, preferredTarget: NSRunningApplication?) {
        if panel?.isVisible == true {
            hide()
        } else {
            show(anchorAt: mouseLocation, preferredTarget: preferredTarget)
        }
    }

    func show(anchorAt mouseLocation: CGPoint, preferredTarget: NSRunningApplication?) {
        let panel = makePanel()
        panel.contentView = NSHostingView(
            rootView: QuickPastePanelView(
                store: store,
                preferredTargetName: preferredTarget?.localizedName,
                onPaste: onPaste,
                onOpenLibrary: onOpenLibrary,
                onClose: { [weak self] in
                    self?.hide()
                }
            )
        )

        configurePanelMask(panel)
        position(panel: panel, near: mouseLocation)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        guard let panel else { return }
        panel.delegate = nil
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    private func makePanel() -> QuickPastePanel {
        if let existing = panel {
            existing.delegate = nil
            existing.contentView = nil
            existing.orderOut(nil)
            existing.close()
            self.panel = nil
        }

        let panel = QuickPastePanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickPastePanelLayout.panelWidth, height: QuickPastePanelLayout.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? QuickPastePanel === panel else { return }
        hide()
    }

    private func configurePanelMask(_ panel: QuickPastePanel) {
        let radius = QuickPastePanelLayout.cornerRadius
        let views: [NSView] = [panel.contentView, panel.contentView?.superview].compactMap { $0 }

        for view in views {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = true
            if #available(macOS 10.15, *) {
                view.layer?.cornerCurve = .continuous
            }
        }
    }

    private func position(panel: NSPanel, near mouseLocation: CGPoint) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 120, y: 120, width: 1200, height: 800)
        let panelSize = panel.frame.size
        let offset = QuickPastePanelLayout.anchorOffset
        let inset = QuickPastePanelLayout.screenInset

        let candidateOrigins: [CGPoint] = [
            CGPoint(x: mouseLocation.x + offset, y: mouseLocation.y - panelSize.height - offset),
            CGPoint(x: mouseLocation.x - panelSize.width - offset, y: mouseLocation.y - panelSize.height - offset),
            CGPoint(x: mouseLocation.x + offset, y: mouseLocation.y + offset),
            CGPoint(x: mouseLocation.x - panelSize.width - offset, y: mouseLocation.y + offset)
        ]

        let bestOrigin = candidateOrigins.min { lhs, rhs in
            placementScore(for: lhs, panelSize: panelSize, mouseLocation: mouseLocation, visibleFrame: visibleFrame, inset: inset)
                < placementScore(for: rhs, panelSize: panelSize, mouseLocation: mouseLocation, visibleFrame: visibleFrame, inset: inset)
        } ?? candidateOrigins[0]

        let clampedOrigin = clamp(
            origin: bestOrigin,
            panelSize: panelSize,
            to: visibleFrame.insetBy(dx: inset, dy: inset)
        )

        panel.setFrameOrigin(clampedOrigin)
    }

    private func placementScore(
        for origin: CGPoint,
        panelSize: CGSize,
        mouseLocation: CGPoint,
        visibleFrame: CGRect,
        inset: CGFloat
    ) -> CGFloat {
        let safeFrame = visibleFrame.insetBy(dx: inset, dy: inset)
        let clampedOrigin = clamp(origin: origin, panelSize: panelSize, to: safeFrame)

        let overflowX = abs(origin.x - clampedOrigin.x)
        let overflowY = abs(origin.y - clampedOrigin.y)
        let overflowPenalty = (overflowX + overflowY) * 20

        let panelCenter = CGPoint(
            x: clampedOrigin.x + panelSize.width / 2,
            y: clampedOrigin.y + panelSize.height / 2
        )
        let distancePenalty = hypot(panelCenter.x - mouseLocation.x, panelCenter.y - mouseLocation.y)

        return overflowPenalty + distancePenalty
    }

    private func clamp(origin: CGPoint, panelSize: CGSize, to frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - panelSize.width)),
            y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - panelSize.height))
        )
    }
}

final class QuickPastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

struct QuickPastePanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipFlowStore
    let preferredTargetName: String?
    let onPaste: (ClipboardItem) -> Void
    let onOpenLibrary: () -> Void
    let onClose: () -> Void

    @ViewState private var query = ""
    @ViewState private var selectedItemID: UUID?
    @ViewState private var inspectingItemID: UUID?

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        let clips = store.hudItems(matching: query)

        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("快速粘贴", systemImage: "cursorarrow.rays")
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Spacer()

                    Button("关闭", action: onClose)
                        .buttonStyle(HUDCompactButtonStyle(fill: palette.secondaryButtonFill))
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)

                    TextField("搜索最近内容", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.inputFill)
                )

                if clips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有捕获到内容")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("先去其他应用复制文字或图片，然后按下 \(store.quickPasteShortcut.displayName)，就能在指针附近把它调出来。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(clips) { item in
                                HUDInteractiveRow(
                                    item: item,
                                    store: store,
                                    isSelected: selectedItemID == item.id,
                                    onSelect: {
                                        selectedItemID = item.id
                                    },
                                    onPaste: {
                                        selectedItemID = item.id
                                        onClose()
                                        onPaste(item)
                                    },
                                    onInspect: {
                                        selectedItemID = item.id
                                        withAnimation(ClipFlowMotion.overlay) {
                                            inspectingItemID = inspectingItemID == item.id ? nil : item.id
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                HStack(spacing: 8) {
                    Button("打开主窗口") {
                        onClose()
                        onOpenLibrary()
                    }
                    .buttonStyle(HUDCompactButtonStyle(fill: palette.secondaryButtonFill))

                    Button("粘贴选中项") {
                        if let selected = clips.first(where: { $0.id == selectedItemID }) ?? clips.first {
                            selectedItemID = selected.id
                            onClose()
                            onPaste(selected)
                        }
                    }
                    .buttonStyle(HUDCompactButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                }
            }
            .blur(radius: inspectingItem == nil ? 0 : ClipFlowMotion.backgroundDefocusRadius)

            if let inspectingItem {
                HUDInspectorOverlay(
                    item: inspectingItem,
                    store: store,
                    onClose: {
                        withAnimation(ClipFlowMotion.overlay) {
                            inspectingItemID = nil
                        }
                    },
                    onPaste: {
                        withAnimation(ClipFlowMotion.overlay) {
                            inspectingItemID = nil
                        }
                        onClose()
                        onPaste(inspectingItem)
                    }
                )
                .transition(ClipFlowMotion.overlayTransition)
            }
        }
        .padding(14)
        .frame(width: QuickPastePanelLayout.panelWidth, height: QuickPastePanelLayout.panelHeight, alignment: .topLeading)
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = clips.first?.id
            }
        }
        .onChange(of: query) { _, _ in
            selectedItemID = clips.first?.id
        }
        .clipShape(RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 24, x: 0, y: 18)
    }

    private var inspectingItem: ClipboardItem? {
        guard let inspectingItemID else { return nil }
        return store.item(withID: inspectingItemID)
    }
}

struct HUDRow: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    let item: ClipboardItem
    let store: ClipFlowStore
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.isImage ? item.title : store.displaySnippet(for: item))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(item.isImage ? 1 : 2)

                    Spacer()

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
                        height: 88,
                        cornerRadius: 12,
                        showsDimensionLabel: false,
                        contentMode: .fit,
                        insetPreview: true
                    )
                }

                HStack(spacing: 5) {
                    Text(item.sourceApp)
                    if item.pinned {
                        Text("已置顶")
                    }
                    if item.privacy != .standard {
                        Text(item.privacy.label)
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? tint.opacity(0.18) : palette.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.42) : palette.border, lineWidth: 1)
        )
        .scaleEffect(isSelected ? 0.995 : 1)
        .animation(ClipFlowMotion.selection, value: isSelected)
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

struct HUDCompactButtonStyle: ButtonStyle {
    let fill: Color
    var foreground: Color = Color.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .animation(ClipFlowMotion.press, value: configuration.isPressed)
    }
}

struct HUDInteractiveRow: NSViewRepresentable {
    let item: ClipboardItem
    let store: ClipFlowStore
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onInspect: () -> Void

    func makeNSView(context: Context) -> HUDInteractiveHostingView {
        let view = HUDInteractiveHostingView()
        view.update(
            rootView: AnyView(
                HUDRow(
                    item: item,
                    store: store,
                    isSelected: isSelected
                )
            ),
            onSelect: onSelect,
            onPaste: onPaste,
            onInspect: onInspect
        )
        return view
    }

    func updateNSView(_ nsView: HUDInteractiveHostingView, context: Context) {
        nsView.update(
            rootView: AnyView(
                HUDRow(
                    item: item,
                    store: store,
                    isSelected: isSelected
                )
            ),
            onSelect: onSelect,
            onPaste: onPaste,
            onInspect: onInspect
        )
    }
}

final class HUDInteractiveHostingView: NSView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var onSelect: () -> Void = {}
    private var onPaste: () -> Void = {}
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
        onPaste: @escaping () -> Void,
        onInspect: @escaping () -> Void
    ) {
        hostingView.rootView = rootView
        self.onSelect = onSelect
        self.onPaste = onPaste
        self.onInspect = onInspect
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onPaste()
        } else {
            onSelect()
        }
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

struct HUDInspectorOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    let onClose: () -> Void
    let onPaste: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(304, max(280, proxy.size.width - 24))
            let imageHeight = item.isImage ? min(196, max(156, proxy.size.height * 0.24)) : 0
            let textContentMaxHeight = min(220, max(110, proxy.size.height * 0.34))
            let textValue = store.displayFullText(for: item)
            let textBoxWidth = max(220, cardWidth - 28)
            let estimatedTextHeight = estimatedTextBoxHeight(for: textValue, width: textBoxWidth)
            let shouldScrollText = estimatedTextHeight > textContentMaxHeight

            ZStack {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text("\(item.sourceApp) · \(item.timeLabel)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.secondary)
                        }

                        Spacer()

                        Button("关闭", action: onClose)
                            .buttonStyle(ClipButtonStyle(fill: palette.secondaryButtonFill))
                    }

                    if item.isImage {
                        VStack(alignment: .leading, spacing: 12) {
                            ClipThumbnailView(
                                store: store,
                                item: item,
                                height: imageHeight,
                                cornerRadius: 18,
                                showsDimensionLabel: false,
                                contentMode: .fit,
                                insetPreview: true
                            )

                            FlexiblePillRow(items: item.labels, tint: tint)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            if shouldScrollText {
                                ScrollView(.vertical, showsIndicators: false) {
                                    Text(textValue)
                                        .font(.system(size: item.kind == .code ? 12 : 13, weight: .medium, design: item.kind == .code ? .monospaced : .rounded))
                                        .foregroundStyle(Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(height: textContentMaxHeight)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(palette.inputFill)
                                )
                            } else {
                                Text(textValue)
                                    .font(.system(size: item.kind == .code ? 12 : 13, weight: .medium, design: item.kind == .code ? .monospaced : .rounded))
                                    .foregroundStyle(Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(palette.inputFill)
                                    )
                            }

                            FlexiblePillRow(items: item.labels, tint: tint)
                        }
                    }

                    HStack(spacing: 10) {
                        if item.privacy != .standard {
                            Button(store.isRevealed(item) ? "隐藏内容" : "显示内容") {
                                store.toggleReveal(item.id)
                            }
                            .buttonStyle(ClipButtonStyle(fill: tint.opacity(0.14), foreground: tint))
                        }

                        if let linkURL = item.primaryURL {
                            Button("访问链接") {
                                NSWorkspace.shared.open(linkURL)
                            }
                            .buttonStyle(ClipButtonStyle(fill: ClipCategory.links.tint.opacity(0.14), foreground: ClipCategory.links.tint))
                        }

                        Button("粘贴这项", action: onPaste)
                            .buttonStyle(ClipButtonStyle(fill: Color(red: 0.30, green: 0.59, blue: 0.92), foreground: .white))
                    }
                }
                .padding(14)
                .frame(width: cardWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 16)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    private func estimatedTextBoxHeight(for text: String, width: CGFloat) -> CGFloat {
        let font: NSFont = item.kind == .code
            ? .monospacedSystemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 13, weight: .medium)

        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(160, width - 20), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )

        return ceil(rect.height) + 20
    }
}
