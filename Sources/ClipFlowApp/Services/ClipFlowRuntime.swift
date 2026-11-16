import AppKit

@MainActor
final class ClipFlowRuntime: NSObject {
    static let shared = ClipFlowRuntime()

    let store = ClipFlowStore.shared

    private let clipboardMonitor: ClipboardMonitor
    private let pasteService: PasteService
    private lazy var hudController = QuickPastePanelController(
        store: store,
        onPaste: { [weak self] item in self?.paste(item) },
        onPastePlain: { [weak self] item in self?.pastePlainText(item) },
        onOpenLibrary: { [weak self] in self?.openLibrary() }
    )
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

    func pastePlainText(_ item: ClipboardItem) {
        hudController.hide()
        pasteService.paste(item, preferredTarget: lastExternalApp, plainText: true)
    }

    func pasteSnippet(_ snippet: SavedSnippet) {
        hudController.hide()
        pasteService.pastePlainText(snippet.body, preferredTarget: lastExternalApp, announcingPlain: false)
    }

    func pasteSnippetPlain(_ snippet: SavedSnippet) {
        hudController.hide()
        pasteService.pastePlainText(snippet.body, preferredTarget: lastExternalApp, announcingPlain: true)
    }

    @discardableResult
    func copySnippet(_ snippet: SavedSnippet) -> Bool {
        pasteService.copyPlainText(snippet.body)
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
        pasteService.copyToClipboard(item)
    }

    @discardableResult
    func copyPlainText(_ item: ClipboardItem) -> Bool {
        pasteService.copyToClipboard(item, plainText: true)
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
