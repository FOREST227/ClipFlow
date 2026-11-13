import XCTest
@testable import ClipFlowApp

final class CloudSyncTests: XCTestCase {
    func testStatusLabelsSeparateEnablementFromProgress() {
        XCTAssertEqual(ClipFlowCloudSyncPhase.disabled.statusLabel, "未同步")
        XCTAssertEqual(ClipFlowCloudSyncPhase.pending.statusLabel, "未同步")
        XCTAssertEqual(ClipFlowCloudSyncPhase.syncing.statusLabel, "同步中")
        XCTAssertEqual(ClipFlowCloudSyncPhase.active.statusLabel, "已同步")
        XCTAssertEqual(ClipFlowCloudSyncPhase.unavailable.statusLabel, "同步失败")
        XCTAssertEqual(ClipFlowCloudSyncPhase.failed("error").statusLabel, "同步失败")
    }

    func testUnchangedSyncDoesNotRewriteHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appendingPathComponent("localImages")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: images, documentsDirectoryURL: directory)
        let item = ClipboardClassifier.makeItem(text: "hello", sourceApp: "Editor",
            sourceBundleID: nil, autoProtectSecrets: true, existingItem: nil)
        _ = try coordinator.synchronize(localItems: [item], tombstones: [:], maxItems: 80)
        let historyURL = directory.appendingPathComponent("ClipFlow/history.json")
        let first = try Data(contentsOf: historyURL)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: historyURL.path)
        _ = try coordinator.synchronize(localItems: [item], tombstones: [:], maxItems: 80)
        XCTAssertEqual(try Data(contentsOf: historyURL), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: historyURL.path)[.modificationDate] as? Date, timestamp)
    }

    func testSensitiveItemsNeverSyncEvenWithExpiryOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: directory, documentsDirectoryURL: directory)
        let item = ClipboardClassifier.makeItem(text: "private note", sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords", autoProtectSecrets: true, existingItem: nil)
            .applyingExpirationPolicy(enabled: false)
        let result = try coordinator.synchronize(localItems: [item], tombstones: [:], maxItems: 80)
        XCTAssertTrue(result.cloudItems.isEmpty)
    }

    func testSensitiveItemAndPayloadReferenceNeverReachSyncedFile() throws {
        let (coordinator, directory) = try temporaryCoordinator()
        let visible = sampleItem("shopping list", at: Date().addingTimeInterval(-30))
        let sensitive = ClipboardClassifier.makeItem(
            text: "clip-secret-sync-9f3a",
            sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords",
            autoProtectSecrets: true,
            existingItem: nil
        ).applyingExpirationPolicy(enabled: false)
        var referenced = sampleItem("visible label", at: Date().addingTimeInterval(-10))
        referenced.secretPayloadRef = referenced.id.uuidString
        referenced.fullText = "clip-secret-ref-18c4"
        referenced.snippet = "clip-secret-ref-18c4"
        XCTAssertTrue(sensitive.isSensitive)
        XCTAssertFalse(referenced.isSensitive)

        let result = try coordinator.synchronize(
            localItems: [visible, sensitive, referenced],
            tombstones: [:],
            maxItems: 80
        )
        XCTAssertFalse(result.cloudItems.contains { $0.id == sensitive.id })
        let historyURL = directory.appendingPathComponent("ClipFlow/history.json")
        let raw = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("shopping list"))
        XCTAssertFalse(raw.contains("clip-secret-sync-9f3a"), raw)
        XCTAssertFalse(raw.contains("clip-secret-ref-18c4"), raw)
        XCTAssertFalse(raw.contains(referenced.id.uuidString), raw)
    }

    func testSyncPreservesRemoteImageThatArrivesBeforeItsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteImages = directory.appendingPathComponent("ClipFlow/images")
        try FileManager.default.createDirectory(at: remoteImages, withIntermediateDirectories: true)
        let incomingAsset = remoteImages.appendingPathComponent("other-device.png")
        let original = Data([1, 2, 3])
        try original.write(to: incomingAsset)
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: directory, documentsDirectoryURL: directory)
        _ = try coordinator.synchronize(localItems: [], tombstones: [:], maxItems: 80)
        XCTAssertEqual(try Data(contentsOf: incomingAsset), original)
    }

    func testPinDoesNotResurrectTombstonedItem() throws {
        let (coordinator, directory) = try temporaryCoordinator()
        let captured = Date().addingTimeInterval(-3_600)
        var deleted = sampleItem("deleted", at: captured)
        deleted.pinned = true
        deleted.pinnedAt = Date()
        deleted.createdAt = Date()
        var fresh = sampleItem("fresh", at: captured.addingTimeInterval(120))
        fresh.pinned = true
        fresh.pinnedAt = Date()
        let tombstone = captured.addingTimeInterval(60)
        let result = try coordinator.synchronize(
            localItems: [deleted, fresh],
            tombstones: [deleted.id: tombstone],
            maxItems: 80
        )

        XCTAssertEqual(result.cloudItems.map(\.id), [fresh.id])
        XCTAssertEqual(result.localItems.map(\.id), [fresh.id])
        XCTAssertFalse(result.cloudItems.contains { $0.id == deleted.id })
        let historyURL = directory.appendingPathComponent("ClipFlow/history.json")
        let stored = try JSONDecoder().decode(ClipFlowCloudSyncState.self, from: Data(contentsOf: historyURL))
        XCTAssertEqual(stored.items.map(\.id), [fresh.id])
        XCTAssertEqual(stored.tombstones[deleted.id]?.timeIntervalSince(tombstone) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(stored.items.first?.createdAt.timeIntervalSince(fresh.createdAt) ?? -1, 0, accuracy: 0.001)
    }

    func testLegacyPinWithoutCaptureTimeDoesNotResurrect() throws {
        let (coordinator, _) = try temporaryCoordinator()
        var legacy = sampleItem("legacy pin", at: Date().addingTimeInterval(-3_600))
        legacy.capturedAt = nil
        legacy.pinned = true
        legacy.createdAt = Date()
        let applied = legacy.applyingExpirationPolicy(enabled: false)
        XCTAssertNil(applied.capturedAt)
        let tombstone = Date().addingTimeInterval(-60)
        let result = try coordinator.synchronize(
            localItems: [legacy],
            tombstones: [legacy.id: tombstone],
            maxItems: 80
        )
        XCTAssertTrue(result.cloudItems.isEmpty)
        XCTAssertTrue(result.localItems.isEmpty)
        XCTAssertNotNil(result.tombstones[legacy.id])
    }

    func testDivergentHistoriesMergeDeterministically() throws {
        let origin = Date().addingTimeInterval(-1_000)
        let alphaID = UUID()
        let oldAlpha = sampleItem("alpha", at: origin.addingTimeInterval(30), id: alphaID)
        var revised = sampleItem("alpha revised", at: origin.addingTimeInterval(50), id: alphaID)
        revised.snippet = "alpha revised"
        var gone = sampleItem("gone", at: origin.addingTimeInterval(5))
        gone.pinned = true
        gone.pinnedAt = Date()
        gone.createdAt = Date()
        var newPin = sampleItem("new pin", at: origin.addingTimeInterval(20))
        newPin.pinned = true
        newPin.pinnedAt = origin.addingTimeInterval(80)
        var oldPin = sampleItem("old pin", at: origin.addingTimeInterval(10))
        oldPin.pinned = true
        oldPin.pinnedAt = origin.addingTimeInterval(40)
        let beta = sampleItem("beta", at: origin.addingTimeInterval(35))
        let historyA = [oldAlpha, gone, newPin]
        let historyB = [revised, beta, oldPin]
        let tombstone = origin.addingTimeInterval(15)
        let tombsB = [gone.id: tombstone]

        let direct = ClipFlowHistoryMerge.merge(
            localItems: historyA,
            remoteItems: historyB,
            localTombstones: [:],
            remoteTombstones: tombsB,
            maxItems: 80
        )
        let swapped = ClipFlowHistoryMerge.merge(
            localItems: historyB,
            remoteItems: historyA,
            localTombstones: tombsB,
            remoteTombstones: [:],
            maxItems: 80
        )
        let forward = try sequence(historyA, tombs: [:], then: historyB, tombs: tombsB)
        let backward = try sequence(historyB, tombs: tombsB, then: historyA, tombs: [:])

        XCTAssertEqual(direct, swapped)
        XCTAssertEqual(direct.items.map(\.fullText), ["new pin", "old pin", "alpha revised", "beta"])
        assertSameItems(forward.cloudItems, direct.items)
        assertSameItems(backward.cloudItems, direct.items)
        assertSameTombstones(forward.tombstones, direct.tombstones)
        assertSameTombstones(backward.tombstones, direct.tombstones)
        XCTAssertFalse(direct.items.contains { $0.id == gone.id })
        XCTAssertEqual(direct.tombstones[gone.id]?.timeIntervalSince(tombstone) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(direct.items.first { $0.id == alphaID }?.fullText, "alpha revised")
    }

    func testPinnedItemOrderIsPreserved() throws {
        let origin = Date().addingTimeInterval(-500)
        var olderLegacy = sampleItem("legacy-older", at: origin.addingTimeInterval(10))
        olderLegacy.pinned = true
        olderLegacy.createdAt = origin.addingTimeInterval(30)
        var newerLegacy = sampleItem("legacy-newer", at: origin.addingTimeInterval(5))
        newerLegacy.pinned = true
        newerLegacy.createdAt = origin.addingTimeInterval(40)
        var recentPin = sampleItem("recent pin", at: origin.addingTimeInterval(1))
        recentPin.pinned = true
        recentPin.pinnedAt = origin.addingTimeInterval(90)
        recentPin.createdAt = origin.addingTimeInterval(1)

        let (coordinator, _) = try temporaryCoordinator()
        let result = try coordinator.synchronize(
            localItems: [olderLegacy, newerLegacy, recentPin],
            tombstones: [:],
            maxItems: 80
        )
        XCTAssertEqual(result.cloudItems.map(\.fullText), ["recent pin", "legacy-newer", "legacy-older"])
        XCTAssertEqual(result.cloudItems.map(\.createdAt), [recentPin.createdAt, newerLegacy.createdAt, olderLegacy.createdAt])
    }

    private func temporaryCoordinator() throws -> (ClipFlowCloudSyncCoordinator, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: directory, documentsDirectoryURL: directory)
        return (coordinator, directory)
    }

    private func sampleItem(_ text: String, at date: Date, id: UUID = UUID()) -> ClipboardItem {
        var item = ClipboardClassifier.makeItem(
            text: text,
            sourceApp: "Editor",
            sourceBundleID: nil,
            autoProtectSecrets: true,
            existingItem: nil
        )
        item.id = id
        item.createdAt = date
        item.capturedAt = date
        item.fullText = text
        return item
    }

    private func sequence(
        _ first: [ClipboardItem],
        tombs firstTombs: [UUID: Date],
        then second: [ClipboardItem],
        tombs secondTombs: [UUID: Date]
    ) throws -> ClipFlowCloudSyncResult {
        let (coordinator, _) = try temporaryCoordinator()
        _ = try coordinator.synchronize(localItems: first, tombstones: firstTombs, maxItems: 80)
        return try coordinator.synchronize(localItems: second, tombstones: secondTombs, maxItems: 80)
    }

    private func assertSameItems(_ lhs: [ClipboardItem], _ rhs: [ClipboardItem], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.map(\.id), rhs.map(\.id), file: file, line: line)
        for pair in zip(lhs, rhs) {
            XCTAssertEqual(pair.0.fullText, pair.1.fullText, file: file, line: line)
            XCTAssertEqual(pair.0.pinned, pair.1.pinned, file: file, line: line)
            XCTAssertEqual(pair.0.captureTimestamp.timeIntervalSince1970, pair.1.captureTimestamp.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(pair.0.createdAt.timeIntervalSince1970, pair.1.createdAt.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual((pair.0.pinnedAt ?? .distantPast).timeIntervalSince1970, (pair.1.pinnedAt ?? .distantPast).timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
        }
    }

    private func assertSameTombstones(_ lhs: [UUID: Date], _ rhs: [UUID: Date], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (id, date) in lhs {
            XCTAssertEqual(rhs[id]?.timeIntervalSince1970 ?? -1, date.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
        }
    }
}
