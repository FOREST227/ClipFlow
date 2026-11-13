import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class ClipFlowStore: ObservableObject {
    static let shared = ClipFlowStore()

    @Published var searchText = "" {
        didSet { ensureSelectionStillValid() }
    }
    @Published var selectedCategory: ClipCategory = .all {
        didSet { ensureSelectionStillValid() }
    }
    let historySelection = HistorySelection()
    var selectedItemID: ClipboardItem.ID? {
        get { historySelection.itemID }
        set {
            guard historySelection.itemID != newValue else { return }
            historySelection.itemID = newValue
        }
    }
    @Published var capturePaused: Bool {
        didSet { defaults.set(capturePaused, forKey: Keys.capturePaused) }
    }
    @Published var appearanceMode: ClipFlowAppearance {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }
    @Published var autoProtectSecrets: Bool {
        didSet { defaults.set(autoProtectSecrets, forKey: Keys.autoProtectSecrets) }
    }
    @Published var sensitiveAutoExpireEnabled: Bool {
        didSet {
            defaults.set(sensitiveAutoExpireEnabled, forKey: Keys.sensitiveAutoExpireEnabled)
            items = items.map { $0.applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled) }
            purgeExpired()
        }
    }
    @Published var launchAtLogin: Bool
    @Published var iCloudSyncEnabled: Bool
    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }
    @Published var revealedItemIDs: Set<UUID> = []
    @Published var lastCaptureStatus: String = "准备就绪"
    @Published var iCloudSyncPhase: ClipFlowCloudSyncPhase = .disabled
    @Published var iCloudLastSyncedAt: Date?
    @Published var startupPermissionReport: ClipFlowPermissionReport?
    /// Nil until the silent launch check. False means auto-paste must copy instead.
    @Published private(set) var accessibilityTrusted: Bool?
    @Published private(set) var quickPasteShortcut: ClipFlowShortcut
    @Published var shortcutError: String?
    @Published private(set) var isRecordingShortcut = false
    var registerShortcut: ((ClipFlowShortcut) -> String?)?
    var suspendShortcut: (() -> Void)?
    @Published var historyLoadError: String?

    @Published private(set) var items: [ClipboardItem] = [] {
        didSet {
            itemsRevision += 1
            schedulePersistItems()
            ensureSelectionStillValid()
            if iCloudSyncEnabled && !isApplyingCloudSnapshot {
                scheduleICloudSync()
            }
        }
    }

    let integrations = ClipFlowCatalog.integrations
    let maxItems = 80

    let defaults: UserDefaults
    let fileManager = FileManager.default
    let persistenceQueue = DispatchQueue(label: "ClipFlow.persistence", qos: .utility)
    let imagePreviewCache = NSCache<NSString, NSImage>()
    let historyURL: URL
    let historyWriter: HistoryFileWriter
    let payloadRepository: SensitivePayloadRepository
    let payloadDigests = SensitivePayloadDigest()
    let imagesDirectoryURL: URL
    let cloudSyncCoordinator: ClipFlowCloudSyncCoordinator
    var pendingPersistWorkItem: DispatchWorkItem?
    var localSyncTombstones: [UUID: Date] = [:] {
        didSet { persistLocalSyncTombstones() }
    }
    var cloudSyncLoopTask: Task<Void, Never>?
    var pendingCloudSyncTask: Task<Void, Never>?
    let cloudSyncWorker = ClipFlowCloudSyncWorker()
    var activeCloudSyncTask: Task<Void, Never>?
    var cloudSyncGeneration = 0
    var syncRequestedWhileRunning = false
    private var isApplyingCloudSnapshot = false
    var itemsRevision = 0
    private let accessibility: any AccessibilityTrustChecking

    init(
        storageDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        syncDirectory: URL? = nil,
        payloadRepository: SensitivePayloadRepository = SensitivePayloadKeychain(),
        accessibility: any AccessibilityTrustChecking = AccessibilityTrust.system
    ) {
        self.defaults = defaults
        self.payloadRepository = payloadRepository
        self.accessibility = accessibility
        appearanceMode = ClipFlowAppearance.load(from: defaults)
        quickPasteShortcut = ClipFlowShortcut.load(from: defaults)
        let appSupport = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipFlow", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        historyURL = appSupport.appendingPathComponent("history.json")
        historyWriter = HistoryFileWriter(url: historyURL)
        imagesDirectoryURL = appSupport.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
        imagePreviewCache.countLimit = maxItems + 20
        imagePreviewCache.totalCostLimit = 64 * 1024 * 1024
        cloudSyncCoordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: imagesDirectoryURL, documentsDirectoryURL: syncDirectory)

        capturePaused = defaults.object(forKey: Keys.capturePaused) as? Bool ?? false
        autoProtectSecrets = defaults.object(forKey: Keys.autoProtectSecrets) as? Bool ?? true
        sensitiveAutoExpireEnabled = defaults.object(forKey: Keys.sensitiveAutoExpireEnabled) as? Bool ?? true
        launchAtLogin = Self.currentLaunchAtLoginState()
        iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSyncEnabled) as? Bool ?? false
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? PasswordManagerApps.bundleIDs
        iCloudLastSyncedAt = defaults.object(forKey: Keys.iCloudLastSyncedAt) as? Date
        localSyncTombstones = Self.decodeTombstones(from: defaults.data(forKey: Keys.iCloudSyncTombstones))
        items = loadItems()
        cleanupOrphanedImageFiles()
        selectedItemID = items.first?.id
    }

    func start() {
        schedulePersistItems()
        runStartupPermissionCheck()
        if iCloudSyncEnabled {
            Task { [weak self] in
                self?.enableICloudSyncIfPossible(announceResult: false)
            }
        }
    }

    @discardableResult
    func setQuickPasteShortcut(_ shortcut: ClipFlowShortcut) -> Bool {
        if let error = shortcut.validationError {
            shortcutError = error
            return false
        }
        guard let registerShortcut else {
            shortcutError = "快捷键服务尚未就绪，请重启应用后重试。"
            return false
        }
        if let error = registerShortcut(shortcut) {
            shortcutError = error
            return false
        }
        quickPasteShortcut = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: ClipFlowShortcut.defaultsKey)
        shortcutError = nil
        lastCaptureStatus = "快捷键已设为 \(shortcut.displayName)"
        return true
    }

    func beginShortcutRecording() -> Bool {
        guard !isRecordingShortcut else { return false }
        guard registerShortcut != nil, suspendShortcut != nil else {
            shortcutError = "快捷键服务尚未就绪，请重启应用后重试。"
            return false
        }
        suspendShortcut?()
        isRecordingShortcut = true
        shortcutError = nil
        return true
    }

    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        if let error = registerShortcut?(quickPasteShortcut) {
            shortcutError = "快捷键未能恢复：\(error)"
        }
    }

    func togglePin(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].pinned.toggle()
        items[index].pinnedAt = Date()
        lastCaptureStatus = items[index].pinned ? "已置顶到快速粘贴" : "已取消快速置顶"
    }

    func delete(_ itemID: UUID) {
        if let item = items.first(where: { $0.id == itemID }) {
            rememberCloudDeletion(for: [item])
            removeStoredAssetIfNeeded(for: item)
        }
        items.removeAll { $0.id == itemID }
        revealedItemIDs.remove(itemID)
        lastCaptureStatus = "已删除该条内容"
    }

    func clearHistory() {
        let pinned = items.filter(\.pinned)
        rememberCloudDeletion(for: items.filter { !$0.pinned })
        items.filter { !$0.pinned }.forEach(removeStoredAssetIfNeeded)
        items = pinned
        revealedItemIDs.removeAll()
        lastCaptureStatus = pinned.isEmpty ? "历史记录已清空" : "历史记录已清空，已保留置顶内容"
    }

    func ingestCopiedText(
        _ text: String,
        sourceApp: String,
        sourceBundleID: String?,
        richContent: ClipboardRepresentations.Snapshot = .empty
    ) {
        guard !text.isEmpty else { return }
        guard text.count <= 20_000 else {
            lastCaptureStatus = "已跳过过大的剪贴内容"
            return
        }

        purgeExpired()

        let recentSourceBundleIDs = OTPDetector.recentSourceBundleIDs(in: items)
        let existingIndex = items.firstIndex { !$0.isImage && $0.fullText == text }
        let existing = existingIndex.map { items.remove(at: $0) }
        let item = ClipboardClassifier.makeItem(
            text: text,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            autoProtectSecrets: autoProtectSecrets,
            existingItem: existing,
            recentSourceBundleIDs: recentSourceBundleIDs,
            richContent: richContent
        ).applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled)

        items.insert(item, at: 0)
        trimItemsToLimit()

        selectedItemID = selectedItemID ?? item.id
        lastCaptureStatus = "已从 \(sourceApp) 捕获新内容"
    }

    func ingestCopiedImage(
        _ imageData: Data,
        size: CGSize,
        sourceApp: String,
        sourceBundleID: String?,
        signature precomputedSignature: String? = nil
    ) {
        guard !imageData.isEmpty else { return }
        guard imageData.count <= 25_000_000 else {
            lastCaptureStatus = "已跳过过大的图片"
            return
        }

        purgeExpired()

        let signature = precomputedSignature ?? ClipboardImageEncoder.signature(for: imageData)
        let existingIndex = items.firstIndex { $0.imageSignature == signature }
        let existing = existingIndex.map { items.remove(at: $0) }
        let itemID = existing?.id ?? UUID()
        let imageFilename = "\(itemID.uuidString).png"
        let imageURL = imagesDirectoryURL.appendingPathComponent(imageFilename)

        do {
            try imageData.write(to: imageURL, options: [.atomic])
        } catch {
            if let existing {
                items.insert(existing, at: 0)
            }
            lastCaptureStatus = "保存图片失败"
            return
        }

        imagePreviewCache.removeObject(forKey: imageFilename as NSString)

        if let existing, existing.imageFilename != imageFilename {
            removeStoredAssetIfNeeded(for: existing)
        }

        let item = ClipboardClassifier.makeImageItem(
            imageFilename: imageFilename,
            imageSignature: signature,
            imageSize: size,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            existingItem: existing
        ).applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled)

        items.insert(item, at: 0)
        trimItemsToLimit()

        selectedItemID = selectedItemID ?? item.id
        lastCaptureStatus = "已从 \(sourceApp) 捕获图片"
    }

    /// Saved exclusions plus every password-manager id, so an older saved list still skips those apps.
    var effectiveExcludedBundleIDs: Set<String> {
        Set(excludedBundleIDs).union(PasswordManagerApps.bundleIDs)
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return effectiveExcludedBundleIDs.contains(bundleID)
    }

    func updateExcludedApps(from rawValue: String) {
        let cleaned = rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        excludedBundleIDs = cleaned.isEmpty ? PasswordManagerApps.bundleIDs : cleaned
    }

    func resetExcludedAppsToDefaults() {
        excludedBundleIDs = PasswordManagerApps.bundleIDs
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13, *) else {
            launchAtLogin = false
            lastCaptureStatus = "macOS 12 请在系统偏好设置的用户与群组中添加登录项"
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            launchAtLogin = enabled
            defaults.set(enabled, forKey: Keys.launchAtLogin)
            lastCaptureStatus = enabled ? "已开启开机自动启动" : "已关闭开机自动启动"
        } catch {
            launchAtLogin = Self.currentLaunchAtLoginState()
            lastCaptureStatus = "开机自动启动设置失败，请将 ClipFlow 放在应用程序目录后再试"
        }
    }

    func dismissStartupPermissionReport() {
        startupPermissionReport = nil
    }

    func rerunPermissionCheck() {
        refreshPermissionReport(showEvenIfHealthy: true)
    }

    /// `prompt` is true only for an explicit request or an auto-paste attempt.
    @discardableResult
    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let trusted = accessibility.isTrusted(prompt: prompt)
        accessibilityTrusted = trusted
        return trusted
    }

    func requestAccessibilityPermissionPrompt() {
        _ = isAccessibilityTrusted(prompt: true)
        refreshPermissionReport(showEvenIfHealthy: true)
    }

    /// Auto-paste could not run. The content is already back on the clipboard.
    func notePasteBlockedByAccessibility() {
        accessibilityTrusted = false
        lastCaptureStatus = "已复制回剪贴板。请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 ClipFlow，或在目标输入框手动粘贴。"
        startupPermissionReport = ClipFlowPermissionReport(
            title: "自动粘贴需要辅助功能",
            message: "这次没有自动粘贴。内容已放回剪贴板，可在目标输入框按 ⌘V 手动粘贴。允许 ClipFlow 使用辅助功能后，再次选择条目即可自动粘贴。",
            items: [
                ClipFlowPermissionItem(
                    title: "辅助功能",
                    detail: "打开“系统设置 → 隐私与安全性 → 辅助功能”，打开 ClipFlow 的开关。启动时只做静默检查；系统授权提示会在你使用自动粘贴时出现。",
                    icon: "figure.wave.circle",
                    status: .needsAttention
                )
            ]
        )
    }

    func purgeExpired(at now: Date = Date()) {
        let expiredItems = items.filter { $0.isExpired(at: now) }
        guard !expiredItems.isEmpty else { return }
        let expiredIDs = Set(expiredItems.map(\.id))
        expiredItems.forEach(removeStoredAssetIfNeeded)
        items.removeAll { expiredIDs.contains($0.id) }
        revealedItemIDs.subtract(expiredIDs)
        lastCaptureStatus = "已清理过期的敏感内容"
    }

    private func trimItemsToLimit() {
        guard items.count > maxItems else { return }
        let ordered = sortItems(items)
        let retained = ordered.filter(\.pinned) + ordered.filter { !$0.pinned }
            .prefix(max(0, maxItems - ordered.filter(\.pinned).count))
        let retainedIDs = Set(retained.map(\.id))
        let overflow = items.filter { !retainedIDs.contains($0.id) }
        rememberCloudDeletion(for: overflow)
        overflow.forEach(removeStoredAssetIfNeeded)
        items = retained
    }

    func applyCloudItems(_ cloudItems: [ClipboardItem]) {
        let preservedLocalItems = items.filter { !isEligibleForICloudSync($0) }
        var combinedByID = Dictionary(uniqueKeysWithValues: preservedLocalItems.map { ($0.id, $0) })

        for item in cloudItems where combinedByID[item.id] == nil {
            combinedByID[item.id] = item
        }

        let combinedItems = sortItems(Array(combinedByID.values))
        guard combinedItems != items else { return }

        isApplyingCloudSnapshot = true
        items = combinedItems
        isApplyingCloudSnapshot = false
        cleanupOrphanedImageFiles()
    }

    func sortItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted(by: ClipboardItemOrder.isBefore)
    }

    enum Keys {
        static let appearanceMode = "appearanceMode"
        static let capturePaused = "capturePaused"
        static let autoProtectSecrets = "autoProtectSecrets"
        static let sensitiveAutoExpireEnabled = "sensitiveAutoExpireEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let iCloudLastSyncedAt = "iCloudLastSyncedAt"
        static let iCloudSyncTombstones = "iCloudSyncTombstones"
        static let excludedBundleIDs = "excludedBundleIDs"
    }

    private static func currentLaunchAtLoginState() -> Bool {
        guard #available(macOS 13, *) else { return false }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    private static func decodeTombstones(from data: Data?) -> [UUID: Date] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([UUID: Date].self, from: data)) ?? [:]
    }

}
