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
        try prepareUbiquitousItem(at: locations.historyURL)

        let merged = try ClipFlowCloudSyncFile.coordinate(historyAt: locations.historyURL) { readURL, writeURL in
            let remoteState = try ClipFlowCloudSyncFile.readState(at: readURL)
            let merged = ClipFlowHistoryMerge.merge(
                localItems: localItems,
                remoteItems: remoteState.items,
                localTombstones: tombstones,
                remoteTombstones: remoteState.tombstones,
                maxItems: maxItems
            )
            for item in merged.items where item.isImage {
                try prepareCloudAssetIfNeeded(for: item, cloudImagesDirectoryURL: locations.imagesURL)
            }
            try ClipFlowCloudSyncFile.writeIfChanged(merged, replacing: remoteState, at: writeURL)
            return merged
        }

        // iCloud may deliver an image before the history that references it.
        // A single device's snapshot cannot prove a remote asset is orphaned.
        // Only local assets are garbage-collected until coordinated remote GC exists.
        let localReadyItems = merged.items.filter {
            ensureLocalAssetIfNeeded(for: $0, cloudImagesDirectoryURL: locations.imagesURL)
        }

        return ClipFlowCloudSyncResult(
            cloudItems: merged.items,
            localItems: localReadyItems,
            tombstones: merged.tombstones
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

struct ClipFlowMergedHistory: Equatable, Sendable {
    var items: [ClipboardItem]
    var tombstones: [UUID: Date]
}

/// Item identity wins over whole-file replacement. Capture time picks the version;
/// a pin cannot move that timestamp, so a tombstone stays a tombstone.
final class ClipFlowHistoryMerge {
    private init() {}

    static func merge(
        localItems: [ClipboardItem],
        remoteItems: [ClipboardItem],
        localTombstones: [UUID: Date],
        remoteTombstones: [UUID: Date],
        maxItems: Int,
        now: Date = Date()
    ) -> ClipFlowMergedHistory {
        let tombstones = prune(mergeTombstones(localTombstones, remoteTombstones), now: now)
        var byID: [UUID: ClipboardItem] = [:]
        for item in remoteItems + localItems {
            guard !item.isSensitive, shouldKeep(item, tombstones: tombstones) else { continue }
            if let existing = byID[item.id] {
                byID[item.id] = preferred(existing, item)
            } else {
                byID[item.id] = item
            }
        }

        var items = byID.values.sorted(by: ClipboardItemOrder.isBefore)
        if items.count > maxItems {
            let pinned = items.filter(\.pinned)
            let rest = items.filter { !$0.pinned }
            items = pinned + rest.prefix(max(0, maxItems - pinned.count))
        }
        return ClipFlowMergedHistory(items: items, tombstones: tombstones)
    }

    private static func shouldKeep(_ item: ClipboardItem, tombstones: [UUID: Date]) -> Bool {
        guard let tombstone = tombstones[item.id] else { return true }
        // No capture time means createdAt may be a legacy pin bump. A deletion wins.
        guard let capturedAt = item.capturedAt else { return false }
        return capturedAt > tombstone
    }

    private static func mergeTombstones(_ lhs: [UUID: Date], _ rhs: [UUID: Date]) -> [UUID: Date] {
        var merged = lhs
        for (id, date) in rhs {
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

    private static func prune(_ tombstones: [UUID: Date], now: Date) -> [UUID: Date] {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return tombstones.filter { $0.value >= cutoff }
    }

    /// Newer capture wins. When the capture is unchanged, the later pin edit wins.
    /// Equal versions fall back to a byte order so argument order cannot change the result.
    private static func preferred(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> ClipboardItem {
        if lhs.captureTimestamp != rhs.captureTimestamp {
            return lhs.captureTimestamp > rhs.captureTimestamp ? lhs : rhs
        }
        let leftPin = ClipboardItemOrder.pinTimestamp(of: lhs)
        let rightPin = ClipboardItemOrder.pinTimestamp(of: rhs)
        if leftPin != rightPin {
            return leftPin > rightPin ? lhs : rhs
        }
        return canonical(lhs, rhs)
    }

    private static func canonical(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> ClipboardItem {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let left = [UInt8]((try? encoder.encode(lhs)) ?? Data())
        let right = [UInt8]((try? encoder.encode(rhs)) ?? Data())
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }
}

/// Coordinated read plus atomic replace. Callers merge inside the block so a
/// concurrent iCloud write is folded in instead of overwritten.
final class ClipFlowCloudSyncFile {
    private init() {}

    static func coordinate<T: Sendable>(
        historyAt url: URL,
        _ body: (URL, URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let outcome = CoordinationOutcome<T>()
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { readURL, writeURL in
            outcome.result = Result { try body(readURL, writeURL) }
        }
        if coordinationError != nil {
            throw ClipFlowCloudSyncError.writeFailed
        }
        guard let result = outcome.result else {
            throw ClipFlowCloudSyncError.writeFailed
        }
        return try result.get()
    }

    static func readState(at url: URL) throws -> ClipFlowCloudSyncState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClipFlowCloudSyncState()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ClipFlowCloudSyncState.self, from: data)
        } catch {
            throw ClipFlowCloudSyncError.invalidState
        }
    }

    static func writeIfChanged(
        _ merged: ClipFlowMergedHistory,
        replacing remote: ClipFlowCloudSyncState,
        at url: URL
    ) throws {
        guard remote.items != merged.items || remote.tombstones != merged.tombstones else {
            return
        }
        let state = ClipFlowCloudSyncState(
            schemaVersion: remote.schemaVersion,
            updatedAt: Date(),
            items: merged.items,
            tombstones: merged.tombstones
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw ClipFlowCloudSyncError.writeFailed
        }
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ClipFlowCloudSyncError.writeFailed
        }
    }
}

private final class CoordinationOutcome<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
