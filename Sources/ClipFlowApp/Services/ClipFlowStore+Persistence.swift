import AppKit
import Foundation
import ImageIO

extension ClipFlowStore {
    func imageURL(for item: ClipboardItem) -> URL? {
        guard let imageFilename = item.imageFilename else { return nil }
        return imagesDirectoryURL.appendingPathComponent(imageFilename)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let imageURL = imageURL(for: item) else { return nil }
        return try? Data(contentsOf: imageURL, options: [.mappedIfSafe])
    }

    /// O(1) RAM-only thumbnail lookup for 120Hz scrolling — never blocks the main thread on disk I/O.
    func cachedImagePreview(for item: ClipboardItem) -> NSImage? {
        guard !item.isExpired(), let imageFilename = item.imageFilename else { return nil }
        return imagePreviewCache.object(forKey: imageFilename as NSString)
    }

    func imagePreview(for item: ClipboardItem) -> NSImage? {
        guard !item.isExpired() else { return nil }
        guard let imageFilename = item.imageFilename else { return nil }

        let cacheKey = imageFilename as NSString
        if let cachedImage = imagePreviewCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let imageURL = imageURL(for: item),
              let thumbnail = Self.decodeThumbnail(at: imageURL) else {
            return nil
        }

        let image = NSImage(cgImage: thumbnail, size: .zero)
        imagePreviewCache.setObject(image, forKey: cacheKey, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }

    /// Decodes image thumbnails concurrently off the main thread and streams each into RAM
    /// immediately as soon as it completes, so fast scrolling and time-dial jumps never block or show blanks.
    func prewarmQuickPasteAssets(
        around centerIndex: Int = 0,
        limit: Int = 24,
        in sourceItems: [ClipboardItem]? = nil,
        priority: TaskPriority = .utility
    ) {
        let candidates = sourceItems ?? quickPasteItems
        guard !candidates.isEmpty, limit > 0 else { return }
        let clampedCenter = min(max(0, centerIndex), candidates.count - 1)
        let start = max(0, clampedCenter - 4)
        let end = min(candidates.count, start + limit)
        guard start < end else { return }
        let slice = Array(candidates[start..<end])

        AppIconResolver.shared.prewarm(items: slice)
        DetailTextPrewarmer.shared.prewarm(items: slice, store: self, priority: priority)

        var uncachedImages: [(filename: String, url: URL)] = []
        for item in slice where item.isImage && !item.isExpired() {
            guard let filename = item.imageFilename else { continue }
            if imagePreviewCache.object(forKey: filename as NSString) == nil,
               !inFlightPrewarmFilenames.contains(filename),
               let url = imageURL(for: item) {
                inFlightPrewarmFilenames.insert(filename)
                uncachedImages.append((filename, url))
            }
        }
        guard !uncachedImages.isEmpty else { return }

        Task.detached(priority: priority) { [weak self] in
            let maxConcurrent = 4
            await withTaskGroup(of: (String, CGImage?, Int).self) { group in
                var nextIndex = 0
                let initialCount = min(maxConcurrent, uncachedImages.count)
                for _ in 0..<initialCount {
                    let entry = uncachedImages[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        if let cgImage = Self.decodeThumbnail(at: entry.url) {
                            return (entry.filename, cgImage, cgImage.bytesPerRow * cgImage.height)
                        }
                        return (entry.filename, nil, 0)
                    }
                }

                for await (filename, cgImage, cost) in group {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.inFlightPrewarmFilenames.remove(filename)
                        if let cgImage {
                            let key = filename as NSString
                            if self.imagePreviewCache.object(forKey: key) == nil {
                                self.imagePreviewCache.setObject(NSImage(cgImage: cgImage, size: .zero), forKey: key, cost: cost)
                            }
                        }
                    }
                    if nextIndex < uncachedImages.count {
                        let entry = uncachedImages[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            if let cgImage = Self.decodeThumbnail(at: entry.url) {
                                return (entry.filename, cgImage, cgImage.bytesPerRow * cgImage.height)
                            }
                            return (entry.filename, nil, 0)
                        }
                    }
                }
            }
        }
    }

    nonisolated static func decodeThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    func loadItems() -> [ClipboardItem] {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: historyURL)
            } catch CocoaError.fileReadNoSuchFile {
                return []
            }
            let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
            let normalized = decoded.map { $0.applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled) }
            let kept = normalized.filter { item in
                if item.isImage, let imageURL = imageURL(for: item), !fileManager.fileExists(atPath: imageURL.path) {
                    return false
                }
                return !item.isExpired()
            }
            let keptIDs = Set(kept.map(\.id))
            let dropped = normalized.filter { !keptIDs.contains($0.id) }
            for item in dropped where item.secretPayloadRef != nil {
                SensitivePayloadStore.deleteStoredPayload(for: item, repository: payloadRepository, digests: payloadDigests)
            }

            var needsRewrite = dropped.contains {
                $0.secretPayloadRef != nil || SensitivePayloadStore.containsProtectedPlaintext($0)
            }
            var blockedRewrite = false
            var prepared: [ClipboardItem] = []
            prepared.reserveCapacity(kept.count)
            for item in kept {
                do {
                    let materialized = try SensitivePayloadStore.materialize(
                        item, repository: payloadRepository, digests: payloadDigests
                    )
                    prepared.append(materialized.item)
                    if materialized.rewrotePlaintext {
                        needsRewrite = true
                    }
                } catch {
                    prepared.append(item)
                    blockedRewrite = true
                    lastCaptureStatus = SensitivePayloadStore.keychainWriteFailure
                }
            }

            if needsRewrite && !blockedRewrite {
                do {
                    try writePersistedHistory(prepared)
                } catch {
                    report(error)
                }
            }
            return prepared
        } catch {
            historyLoadError = "历史文件读取失败，已保留原文件和图片。新记录暂存于内存，请恢复历史文件后重启应用。"
            lastCaptureStatus = historyLoadError ?? "历史文件读取失败"
            return []
        }
    }

    func schedulePersistItems() {
        guard historyLoadError == nil else { return }

        let data: Data
        do {
            data = try persistedHistoryData(for: items)
        } catch {
            report(error)
            return
        }

        pendingPersistWorkItem?.cancel()
        let generation = historyWriter.stage(data)
        let writer = historyWriter
        let writerBlock: @Sendable () -> Void = {
            if writer.writeIfCurrent(generation) == .failed {
                Task { @MainActor in
                    ClipFlowStore.shared.lastCaptureStatus = "保存历史记录失败"
                }
            }
        }
        let workItem = DispatchWorkItem(qos: .utility, flags: .assignCurrentContext, block: writerBlock)
        pendingPersistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    /// Writes any debounced history snapshot immediately. Safe when nothing is waiting.
    func flushPendingPersistence() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        if historyWriter.flush() == .failed {
            lastCaptureStatus = "保存历史记录失败"
        }
    }

    /// Writes the latest history snapshot now and drops the delayed copy.
    /// Tests call this before deleting the storage directory.
    func flushPendingPersistenceForTests() {
        flushPendingPersistence()
    }

    private func persistedHistoryData(for items: [ClipboardItem]) throws -> Data {
        let redacted: [ClipboardItem]
        do {
            redacted = try items.map {
                try SensitivePayloadStore.redactedForDisk($0, repository: payloadRepository, digests: payloadDigests)
            }
        } catch {
            throw HistoryPersistError.keychain(error)
        }
        do {
            return try JSONEncoder().encode(redacted)
        } catch {
            throw HistoryPersistError.encoding(error)
        }
    }

    private func report(_ error: Error) {
        if let failure = error as? HistoryPersistError {
            lastCaptureStatus = failure.statusMessage
        } else {
            lastCaptureStatus = "保存历史记录失败"
        }
    }

    private enum HistoryPersistError: Error {
        case keychain(Error)
        case encoding(Error)

        var statusMessage: String {
            switch self {
            case .keychain:
                SensitivePayloadStore.keychainWriteFailure
            case .encoding:
                SensitivePayloadStore.encodingFailure
            }
        }
    }

    private func writePersistedHistory(_ items: [ClipboardItem]) throws {
        try historyWriter.writeNow(try persistedHistoryData(for: items))
    }

    func removeStoredAssetIfNeeded(for item: ClipboardItem) {
        SensitivePayloadStore.deleteStoredPayload(for: item, repository: payloadRepository, digests: payloadDigests)
        if let imageFilename = item.imageFilename {
            imagePreviewCache.removeObject(forKey: imageFilename as NSString)
        }

        guard let imageURL = imageURL(for: item), fileManager.fileExists(atPath: imageURL.path) else {
            return
        }

        try? fileManager.removeItem(at: imageURL)
    }

    func cleanupOrphanedImageFiles() {
        guard historyLoadError == nil else { return }
        guard let fileURLs = try? fileManager.contentsOfDirectory(at: imagesDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        let activeFilenames = Set(items.compactMap(\.imageFilename))
        for fileURL in fileURLs where !activeFilenames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
