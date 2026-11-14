import AppKit
import Combine
import Carbon
import SwiftUI

private enum QuickPastePanelLayout {
    static let panelWidth: CGFloat = ClipFlowLayout.menuWidth
    static let panelHeight: CGFloat = QuickPasteCardLayout.viewportHeight + 164
    static let cornerRadius: CGFloat = ClipFlowLayout.overlayRadius
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
    /// `.distantPast` so the first poll still sweeps items that expired while the app was closed.
    var lastPurgeAt = Date.distantPast
    /// Tests advance this instead of waiting for wall-clock expiry.
    var now: () -> Date = { Date() }
    private var captureGeneration = 0
    private var captureInFlight = false
    /// PNG decode, encode, and hash. Tests replace this to pause that work.
    var encodeImage: @Sendable (ClipboardImageEncoder.Source) -> EncodedClipboardImage? = { source in
        ClipboardImageEncoder.encode(source)
    }

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
        captureGeneration += 1
        captureInFlight = false
        lastChangeCount = pasteboard.changeCount
    }

    func poll(sourceApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        if captureInFlight { return }

        let changeCount = pasteboard.changeCount
        let changed = changeCount != lastChangeCount
        let current = now()
        if changed || current.timeIntervalSince(lastPurgeAt) >= ClipFlowMotion.clipboardPurgeInterval {
            store.purgeExpired(at: current)
            lastPurgeAt = current
        }

        if store.capturePaused {
            lastChangeCount = changeCount
            return
        }

        guard changed else { return }

        let sourceBundleID = sourceApplication?.bundleIdentifier
        if (sourceBundleID != nil && sourceBundleID == Bundle.main.bundleIdentifier) || store.isExcluded(bundleID: sourceBundleID) {
            lastChangeCount = changeCount
            return
        }

        if SensitivePasteboard.containsMarker(pasteboard) {
            lastChangeCount = changeCount
            return
        }

        guard let choice = ClipboardCapture.choose(from: pasteboard) else {
            guard pasteboard.changeCount == changeCount else { return }
            lastChangeCount = changeCount
            return
        }
        guard pasteboard.changeCount == changeCount else { return }

        let sourceApp = sourceApplication?.localizedName ?? "未知应用"
        switch choice {
        case .text(let text):
            let richContent = ClipboardRepresentations.capture(from: pasteboard)
            guard pasteboard.changeCount == changeCount else { return }
            lastChangeCount = changeCount
            store.ingestCopiedText(
                text,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID,
                richContent: richContent
            )
        case .image(let source):
            startImageCapture(
                source: source,
                changeCount: changeCount,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID
            )
        }
    }

    private func startImageCapture(
        source: ClipboardImageEncoder.Source,
        changeCount: Int,
        sourceApp: String,
        sourceBundleID: String?
    ) {
        captureInFlight = true
        let generation = captureGeneration
        let encode = encodeImage
        Task { @MainActor [weak self] in
            let encoded = await Task.detached(priority: .userInitiated) {
                encode(source)
            }.value
            self?.finishImageCapture(
                encoded,
                generation: generation,
                changeCount: changeCount,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID
            )
        }
    }

    private func finishImageCapture(
        _ encoded: EncodedClipboardImage?,
        generation: Int,
        changeCount: Int,
        sourceApp: String,
        sourceBundleID: String?
    ) {
        guard generation == captureGeneration else { return }
        captureInFlight = false
        guard pasteboard.changeCount == changeCount else {
            poll()
            return
        }

        lastChangeCount = changeCount
        guard let encoded else { return }
        store.ingestCopiedImage(
            encoded.pngData,
            size: encoded.size,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            signature: encoded.signature
        )
    }
}

@MainActor
final class PasteService {
    private let store: ClipFlowStore
    private let pasteboard: NSPasteboard
    private let commitPaste: @MainActor (NSRunningApplication?) -> Void
    weak var monitor: ClipboardMonitor?

    init(
        store: ClipFlowStore,
        pasteboard: NSPasteboard = .general,
        commitPaste: @escaping @MainActor (NSRunningApplication?) -> Void = PasteShortcutSender.commit
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.commitPaste = commitPaste
    }

    func paste(_ item: ClipboardItem, preferredTarget: NSRunningApplication?) {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return
        }
        if item.secretPayloadUnavailable == true {
            store.lastCaptureStatus = SensitivePayloadStore.unreadableStatus
            return
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        pasteboard.clearContents()
        guard restore(item, to: pasteboard) else {
            store.lastCaptureStatus = item.isImage ? "图片资源不可用，请重新复制一次" : "恢复剪贴内容失败"
            return
        }

        // Ask only once the user actually pastes. Without trust, the clipboard copy stands.
        guard store.isAccessibilityTrusted(prompt: true) else {
            store.notePasteBlockedByAccessibility()
            return
        }

        let targetApp = preferredTarget ?? NSWorkspace.shared.frontmostApplication
        commitPaste(targetApp)
        store.lastCaptureStatus = "已粘贴到 \(targetApp?.localizedName ?? "前台应用")"
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return false
        }
        if item.secretPayloadUnavailable == true {
            store.lastCaptureStatus = SensitivePayloadStore.unreadableStatus
            return false
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        pasteboard.clearContents()
        guard restore(item, to: pasteboard) else {
            store.lastCaptureStatus = item.isImage ? "图片资源不可用，请重新复制一次" : "复制到剪贴板失败"
            return false
        }

        store.lastCaptureStatus = "已复制到剪贴板，可在目标输入框中手动粘贴"
        return true
    }

    func restore(_ item: ClipboardItem, to pasteboard: NSPasteboard) -> Bool {
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

        let snapshot = ClipboardRepresentations.Snapshot(
            rtfData: item.rtfData,
            htmlData: item.htmlData,
            fileURLs: item.fileURLs ?? []
        )
        return ClipboardRepresentations.write(plainText: item.fullText, snapshot: snapshot, to: pasteboard)
    }
}

@MainActor
final class QuickPastePanelController: NSObject, NSWindowDelegate {
    private let store: ClipFlowStore
    private let onPaste: (ClipboardItem) -> Void
    private let onOpenLibrary: () -> Void
    private var panel: QuickPastePanel?
    private var inspector: InspectorPresentation?

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
        inspector?.reset()
        let panel = makePanel()
        let inspector = InspectorPresentation(driver: AppKitInspectorAnimationDriver())
        self.inspector = inspector
        panel.onCancelInspector = { [weak inspector] in
            guard let inspector, inspector.blocksBackground else { return false }
            inspector.dismiss(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            return true
        }
        panel.onCancelPanel = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(
            rootView: QuickPastePanelView(
                store: store,
                preferredTargetName: preferredTarget?.localizedName,
                onPaste: onPaste,
                onOpenLibrary: onOpenLibrary,
                onClose: { [weak self] in
                    self?.hide()
                },
                inspector: inspector
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
        inspector?.reset()
        inspector = nil
        guard let panel else { return }
        panel.onCancelInspector = nil
        panel.onCancelPanel = nil
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
    weak var clipboardList: QuickPasteListView?
    private var routedRowPress = false
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            routedRowPress = clipboardList?.routeMouseDown(event) == true
            if routedRowPress { return }
        } else if routedRowPress && (event.type == .leftMouseUp || event.type == .leftMouseDragged) {
            if event.type == .leftMouseUp { routedRowPress = false }
            return
        }
        super.sendEvent(event)
    }
    var onCancelInspector: (() -> Bool)?
    var onCancelPanel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if onCancelInspector?() == true { return }
        if let onCancelPanel { onCancelPanel() }
        else { orderOut(nil) }
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
    // Keep selection independent of the parent view's layout/scroll identity.
    @ViewState private var selection = HistorySelection()
    @ViewState private var listProxy = QuickPasteListProxy()
    @StateObject private var inspector: InspectorPresentation
    private var motionPreferences = InspectorMotionPreferences()
    private var reduceMotion: Bool { motionPreferences.reduceMotion }

    init(store: ClipFlowStore, preferredTargetName: String?, onPaste: @escaping (ClipboardItem) -> Void,
         onOpenLibrary: @escaping () -> Void, onClose: @escaping () -> Void,
         inspector: InspectorPresentation? = nil) {
        self.store = store
        self.preferredTargetName = preferredTargetName
        self.onPaste = onPaste
        self.onOpenLibrary = onOpenLibrary
        self.onClose = onClose
        _inspector = StateObject(wrappedValue: inspector ??
            InspectorPresentation(driver: AppKitInspectorAnimationDriver()))
    }

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
                        if let preferredTargetName, !preferredTargetName.isEmpty {
                            Text("→ \(preferredTargetName)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary).lineLimit(1)
                                .help("粘贴到 \(preferredTargetName)")
                        }
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
                .padding(.horizontal, ClipFlowLayout.space12)
                .frame(height: ClipFlowLayout.controlHeight)
                .background(palette.inputFill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1))

                if clips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "还没有捕获到内容" : "没有匹配的内容")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(query.isEmpty
                            ? "先去其他应用复制文字或图片，然后按下 \(store.quickPasteShortcut.displayName)，就能在指针附近把它调出来。"
                            : "试试其他关键词，或打开历史记录查看全部内容。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: QuickPasteCardLayout.viewportHeight, alignment: .top)
                } else {
                    QuickPasteNativeList(items: clips, store: store, selection: selection, proxy: listProxy,
                        isBlocked: { [weak inspector] in inspector?.blocksBackground != false },
                        onSelect: { item in selection.itemID = item.id },
                        onPaste: { item in
                            selection.itemID = item.id
                            onClose()
                            onPaste(item)
                        },
                        onInspect: { item in
                            selection.itemID = item.id
                            if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
                                inspector.dismiss(reduceMotion: reduceMotion)
                            } else {
                                inspector.open(itemID: item.id, reduceMotion: reduceMotion)
                            }
                        },
                        onInspectFrom: { item, source in
                            selection.itemID = item.id
                            if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
                                inspector.dismiss(reduceMotion: reduceMotion)
                            } else {
                                inspector.open(itemID: item.id, reduceMotion: reduceMotion, source: source)
                            }
                        })
                    .frame(height: QuickPasteCardLayout.viewportHeight)
                }

                HStack(spacing: 8) {
                    QuickPasteKeyHint(keys: "↑↓", title: "选择")
                    QuickPasteKeyHint(keys: "↩", title: "粘贴")
                    QuickPasteKeyHint(keys: "⌘1–9", title: "直接粘贴")
                    QuickPasteKeyHint(keys: "空格", title: "详情")
                    Spacer(minLength: 0)
                    Button {
                        onClose()
                        onOpenLibrary()
                    } label: {
                        Text("历史记录")
                    }
                    .buttonStyle(MenuFooterActionStyle(fill: palette.secondaryButtonFill))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: ClipFlowLayout.controlHeight)
            }
            .padding(ClipFlowLayout.pageInset)
            .allowsHitTesting(!inspector.blocksBackground)
            .disabled(inspector.blocksBackground)
            .accessibilityHidden(inspector.blocksBackground)

            // The full-sized scrim survives every last closing frame.
            if inspector.blocksBackground {
                InspectorScrim(motion: inspector.motion, opacity: 1) {
                    inspector.dismiss(reduceMotion: reduceMotion)
                }
            }

            if let inspectingItem {
                HUDInspectorOverlay(
                    item: inspectingItem, store: store,
                    sourceRectInWindow: inspector.snapshot.sourceRectInWindow,
                    motion: inspector.motion,
                    onClose: { inspector.dismiss(reduceMotion: reduceMotion) },
                    onPaste: {
                        inspector.dismiss(reduceMotion: reduceMotion) {
                            guard let current = store.item(withID: inspectingItem.id) else { return }
                            onClose()
                            onPaste(current)
                        }
                    }
                )
            }
        }
        .frame(width: QuickPastePanelLayout.panelWidth, height: QuickPastePanelLayout.panelHeight, alignment: .topLeading)
        .background(
            InspectorEscapeHandler(onEscape: {
                guard inspector.blocksBackground else { return false }
                inspector.dismiss(reduceMotion: reduceMotion)
                return true
            }, onWindowInactive: { inspector.reset() }).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
        .onChangeBackward(of: store.items) {
            inspector.invalidateIfMissing(availableIDs: Set(store.items.filter { !$0.isExpired() }.map(\.id)))
        }
        .onDisappear { inspector.reset() }
        .onAppear {
            if selection.itemID == nil {
                selection.itemID = clips.first?.id
            }
        }
        .onChangeBackward(of: query) {
            selection.itemID = clips.first?.id
        }
        .background(
            ListKeyCommandMonitor(queryIsEmpty: query.isEmpty, onCommand: { handleKeyCommand($0, clips: clips) })
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
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
        guard let id = inspector.snapshot.itemID else { return nil }
        return store.item(withID: id)
    }

    private func handleKeyCommand(_ command: ListKeyCommand, clips: [ClipboardItem]) -> Bool {
        guard !inspector.blocksBackground, !clips.isEmpty else { return false }
        let selected = clips.first(where: { $0.id == selection.itemID })
        switch command {
        case .moveUp, .moveDown:
            return selection.move(by: command == .moveUp ? -1 : 1, in: clips.map(\.id)) != nil
        case .activate:
            paste(selected ?? clips[0])
        case .pasteIndex(let index):
            guard clips.indices.contains(index) else { return false }
            paste(clips[index])
        case .toggleDetails:
            guard let selected else { return false }
            if listProxy.list?.openDetails(for: selected.id) != true {
                inspector.open(itemID: selected.id, reduceMotion: reduceMotion)
            }
        }
        return true
    }

    private func paste(_ item: ClipboardItem) {
        selection.itemID = item.id
        onClose()
        onPaste(item)
    }
}

struct QuickPasteKeyHint: View {
    let keys: String
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Text(keys)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(title).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys) \(title)")
    }
}

/// Selection repaints a lightweight background, never the hosted row's content.
struct HUDSelectionChrome: View {
    let itemID: UUID
    let selection: HistorySelection
    let tint: Color
    @ViewState private var isSelected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
            .fill(isSelected ? palette.selectedRowFill : palette.rowFill)
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .fill(isSelected ? tint.opacity(0.16) : .clear))
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.65) : palette.rowBorder,
                    lineWidth: isSelected ? 1.5 : 1))
            .animation(reduceMotion ? nil : ClipFlowMotion.rowSelection, value: isSelected)
            .onReceive(selection.$itemID.map { $0 == itemID }.removeDuplicates()) {
                if isSelected != $0 { isSelected = $0 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct HUDRow: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    /// Position among the first nine rows, pasted directly with ⌘1…⌘9.
    var shortcutIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: item.isImage || item.kind == .code ? 6 : 4) {
            HStack(spacing: 5) {
                Image(systemName: iconName).foregroundStyle(item.kind.labelColor(for: colorScheme))
                Text(item.kind.label).foregroundStyle(item.kind.labelColor(for: colorScheme)).fixedSize()
                Text(item.sourceApp).lineLimit(1)
                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.pinned.tint) }
                if item.isSensitive { Image(systemName: "lock.fill").foregroundStyle(item.privacy.color) }
                Spacer(minLength: 4)
                Text(item.timeLabel).lineLimit(1).fixedSize()
                if let shortcutIndex, shortcutIndex < 9 {
                    Text("⌘\(shortcutIndex + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 4).frame(height: 14)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            .frame(height: 14)

            if item.isImage {
                imageContent
            } else if item.kind == .code {
                Text(String(store.displayFullText(for: item).prefix(1000)))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(7)
                    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
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

    }

    @ViewBuilder private var imageContent: some View {
        let shape = LibraryImageShape.resolve(width: item.imageWidth, height: item.imageHeight)
        if shape == .landscape {
            VStack(alignment: .leading, spacing: 4) {
                ClipThumbnailView(store: store, item: item, height: LibraryImageThumbnail.height, cornerRadius: ClipFlowLayout.controlRadius,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                Text(item.imageDimensionText ?? "图片").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ClipThumbnailView(store: store, item: item, height: LibraryImageThumbnail.height, cornerRadius: ClipFlowLayout.controlRadius,
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

    private var iconName: String { item.kind.symbolName }
}

struct HUDInteractiveRow: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let item: ClipboardItem
    let store: ClipFlowStore
    let selection: HistorySelection
    var onInspectFrom: ((InspectorSourceAnchor) -> Void)? = nil
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onInspect: () -> Void

    func makeNSView(context: Context) -> HUDInteractiveHostingView {
        let view = HUDInteractiveHostingView()
        view.interactionEnabled = isEnabled
        view.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        view.update(
            itemID: item.id,
            rootView: AnyView(
                HUDRow(
                    item: item,
                    store: store
                )
            ),
            selectionView: AnyView(HUDSelectionChrome(itemID: item.id, selection: selection,
                tint: item.kind.tint)),
            onSelect: onSelect,
            onPaste: onPaste,
            onInspect: InspectorSourceAnchor.callback(for: view, fallback: onInspect, anchored: onInspectFrom)
        )
        return view
    }

    func updateNSView(_ nsView: HUDInteractiveHostingView, context: Context) {
        nsView.interactionEnabled = isEnabled
        nsView.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        nsView.update(
            itemID: item.id,
            rootView: AnyView(
                HUDRow(
                    item: item,
                    store: store
                )
            ),
            selectionView: AnyView(HUDSelectionChrome(itemID: item.id, selection: selection,
                tint: item.kind.tint)),
            onSelect: onSelect,
            onPaste: onPaste,
            onInspect: InspectorSourceAnchor.callback(for: nsView, fallback: onInspect, anchored: onInspectFrom)
        )
    }
}

final class HUDInteractiveHostingView: ClipboardRowHitView {
    private(set) var contentRevision = 0
    var representedItemID: UUID? { itemID }
    private let selectionHostingView = NSHostingView(rootView: AnyView(EmptyView()))
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
        itemID: UUID? = nil,
        rootView: AnyView,
        selectionView: AnyView? = nil,
        onSelect: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onInspect: @escaping () -> Void,
        menuProvider: (() -> [ClipboardRowMenuEntry])? = nil
    ) {
        if self.itemID != itemID {
            resetClickSequence()
            self.itemID = itemID
        }
        contentRevision += 1
        hostingView.rootView = rootView
        if let selectionView { selectionHostingView.rootView = selectionView }
        self.onSelect = onSelect
        self.onPaste = onPaste
        self.onInspect = onInspect
        self.menuProvider = menuProvider ?? { [] }
    }

    /// Opens the detail drawer from this row (middle click, menu, keyboard).
    override func openDetails() {
        guard interactionEnabled else { return }
        resetClickSequence()
        onInspect()
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

    override func rowInteractionWasDisabled() { resetClickSequence() }

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
        guard interactionEnabled else { return }
        resetClickSequence()
        guard let menu = contextMenu() else { return }
        onSelect()
        Self.presentContextMenu(menu, event, self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        if event.buttonNumber == 2 {
            openDetails()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionEnabled else { return nil }
        resetClickSequence()
        return contextMenu()
    }
}

struct HUDInspectorOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    var sourceRectInWindow: CGRect? = nil
    var motion: InspectorMotionProgress? = nil
    let onClose: () -> Void
    let onPaste: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = max(280, proxy.size.width - 12)
            ZStack {
                LibraryInspectorOverlay(item: item, store: store,
                    palette: .resolve(for: colorScheme), maxHeight: max(280, proxy.size.height - 12),
                    contentWidth: cardWidth, onPasteAction: onPaste, sourceRectInWindow: sourceRectInWindow, motion: motion, onClose: onClose)
                    .frame(width: cardWidth)
                    .padding(6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
