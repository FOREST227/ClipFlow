import XCTest
import AppKit
@testable import ClipFlowApp

@MainActor
final class StoreTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults)
    }

    func testStorePreservesWhitespaceAndDistinctCopies() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("  hello\n", sourceApp: "Editor", sourceBundleID: nil)
        store.ingestCopiedText("hello", sourceApp: "Editor", sourceBundleID: nil)
        XCTAssertEqual(Set(store.items.map(\.fullText)), ["  hello\n", "hello"])
        try await Task.sleep(nanoseconds: 200000000)
    }

    func testOverflowRetainsPinnedItem() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("keep me", sourceApp: "Editor", sourceBundleID: nil)
        let pinnedID = try XCTUnwrap(store.items.first?.id)
        store.togglePin(pinnedID)
        for index in 0..<80 {
            store.ingestCopiedText("note \(index)", sourceApp: "Editor", sourceBundleID: nil)
        }
        XCTAssertEqual(store.items.count, 80)
        XCTAssertNotNil(store.item(withID: pinnedID))
        try await Task.sleep(nanoseconds: 200000000)
    }

    func testCorruptHistoryPreservesImagesAndOriginalFile() async throws {
        let (directory, defaults) = try fixture()
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let imageURL = images.appendingPathComponent("recoverable.png")
        try Data([1, 2, 3]).write(to: imageURL)
        let historyURL = directory.appendingPathComponent("history.json")
        let original = Data("{broken".utf8)
        try original.write(to: historyURL)
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("new copy", sourceApp: "Editor", sourceBundleID: nil)
        try await Task.sleep(nanoseconds: 200000000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(try Data(contentsOf: historyURL), original)
    }

    func testResumeDoesNotDiscardNextExternalCopy() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        store.capturePaused = true
        pasteboard.setString("own copy", forType: .string)
        monitor.ignoreCurrentPasteboardUpdate()
        monitor.poll(sourceApplication: nil)
        store.capturePaused = false
        pasteboard.clearContents()
        pasteboard.setString("external copy", forType: .string)
        monitor.poll(sourceApplication: nil)
        XCTAssertEqual(store.items.first?.fullText, "external copy")
        try await Task.sleep(nanoseconds: 200000000)
    }

    func testExpirySettingSurvivesRestartAndKeepsSensitiveContentLocal() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertTrue(store.sensitiveAutoExpireEnabled)
        store.sensitiveAutoExpireEnabled = false
        store.ingestCopiedText("private note", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let item = try XCTUnwrap(store.items.first)
        XCTAssertFalse(item.autoExpire)
        XCTAssertNil(item.expiresAt)
        XCTAssertTrue(item.localOnly)
        XCTAssertEqual(item.privacy, .vault)
        store.purgeExpired(at: Date().addingTimeInterval(600))
        XCTAssertEqual(store.items.count, 1)
        try await Task.sleep(nanoseconds: 200000000)
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertFalse(reloaded.sensitiveAutoExpireEnabled)
        XCTAssertEqual(reloaded.items.count, 1)
        reloaded.sensitiveAutoExpireEnabled = true
        XCTAssertEqual(try XCTUnwrap(reloaded.items.first?.expiresAt).timeIntervalSince(item.createdAt), 300, accuracy: 0.01)
        try await Task.sleep(nanoseconds: 200000000)
    }

    func testExpiryRemovesPinnedItemsWithoutNewCopy() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("private note", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let item = try XCTUnwrap(store.items.first)
        store.togglePin(item.id)
        store.toggleReveal(item.id)
        store.purgeExpired(at: item.createdAt.addingTimeInterval(299))
        XCTAssertEqual(store.items.count, 1)
        store.purgeExpired(at: item.createdAt.addingTimeInterval(300))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.revealedItemIDs.isEmpty)
        try await Task.sleep(nanoseconds: 200000000)
    }

    func testEnablingExpiryDeletesOldSensitiveHistory() async throws {
        let (directory, defaults) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        var item = ClipboardClassifier.makeItem(text: "private note", sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords", autoProtectSecrets: true, existingItem: nil)
        item.createdAt = Date().addingTimeInterval(-301)
        item.capturedAt = nil // Old history has no separate capture timestamp.
        item.pinned = true
        try JSONEncoder().encode([item]).write(to: directory.appendingPathComponent("history.json"))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.items.count, 1)
        store.sensitiveAutoExpireEnabled = true
        XCTAssertTrue(store.items.isEmpty)
        try await Task.sleep(nanoseconds: 200000000)
    }

    func testRapidCopiesAreDebouncedBeforeSync() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, syncDirectory: directory)
        store.iCloudSyncEnabled = true
        store.ingestCopiedText("first", sourceApp: "Editor", sourceBundleID: nil)
        store.ingestCopiedText("second", sourceApp: "Editor", sourceBundleID: nil)
        try await Task.sleep(nanoseconds: 200000000)
        let historyURL = directory.appendingPathComponent("ClipFlow/history.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        try await Task.sleep(nanoseconds: 1000000000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        store.setICloudSyncEnabled(false)
    }

    func testDisabledSyncCancelsPendingWrite() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, syncDirectory: directory)
        store.iCloudSyncEnabled = true
        store.ingestCopiedText("hello", sourceApp: "Editor", sourceBundleID: nil)
        store.setICloudSyncEnabled(false)
        try await Task.sleep(nanoseconds: 1100000000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ClipFlow/history.json").path))
    }

    func testIdlePausedPollPurgesExpiredContent() async throws {
        let (directory, defaults) = try fixture()
        var item = ClipboardClassifier.makeItem(text: "private note", sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords", autoProtectSecrets: true, existingItem: nil)
        item.createdAt = Date().addingTimeInterval(-299)
        item.capturedAt = item.createdAt
        try JSONEncoder().encode([item]).write(to: directory.appendingPathComponent("history.json"))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.items.count, 1)
        store.capturePaused = true
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        try await Task.sleep(nanoseconds: 1100000000)
        monitor.poll(sourceApplication: nil)
        XCTAssertTrue(store.items.isEmpty)
        try await Task.sleep(nanoseconds: 200000000)
        let persisted = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: directory.appendingPathComponent("history.json")))
        XCTAssertTrue(persisted.isEmpty)
    }

    func testPinAndRestartDoNotExtendExpiry() async throws {
        let (directory, defaults) = try fixture()
        var item = ClipboardClassifier.makeItem(text: "private note", sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords", autoProtectSecrets: true, existingItem: nil)
        item.createdAt = Date().addingTimeInterval(-250)
        item.capturedAt = item.createdAt
        try JSONEncoder().encode([item]).write(to: directory.appendingPathComponent("history.json"))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.togglePin(item.id)
        try await Task.sleep(nanoseconds: 200000000)
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(try XCTUnwrap(reloaded.items.first?.expiresAt).timeIntervalSince(item.createdAt), 300, accuracy: 0.01)
    }

    func testImagePreviewIsDownsampledButOriginalIsPreserved() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 1600, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        store.ingestCopiedImage(data, size: .init(width: 1600, height: 1200), sourceApp: "Editor", sourceBundleID: nil)
        let item = try XCTUnwrap(store.items.first)
        let preview = try XCTUnwrap(store.imagePreview(for: item)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(preview.width, 640)
        XCTAssertLessThanOrEqual(preview.height, 640)
        XCTAssertEqual(store.imageData(for: item), data)
        try await Task.sleep(nanoseconds: 200000000)
    }
}
