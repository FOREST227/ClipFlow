import Foundation

enum ClipFlowCloudSyncPhase: Equatable {
    case disabled
    case pending
    case syncing
    case active
    case unavailable
    case failed(String)

    var statusLabel: String {
        switch self {
        case .disabled, .pending: "未同步"
        case .syncing: "同步中"
        case .active: "已同步"
        case .unavailable, .failed: "同步失败"
        }
    }
}

struct ClipFlowCloudSyncState: Codable {
    var schemaVersion: Int
    var updatedAt: Date
    var items: [ClipboardItem]
    var tombstones: [UUID: Date]

    init(
        schemaVersion: Int = 1,
        updatedAt: Date = Date(),
        items: [ClipboardItem] = [],
        tombstones: [UUID: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.items = items
        self.tombstones = tombstones
    }
}

struct ClipFlowCloudSyncResult: Sendable {
    let cloudItems: [ClipboardItem]
    let localItems: [ClipboardItem]
    let tombstones: [UUID: Date]
}

enum ClipFlowCloudSyncError: LocalizedError {
    case unavailable
    case invalidState
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前无法访问“文稿/ClipFlow”，请确认已允许 ClipFlow 读写“文稿”文件夹。"
        case .invalidState:
            return "“文稿/ClipFlow”中的历史数据不可读取。"
        case .writeFailed:
            return "写入“文稿/ClipFlow”失败。"
        }
    }
}

struct ClipFlowCloudSyncCoordinator: Sendable {
    private var fileManager: FileManager { .default }
    private let localImagesDirectoryURL: URL
    private let documentsFolderName: String
    private let documentsDirectoryURL: URL?

    init(localImagesDirectoryURL: URL, documentsFolderName: String = "ClipFlow", documentsDirectoryURL: URL? = nil) {
        self.localImagesDirectoryURL = localImagesDirectoryURL
        self.documentsFolderName = documentsFolderName
        self.documentsDirectoryURL = documentsDirectoryURL
    }

    func synchronize(
        localItems: [ClipboardItem],
        tombstones: [UUID: Date],
        maxItems: Int
    ) throws -> ClipFlowCloudSyncResult {
        let locations = try resolveLocations()
        let remoteState = try loadRemoteState(from: locations.historyURL)
        let mergedTombstones = pruneTombstones(mergeTombstones(remoteState.tombstones, with: tombstones))
        let localSyncedItems = localItems.filter(isEligibleForCloudSync(_:))

        var mergedByID: [UUID: ClipboardItem] = [:]
        remoteState.items.filter(isEligibleForCloudSync(_:)).forEach { mergedByID[$0.id] = $0 }

        for item in localSyncedItems {
            guard shouldKeep(item, tombstones: mergedTombstones) else { continue }

            if let existing = mergedByID[item.id] {
                if item.createdAt >= existing.createdAt {
                    mergedByID[item.id] = item
                }
            } else {
                mergedByID[item.id] = item
            }
        }

        var mergedItems = Array(mergedByID.values)
            .filter { shouldKeep($0, tombstones: mergedTombstones) }
            .sorted(by: sortItems(lhs:rhs:))

        if mergedItems.count > maxItems {
            let pinned = mergedItems.filter(\.pinned)
            mergedItems = pinned + mergedItems.filter { !$0.pinned }.prefix(max(0, maxItems - pinned.count))
        }

        for item in mergedItems where item.isImage {
            try prepareCloudAssetIfNeeded(for: item, cloudImagesDirectoryURL: locations.imagesURL)
        }

        let localReadyItems = mergedItems.filter {
            ensureLocalAssetIfNeeded(for: $0, cloudImagesDirectoryURL: locations.imagesURL)
        }

        if remoteState.items != mergedItems || remoteState.tombstones != mergedTombstones {
            let stateToWrite = ClipFlowCloudSyncState(
                updatedAt: Date(),
                items: mergedItems,
                tombstones: mergedTombstones
            )
            try persistRemoteStateIfNeeded(stateToWrite, to: locations.historyURL)
        }
        // iCloud may deliver an image before the history that references it.
        // A single device's snapshot cannot prove a remote asset is orphaned.
        // Only local assets are garbage-collected until coordinated remote GC exists.

        return ClipFlowCloudSyncResult(
            cloudItems: mergedItems,
            localItems: localReadyItems,
            tombstones: mergedTombstones
        )
    }

    func resolveAvailabilityDescription() -> String? {
        do {
            _ = try resolveLocations()
            return nil
        } catch {
            return "无法访问“文稿”目录，请在系统设置的“隐私与安全性”里允许 ClipFlow 读写文稿文件夹。"
        }
    }

    private func resolveLocations() throws -> ClipFlowCloudSyncLocations {
        guard let documentsURL = documentsDirectoryURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ClipFlowCloudSyncError.unavailable
        }

        let rootURL = documentsURL.appendingPathComponent(documentsFolderName, isDirectory: true)
        let imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
        let historyURL = rootURL.appendingPathComponent("history.json")

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        } catch {
            throw ClipFlowCloudSyncError.unavailable
        }
        return ClipFlowCloudSyncLocations(historyURL: historyURL, imagesURL: imagesURL)
    }

    private func loadRemoteState(from historyURL: URL) throws -> ClipFlowCloudSyncState {
        try prepareUbiquitousItem(at: historyURL)

        guard fileManager.fileExists(atPath: historyURL.path) else {
            return ClipFlowCloudSyncState()
        }

        do {
            let data = try Data(contentsOf: historyURL)
            return try JSONDecoder().decode(ClipFlowCloudSyncState.self, from: data)
        } catch {
            throw ClipFlowCloudSyncError.invalidState
        }
    }

    private func persistRemoteStateIfNeeded(_ state: ClipFlowCloudSyncState, to historyURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let existingData = try? Data(contentsOf: historyURL)

        if existingData == data {
            return
        }

        do {
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            throw ClipFlowCloudSyncError.writeFailed
        }
    }

    private func shouldKeep(_ item: ClipboardItem, tombstones: [UUID: Date]) -> Bool {
        guard let tombstone = tombstones[item.id] else { return true }
        return item.createdAt > tombstone
    }

    private func mergeTombstones(_ remote: [UUID: Date], with local: [UUID: Date]) -> [UUID: Date] {
        var merged = remote
        for (id, date) in local {
            if let existing = merged[id] {
                if date > existing {
                    merged[id] = date
                }
            } else {
                merged[id] = date
            }
        }
        return merged
    }

    private func pruneTombstones(_ tombstones: [UUID: Date]) -> [UUID: Date] {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        return tombstones.filter { $0.value >= cutoff }
    }

    private func sortItems(lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        if lhs.pinned != rhs.pinned {
            return lhs.pinned && !rhs.pinned
        }
        return lhs.createdAt > rhs.createdAt
    }

    private func isEligibleForCloudSync(_ item: ClipboardItem) -> Bool {
        !item.isSensitive
    }

    private func prepareCloudAssetIfNeeded(for item: ClipboardItem, cloudImagesDirectoryURL: URL) throws {
        guard let filename = item.imageFilename else { return }

        let localURL = localImagesDirectoryURL.appendingPathComponent(filename)
        let cloudURL = cloudImagesDirectoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: localURL.path) else { return }

        if fileManager.fileExists(atPath: cloudURL.path),
           let localData = try? Data(contentsOf: localURL),
           let cloudData = try? Data(contentsOf: cloudURL),
           localData == cloudData {
            return
        }

        if fileManager.fileExists(atPath: cloudURL.path) {
            try? fileManager.removeItem(at: cloudURL)
        }

        try fileManager.copyItem(at: localURL, to: cloudURL)
    }

    private func ensureLocalAssetIfNeeded(for item: ClipboardItem, cloudImagesDirectoryURL: URL) -> Bool {
        guard let filename = item.imageFilename else { return true }

        let localURL = localImagesDirectoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: localURL.path) {
            return true
        }

        let cloudURL = cloudImagesDirectoryURL.appendingPathComponent(filename)
        try? prepareUbiquitousItem(at: cloudURL)

        guard fileManager.fileExists(atPath: cloudURL.path) else {
            return false
        }

        do {
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: cloudURL, to: localURL)
            return true
        } catch {
            return false
        }
    }

    private func prepareUbiquitousItem(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }

        if fileManager.isUbiquitousItem(at: url) {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
    }
}

// File and image work runs off the main actor, serialized across sync requests.
actor ClipFlowCloudSyncWorker {
    func synchronize(
        using coordinator: ClipFlowCloudSyncCoordinator,
        localItems: [ClipboardItem],
        tombstones: [UUID: Date],
        maxItems: Int
    ) throws -> ClipFlowCloudSyncResult {
        try coordinator.synchronize(localItems: localItems, tombstones: tombstones, maxItems: maxItems)
    }
}

private struct ClipFlowCloudSyncLocations {
    let historyURL: URL
    let imagesURL: URL
}
