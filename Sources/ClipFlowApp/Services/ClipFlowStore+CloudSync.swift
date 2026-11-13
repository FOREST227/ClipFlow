import SwiftUI

extension ClipFlowStore {
    func setICloudSyncEnabled(_ enabled: Bool) {
        cloudSyncGeneration += 1
        if enabled {
            iCloudSyncEnabled = true
            defaults.set(true, forKey: Keys.iCloudSyncEnabled)
            refreshPermissionReport(showEvenIfHealthy: false)
            Task { [weak self] in
                self?.enableICloudSyncIfPossible(announceResult: true)
            }
        } else {
            pendingCloudSyncTask?.cancel()
            cloudSyncLoopTask?.cancel()
            iCloudSyncEnabled = false
            defaults.set(false, forKey: Keys.iCloudSyncEnabled)
            iCloudSyncPhase = .disabled
            lastCaptureStatus = "已关闭文稿目录同步"
        }
    }

    var iCloudSyncStatusValue: String { iCloudSyncPhase.statusLabel }

    var iCloudSyncTint: Color {
        switch iCloudSyncPhase {
        case .disabled, .pending:
            return .secondary
        case .syncing:
            return ClipCategory.pinned.tint
        case .active:
            return ClipCategory.images.tint
        case .unavailable, .failed:
            return ClipCategory.protected.tint
        }
    }

    var iCloudSyncDetail: String {
        switch iCloudSyncPhase {
        case .disabled:
            return "将普通文本与图片历史镜像到“文稿/ClipFlow”。如果系统已开启 iCloud Drive 的“桌面与文稿文件夹”，这些内容会随系统同步。"
        case .pending:
            return "本机有待同步的内容，正在等待下一次同步。"
        case .syncing:
            return "正在合并本机与“文稿/ClipFlow”中的历史内容。"
        case .active:
            if let iCloudLastSyncedAt {
                return "文稿目录已同步，上次完成于 \(Self.syncFormatter.string(from: iCloudLastSyncedAt))。受保护内容不会写入“文稿/ClipFlow”。"
            }
            return "已启用文稿目录同步。若系统已开启文稿同步，普通历史内容会随系统在设备间同步。"
        case .unavailable:
            return cloudSyncCoordinator.resolveAvailabilityDescription() ?? "当前无法访问“文稿/ClipFlow”。"
        case .failed(let message):
            return message
        }
    }

    func isEligibleForICloudSync(_ item: ClipboardItem) -> Bool {
        !item.isSensitive
    }

    func rememberCloudDeletion(for removedItems: [ClipboardItem]) {
        let now = Date()
        for item in removedItems where isEligibleForICloudSync(item) {
            localSyncTombstones[item.id] = now
        }
    }

    func enableICloudSyncIfPossible(announceResult: Bool) {
        guard iCloudSyncEnabled, historyLoadError == nil else { return }
        startCloudSyncLoop()
        runICloudSync(announceSuccess: announceResult)
    }

    private func startCloudSyncLoop() {
        cloudSyncLoopTask?.cancel()
        cloudSyncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refreshICloudSyncIfNeeded()
            }
        }
    }

    private func refreshICloudSyncIfNeeded() {
        guard iCloudSyncEnabled else { return }
        runICloudSync(announceSuccess: false)
    }

    func scheduleICloudSync() {
        if iCloudSyncEnabled && activeCloudSyncTask == nil { iCloudSyncPhase = .pending }
        pendingCloudSyncTask?.cancel()
        pendingCloudSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 900_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshICloudSyncIfNeeded()
        }
    }

    private func runICloudSync(announceSuccess: Bool) {
        guard iCloudSyncEnabled, historyLoadError == nil else { return }
        guard activeCloudSyncTask == nil else {
            syncRequestedWhileRunning = true
            return
        }

        iCloudSyncPhase = .syncing
        let snapshot = items
        let tombstones = localSyncTombstones
        let revision = itemsRevision
        let generation = cloudSyncGeneration
        let coordinator = cloudSyncCoordinator
        let worker = cloudSyncWorker
        let limit = maxItems
        activeCloudSyncTask = Task { [weak self] in
            let result: Result<ClipFlowCloudSyncResult, Error>
            do {
                result = .success(try await worker.synchronize(
                    using: coordinator, localItems: snapshot, tombstones: tombstones, maxItems: limit
                ))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.activeCloudSyncTask = nil
            let changedDuringSync = self.itemsRevision != revision
            let needsFollowUp = self.syncRequestedWhileRunning || changedDuringSync
                || self.cloudSyncGeneration != generation
            self.syncRequestedWhileRunning = false
            guard self.iCloudSyncEnabled else {
                self.cleanupOrphanedImageFiles()
                return
            }
            guard self.cloudSyncGeneration == generation else {
                self.cleanupOrphanedImageFiles()
                self.scheduleICloudSync()
                return
            }
            switch result {
            case .success(let result):
                // A copy/delete/pin performed during disk I/O must not be overwritten
                // by the older snapshot. Reconcile it in the next serialized run.
                if !changedDuringSync {
                    self.applyCloudItems(result.localItems)
                    self.localSyncTombstones = result.tombstones
                }
                // A background download may have recreated an asset deleted
                // during this run, even when its stale snapshot is discarded.
                self.cleanupOrphanedImageFiles()
                self.iCloudLastSyncedAt = Date()
                self.defaults.set(self.iCloudLastSyncedAt, forKey: Keys.iCloudLastSyncedAt)
                self.iCloudSyncPhase = .active
                if announceSuccess {
                    self.lastCaptureStatus = "已开启文稿目录同步"
                }
                if needsFollowUp { self.scheduleICloudSync() }
            case .failure(let error):
                if changedDuringSync {
                    self.cleanupOrphanedImageFiles()
                    self.scheduleICloudSync()
                } else {
                    self.handleICloudSyncFailure((error as? ClipFlowCloudSyncError) ?? .writeFailed)
                }
            }
        }
    }

    private func handleICloudSyncFailure(_ error: ClipFlowCloudSyncError) {
        cloudSyncGeneration += 1
        pendingCloudSyncTask?.cancel()
        cloudSyncLoopTask?.cancel()
        iCloudSyncEnabled = false
        defaults.set(false, forKey: Keys.iCloudSyncEnabled)

        switch error {
        case .unavailable:
            iCloudSyncPhase = .unavailable
            lastCaptureStatus = cloudSyncCoordinator.resolveAvailabilityDescription() ?? "无法访问“文稿”目录"
        case .invalidState, .writeFailed:
            iCloudSyncPhase = .failed(error.errorDescription ?? "文稿目录同步失败")
            lastCaptureStatus = error.errorDescription ?? "文稿目录同步失败"
        }
    }

    func persistLocalSyncTombstones() {
        guard let data = try? JSONEncoder().encode(localSyncTombstones) else { return }
        defaults.set(data, forKey: Keys.iCloudSyncTombstones)
    }

    private static let syncFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
