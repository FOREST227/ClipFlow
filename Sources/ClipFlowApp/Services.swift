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
    static let panelHeight: CGFloat = QuickPasteCardLayout.viewportHeight + 164
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

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
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

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return false
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard restore(item, to: pasteboard) else {
            store.lastCaptureStatus = item.isImage ? "图片资源不可用，请重新复制一次" : "复制到剪贴板失败"
            return false
        }

        store.lastCaptureStatus = "已复制到剪贴板，可在目标输入框中手动粘贴"
        return true
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
        // Activate like the history window so SwiftUI receives full trackpad gestures.
        // Runtime retains lastExternalApp separately for the eventual paste.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
                    HStack(spacing: 8) {
                        ClipFlowBrandMark(icon: "cursorarrow.rays", size: 28)
                        Text("快速粘贴")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }

                    Spacer()

                    Button("关闭", action: onClose)
                        .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
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
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
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
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: QuickPasteCardLayout.viewportHeight, alignment: .top)
                } else {
                    SoftEdgeScrollView(showsEdgeEffects: false) {
                        LazyVStack(spacing: QuickPasteCardLayout.spacing) {
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
                                .frame(maxWidth: .infinity)
                                .frame(height: QuickPasteCardLayout.height(for: item.kind))
                            }
                        }
                    }
                    .frame(height: QuickPasteCardLayout.viewportHeight)
                }

                HStack(spacing: 8) {
                    Button {
                        onClose()
                        onOpenLibrary()
                    } label: {
                        Text("历史记录").frame(width: 60)
                    }
                    .buttonStyle(MenuFooterActionStyle(fill: ClipCategory.all.tint.opacity(0.13),
                        height: ClipFlowLayout.controlHeight, fontSize: 12,
                        cornerRadius: ClipFlowLayout.controlRadius))

                    Button {
                        if let selected = clips.first(where: { $0.id == selectedItemID }) ?? clips.first {
                            selectedItemID = selected.id
                            onClose()
                            onPaste(selected)
                        }
                    } label: {
                        Text("粘贴选中项").frame(width: 60)
                    }
                    .buttonStyle(ClipFlowActionButtonStyle(fill: palette.primaryButtonFill, foreground: .white))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(ClipFlowLayout.pageInset)
            .blur(radius: inspectingItem == nil ? 0 : ClipFlowMotion.backgroundDefocusRadius)
            .animation(.easeOut(duration: 0.16), value: inspectingItem != nil)
            .allowsHitTesting(inspectingItem == nil)

            // Keep the scrim mounted and full-sized; it must not scale with the card
            // or inherit the content padding when the inspector opens/closes.
            Color.black.opacity(inspectingItem == nil ? 0 : 0.16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { inspectingItemID = nil }
                .allowsHitTesting(inspectingItem != nil)
                .animation(.easeOut(duration: 0.16), value: inspectingItem != nil)

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
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: inspectingItem != nil)
        .frame(width: QuickPastePanelLayout.panelWidth, height: QuickPastePanelLayout.panelHeight, alignment: .topLeading)
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = clips.first?.id
            }
        }
        .onChangeBackward(of: query) {
            selectedItemID = clips.first?.id
        }
        .background {
            GeometryReader { proxy in
                FloatingPanelBackground(palette: palette)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuickPastePanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    private var inspectingItem: ClipboardItem? {
        guard let inspectingItemID else { return nil }
        return store.item(withID: inspectingItemID)
    }
}

struct HUDRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    let item: ClipboardItem
    let store: ClipFlowStore
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: item.isImage || item.kind == .code ? 6 : 4) {
            HStack(spacing: 5) {
                Image(systemName: iconName).foregroundStyle(tint)
                Text(item.kind.label).foregroundStyle(tint).fixedSize()
                Text(item.sourceApp).lineLimit(1)
                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.quickPaste.tint) }
                if item.isSensitive { Image(systemName: "lock.fill").foregroundStyle(item.privacy.color) }
                Spacer(minLength: 4)
                Text(item.timeLabel).lineLimit(1).fixedSize()
            }
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            .frame(height: 14)

            if item.isImage {
                imageContent
            } else if item.kind == .code {
                Text(String(store.displayFullText(for: item).prefix(1000)))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(7)
                    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(store.displaySnippet(for: item))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: QuickPasteCardLayout.height(for: item.kind), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.16) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.65) : palette.rowBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        .animation(reduceMotion ? nil : ClipFlowMotion.rowSelection, value: isSelected)
    }

    @ViewBuilder private var imageContent: some View {
        let shape = LibraryImageShape.resolve(width: item.imageWidth, height: item.imageHeight)
        if shape == .landscape {
            VStack(alignment: .leading, spacing: 4) {
                ClipThumbnailView(store: store, item: item, height: 76, cornerRadius: 8,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                Text(item.imageDimensionText ?? "图片").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ClipThumbnailView(store: store, item: item, height: 96, cornerRadius: 8,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    .frame(width: shape == .portrait ? 66 : 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(shape == .portrait ? "竖向图片" : "方形图片")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tint: Color {
        item.kind.tint
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
            itemID: item.id,
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
            itemID: item.id,
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

final class HUDInteractiveHostingView: ClipboardRowHitView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private static weak var lastClickedRow: HUDInteractiveHostingView?
    private var previousClick: NSEvent?
    private var itemID: UUID?
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
        itemID: UUID? = nil,
        rootView: AnyView,
        onSelect: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onInspect: @escaping () -> Void
    ) {
        if self.itemID != itemID {
            resetClickSequence()
            self.itemID = itemID
        }
        hostingView.rootView = rootView
        self.onSelect = onSelect
        self.onPaste = onPaste
        self.onInspect = onInspect
    }

    override func mouseDown(with event: NSEvent) {
        if redirectLeftClickIfNeeded(event) {
            resetClickSequence()
            return
        }
        // AppKit's click count belongs to the event sequence, not this item.
        // Require a preceding click on this same row before allowing paste.
        let isDoubleClick = Self.lastClickedRow === self && previousClick.map {
            event.clickCount > 1 && event.clickCount == $0.clickCount + 1
                && event.timestamp >= $0.timestamp
                && event.timestamp - $0.timestamp <= NSEvent.doubleClickInterval
                && event.windowNumber == $0.windowNumber
                && hypot(event.locationInWindow.x - $0.locationInWindow.x,
                         event.locationInWindow.y - $0.locationInWindow.y) <= 4
        } == true
        if isDoubleClick {
            resetClickSequence()
            onPaste()
        } else {
            Self.lastClickedRow = self
            previousClick = event
            onSelect()
        }
    }

    private func resetClickSequence() {
        previousClick = nil
        if Self.lastClickedRow === self { Self.lastClickedRow = nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetClickSequence()
    }

    override func scrollWheel(with event: NSEvent) {
        resetClickSequence()
        super.scrollWheel(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        resetClickSequence()
        onInspect()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            resetClickSequence()
            onInspect()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        resetClickSequence()
        onInspect()
        return nil
    }
}

struct HUDInspectorOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    let onClose: () -> Void
    let onPaste: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(304, max(280, proxy.size.width - 24))
            ZStack {
                LibraryInspectorOverlay(item: item, store: store,
                    palette: .resolve(for: colorScheme), maxHeight: max(280, proxy.size.height - 24),
                    contentWidth: cardWidth, onPasteAction: onPaste, onClose: onClose)
                    .frame(width: cardWidth)
                    .padding(12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
