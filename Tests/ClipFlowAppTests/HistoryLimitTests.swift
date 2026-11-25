import AppKit
import XCTest
@testable import ClipFlowApp

final class HistoryRetentionTests: XCTestCase {
    func testSupportedLimitsAndUnknownValues() {
        XCTAssertEqual(HistoryRetention.choices, [80, 200, 500, 1000])
        XCTAssertEqual(HistoryRetention.defaultLimit, 80)
        XCTAssertEqual(HistoryRetention.normalized(nil), 80)
        XCTAssertEqual(HistoryRetention.normalized(42), 80)
        XCTAssertEqual(HistoryRetention.normalized(200), 200)
    }

    func testPinnedRowsDoNotConsumeOrGetEvictedByTheLimit() {
        let pinnedOld = sample("pinned-old", at: 1, pinned: true)
        let pinnedNew = sample("pinned-new", at: 2, pinned: true)
        let oldest = sample("oldest", at: 3)
        let older = sample("older", at: 4)
        let kept = (0..<3).map { sample("kept-\($0)", at: TimeInterval(10 + $0)) }
        let items = [pinnedOld, oldest, older, pinnedNew] + kept

        let split = HistoryRetention.partition(items, limit: 3)
        XCTAssertEqual(split.removed.map(\.fullText).sorted(), ["older", "oldest"])
        XCTAssertEqual(Set(split.kept.map(\.fullText)), Set(["pinned-old", "pinned-new", "kept-0", "kept-1", "kept-2"]))
        XCTAssertEqual(HistoryRetention.removalCount(in: items, limit: 3), 2)
        XCTAssertEqual(HistoryRetention.removalCount(in: items, limit: 80), 0)
        XCTAssertFalse(HistoryRetention.needsConfirmation(currentLimit: 200, proposedLimit: 500, removalCount: 0))
        XCTAssertFalse(HistoryRetention.needsConfirmation(currentLimit: 200, proposedLimit: 80, removalCount: 0))
        XCTAssertTrue(HistoryRetention.needsConfirmation(currentLimit: 200, proposedLimit: 80, removalCount: 2))
        XCTAssertEqual(
            HistoryRetention.confirmationMessage(removalCount: 2),
            "将删除最早的 2 条未置顶记录。置顶内容会保留。"
        )
    }

    func testMergeUsesTheSamePinnedQuota() throws {
        let pinned = sample("pinned", at: 1, pinned: true)
        let older = sample("older", at: 2)
        let mid = sample("mid", at: 3)
        let newer = sample("newer", at: 4)
        let newest = sample("newest", at: 5)
        let merged = ClipFlowHistoryMerge.merge(
            localItems: [pinned, older, mid],
            remoteItems: [newer, newest],
            localTombstones: [:],
            remoteTombstones: [:],
            maxItems: 2
        )
        XCTAssertEqual(Set(merged.items.map(\.fullText)), ["pinned", "newer", "newest"])

        let restored = ClipFlowHistoryMerge.merge(
            localItems: [],
            remoteItems: [older],
            localTombstones: [older.id: Date()],
            remoteTombstones: [:],
            maxItems: 80
        )
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertNotNil(restored.tombstones[older.id])
    }

    private func sample(_ text: String, at offset: TimeInterval, pinned: Bool = false) -> ClipboardItem {
        var item = ClipboardClassifier.makeItem(
            text: text, sourceApp: "Editor", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
        item.createdAt = date
        item.capturedAt = date
        item.pinned = pinned
        item.pinnedAt = pinned ? date : nil
        return item
    }
}

@MainActor
final class HistoryLimitStoreTests: XCTestCase {
    func testStoredLimitSurvivesRestartAndRejectsUnknownValues() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(500, forKey: ClipFlowStore.Keys.historyItemLimit)
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(store.historyItemLimit, 500)
        XCTAssertEqual(store.maxItems, 500)
        store.applyHistoryItemLimit(42)
        XCTAssertEqual(store.historyItemLimit, 80)
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(reloaded.historyItemLimit, 80)
    }

    func testRaisingTheLimitDoesNotDelete() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = try seededStore(directory: directory, defaults: defaults, payloads: payloads, limit: 80, unpinned: 10, pinned: 2)
        let before = Set(store.items.map(\.id))
        store.applyHistoryItemLimit(200)
        XCTAssertEqual(store.historyItemLimit, 200)
        XCTAssertEqual(Set(store.items.map(\.id)), before)
        XCTAssertTrue(store.localSyncTombstones.isEmpty)
        XCTAssertEqual(store.lastCaptureStatus, HistoryRetention.appliedStatus(limit: 200, removedCount: 0))
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(reloaded.historyItemLimit, 200)
        XCTAssertEqual(reloaded.items.count, 12)
    }

    func testLoweringTrimsOldestUnpinnedAndCleansPayloadsImagesAndTombstones() throws {
        let (directory, defaults, payloads) = try fixture()
        let secretText = "clip-secret-trim-9f3a"
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defaults.set(false, forKey: ClipFlowStore.Keys.sensitiveAutoExpireEnabled)
        defaults.set(200, forKey: ClipFlowStore.Keys.historyItemLimit)

        var secret = ClipboardClassifier.makeItem(
            text: secretText, sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords",
            autoProtectSecrets: true, existingItem: nil
        )
        stamp(&secret, at: 0)
        secret.autoExpire = false
        secret.expiresAt = nil

        var image = ClipboardClassifier.makeImageItem(
            imageFilename: "placeholder.png", imageSignature: "sig",
            imageSize: CGSize(width: 4, height: 4), sourceApp: "Preview",
            sourceBundleID: nil, existingItem: nil
        )
        image.imageFilename = "\(image.id.uuidString).png"
        stamp(&image, at: 1)
        let imageURL = images.appendingPathComponent(image.imageFilename ?? "")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        var pinned = ClipboardClassifier.makeItem(
            text: "pinned-keep", sourceApp: "Editor", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil
        )
        stamp(&pinned, at: 2, pinned: true)

        let fillers = (0..<80).map { index -> ClipboardItem in
            var item = ClipboardClassifier.makeItem(
                text: "keep-\(index)", sourceApp: "Editor", sourceBundleID: nil,
                autoProtectSecrets: false, existingItem: nil
            )
            stamp(&item, at: TimeInterval(10 + index))
            return item
        }
        let history = [secret, image, pinned] + fillers
        try JSONEncoder().encode(history).write(to: directory.appendingPathComponent("history.json"))

        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(store.items.count, 83)
        let secretID = try XCTUnwrap(store.items.first { $0.fullText == secretText }?.id)
        let account = try XCTUnwrap(store.items.first { $0.id == secretID }?.secretPayloadRef)
        XCTAssertEqual(try payloads.load(account: account)?.fullText, secretText)
        store.toggleReveal(secretID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        let syncDirectory = directory.appendingPathComponent("sync")
        let coordinator = ClipFlowCloudSyncCoordinator(
            localImagesDirectoryURL: store.imagesDirectoryURL,
            documentsDirectoryURL: syncDirectory
        )
        _ = try coordinator.synchronize(localItems: store.items, tombstones: [:], maxItems: store.maxItems)

        store.applyHistoryItemLimit(80)

        XCTAssertEqual(store.historyItemLimit, 80)
        XCTAssertEqual(store.items.count, 81)
        XCTAssertNotNil(store.item(withID: pinned.id))
        XCTAssertNil(store.item(withID: secretID))
        XCTAssertNil(store.item(withID: image.id))
        XCTAssertTrue(store.items.contains { $0.fullText == "keep-0" })
        XCTAssertFalse(store.revealedItemIDs.contains(secretID))
        XCTAssertNil(try payloads.load(account: account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertNil(store.localSyncTombstones[secretID], "Sensitive rows are local-only and must not be tombstoned")
        XCTAssertNil(store.localSyncTombstones[pinned.id])
        XCTAssertNotNil(store.localSyncTombstones[image.id])

        let persisted = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains(secretText))
        XCTAssertFalse(persisted.contains(image.imageFilename ?? "missing-image"))
        XCTAssertTrue(persisted.contains("pinned-keep"))
        XCTAssertTrue(persisted.contains("keep-79"))

        let synced = try coordinator.synchronize(
            localItems: store.items,
            tombstones: store.localSyncTombstones,
            maxItems: store.maxItems
        )
        XCTAssertFalse(synced.cloudItems.contains { $0.id == image.id })
        XCTAssertFalse(synced.localItems.contains { $0.id == image.id })
        XCTAssertTrue(synced.cloudItems.contains { $0.fullText == "pinned-keep" })
        let cloudURL = syncDirectory.appendingPathComponent("ClipFlow/history.json")
        let cloudState = try JSONDecoder().decode(ClipFlowCloudSyncState.self, from: Data(contentsOf: cloudURL))
        XCTAssertFalse(cloudState.items.contains { $0.id == image.id })
        XCTAssertNotNil(cloudState.tombstones[image.id])
        XCTAssertNil(cloudState.tombstones[secretID])
        let cloudRaw = try String(contentsOf: cloudURL, encoding: .utf8)
        XCTAssertFalse(cloudRaw.contains(secretText))

        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(reloaded.historyItemLimit, 80)
        XCTAssertEqual(reloaded.items.count, 81)
        XCTAssertNil(try payloads.load(account: account))
    }

    func testSettingsConfirmationTrimsOnlyAfterConfirm() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = try seededStore(directory: directory, defaults: defaults, payloads: payloads, limit: 200, unpinned: 85, pinned: 1)
        let original = store.items.count
        let draft = SettingsDraft(store: store)
        let warning = HistoryRetention.confirmationMessage(removalCount: 5)

        draft.requestHistoryLimit(80, in: store)
        XCTAssertEqual(draft.pendingHistoryLimit, 80)
        XCTAssertEqual(store.historyItemLimit, 200)
        XCTAssertEqual(store.items.count, original)
        XCTAssertEqual(HistoryRetention.removalCount(in: store.items, limit: 80), 5)
        XCTAssertEqual(warning, "将删除最早的 5 条未置顶记录。置顶内容会保留。")

        draft.cancelHistoryLimitChange()
        XCTAssertNil(draft.pendingHistoryLimit)
        XCTAssertEqual(store.historyItemLimit, 200)
        XCTAssertEqual(store.items.count, original)
        XCTAssertTrue(store.localSyncTombstones.isEmpty)

        draft.requestHistoryLimit(500, in: store)
        XCTAssertNil(draft.pendingHistoryLimit)
        XCTAssertEqual(store.historyItemLimit, 500)
        XCTAssertEqual(store.items.count, original)

        draft.requestHistoryLimit(80, in: store)
        draft.confirmHistoryLimitChange(in: store)
        XCTAssertNil(draft.pendingHistoryLimit)
        XCTAssertEqual(store.historyItemLimit, 80)
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, 80)
        XCTAssertEqual(store.items.filter(\.pinned).count, 1)
        XCTAssertEqual(store.localSyncTombstones.count, 5)
    }

    func testThousandItemSearchListAndSaveStayResponsive() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(1000, forKey: ClipFlowStore.Keys.historyItemLimit)
        let items = (0..<1000).map { index -> ClipboardItem in
            var item = ClipboardClassifier.makeItem(
                text: "history-row-\(index) 会议记录与链接 https://example.com/\(index)",
                sourceApp: "Notes", sourceBundleID: nil,
                autoProtectSecrets: false, existingItem: nil
            )
            let date = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
            item.createdAt = date
            item.capturedAt = date
            return item
        }
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("history.json"))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(store.items.count, 1000)

        store.searchText = "history-row-42 会议"
        let searchStart = CFAbsoluteTimeGetCurrent()
        let found = store.filteredItems
        let searchMs = (CFAbsoluteTimeGetCurrent() - searchStart) * 1000
        XCTAssertEqual(found.count, 1)

        store.searchText = "没有这段文字"
        let missStart = CFAbsoluteTimeGetCurrent()
        let missed = store.filteredItems
        let missMs = (CFAbsoluteTimeGetCurrent() - missStart) * 1000
        XCTAssertTrue(missed.isEmpty)

        let geometryStart = CFAbsoluteTimeGetCurrent()
        let placed = HistoryRowGeometry.place(items: store.items, width: 480)
        let geometryMs = (CFAbsoluteTimeGetCurrent() - geometryStart) * 1000
        XCTAssertEqual(placed.frames.count, 1000)

        let target = try XCTUnwrap(store.items.first { $0.fullText.hasPrefix("history-row-500") })
        let saveStart = CFAbsoluteTimeGetCurrent()
        store.togglePin(target.id)
        let saveMs = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
        store.flushPendingPersistence()

        print(String(format: "1000-item search %.2f ms, miss %.2f ms, row geometry %.2f ms, save %.2f ms",
            searchMs, missMs, geometryMs, saveMs))
        XCTAssertLessThan(searchMs, 80, "Search scanned 1000 rows on the main thread")
        XCTAssertLessThan(missMs, 80)
        XCTAssertLessThan(geometryMs, 50)
        XCTAssertLessThan(saveMs, 150, "Saving 1000 rows stalled the main thread")

        store.searchText = ""
        store.libraryViewMode = .list
        _ = NSApplication.shared
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 720, height: 780))
        window.orderFront(nil)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let deadline = Date().addingTimeInterval(5)
        var hosts = historyHosts(in: root)
        while hosts.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hosts = historyHosts(in: root)
        }
        print("1000-item history hosts: \(hosts.count)")
        XCTAssertGreaterThan(hosts.count, 0)
        XCTAssertLessThan(hosts.count, 30, "The history list must keep only visible rows at 1000 items")
    }

    private func seededStore(
        directory: URL,
        defaults: UserDefaults,
        payloads: MemorySensitivePayloadRepository,
        limit: Int,
        unpinned: Int,
        pinned: Int
    ) throws -> ClipFlowStore {
        defaults.set(limit, forKey: ClipFlowStore.Keys.historyItemLimit)
        var items: [ClipboardItem] = []
        for index in 0..<unpinned {
            var item = ClipboardClassifier.makeItem(
                text: "row-\(index)", sourceApp: "Editor", sourceBundleID: nil,
                autoProtectSecrets: false, existingItem: nil
            )
            stamp(&item, at: TimeInterval(index + 1))
            items.append(item)
        }
        for index in 0..<pinned {
            var item = ClipboardClassifier.makeItem(
                text: "pin-\(index)", sourceApp: "Editor", sourceBundleID: nil,
                autoProtectSecrets: false, existingItem: nil
            )
            stamp(&item, at: TimeInterval(1000 + index), pinned: true)
            items.append(item)
        }
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("history.json"))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertEqual(store.historyItemLimit, limit)
        XCTAssertEqual(store.items.count, unpinned + pinned)
        return store
    }

    private func stamp(_ item: inout ClipboardItem, at offset: TimeInterval, pinned: Bool = false) {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
        item.createdAt = date
        item.capturedAt = date
        item.pinned = pinned
        item.pinnedAt = pinned ? date : nil
    }

    private func fixture() throws -> (URL, UserDefaults, MemorySensitivePayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowHistoryLimit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let payloads = MemorySensitivePayloadRepository()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults, payloads)
    }

    private func historyHosts(in view: NSView) -> [LibraryInteractiveHostingView] {
        (view as? LibraryInteractiveHostingView).map { [$0] } ?? view.subviews.flatMap(historyHosts)
    }
}
