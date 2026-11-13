import XCTest
@testable import ClipFlowApp

@MainActor
final class SensitivePersistenceTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, MemorySensitivePayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let payloads = MemorySensitivePayloadRepository()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults, payloads)
    }

    private func makeStore(in directory: URL, defaults: UserDefaults, payloads: MemorySensitivePayloadRepository) -> ClipFlowStore {
        ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
    }

    func testFlushOnTerminatePersistsTheLastItem() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let historyURL = directory.appendingPathComponent("history.json")
        let delegate = ClipFlowAppDelegate(store: store)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        if FileManager.default.fileExists(atPath: historyURL.path) {
            let initial = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL))
            XCTAssertTrue(initial.isEmpty)
        }

        store.ingestCopiedText("last item before quit", sourceApp: "Editor", sourceBundleID: nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let persisted = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL))
        XCTAssertEqual(persisted.map(\.fullText), ["last item before quit"])

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let again = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL))
        XCTAssertEqual(again.map(\.fullText), ["last item before quit"])
    }

    func testSensitiveItemRoundTripsWithoutPlaintextInHistoryOrSyncedDocument() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let payload = "clip-secret-9f3a2c7b"
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        store.sensitiveAutoExpireEnabled = false
        store.ingestCopiedText("shopping list", sourceApp: "Notes", sourceBundleID: nil)
        store.ingestCopiedText(payload, sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")

        let delegate = ClipFlowAppDelegate(store: store)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let historyURL = directory.appendingPathComponent("history.json")
        let raw = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(payload), raw)
        XCTAssertTrue(raw.contains("shopping list"))

        let persisted = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL))
        let storedSecret = try XCTUnwrap(persisted.first { $0.secretPayloadRef != nil })
        XCTAssertEqual(storedSecret.fullText, "")
        XCTAssertEqual(storedSecret.snippet, "")
        XCTAssertEqual(store.items.first { $0.privacy == .vault }?.fullText, payload)

        let reloaded = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let restored = try XCTUnwrap(reloaded.items.first { $0.privacy == .vault })
        XCTAssertEqual(restored.fullText, payload)
        XCTAssertEqual(restored.snippet, payload)

        let syncDirectory = directory.appendingPathComponent("sync")
        let coordinator = ClipFlowCloudSyncCoordinator(
            localImagesDirectoryURL: directory.appendingPathComponent("images"),
            documentsDirectoryURL: syncDirectory
        )
        let result = try coordinator.synchronize(localItems: reloaded.items, tombstones: [:], maxItems: 80)
        XCTAssertTrue(result.cloudItems.allSatisfy { !$0.isSensitive && !$0.fullText.contains(payload) })
        let cloudHistory = syncDirectory.appendingPathComponent("ClipFlow/history.json")
        let cloudRaw = try String(contentsOf: cloudHistory, encoding: .utf8)
        XCTAssertFalse(cloudRaw.contains(payload), cloudRaw)
        XCTAssertTrue(cloudRaw.contains("shopping list"))
    }

    func testMigratesPlaintextSensitiveItemsOutOfHistoryFile() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let payload = "legacy-secret-1c4e8a"
        var sensitive = ClipboardClassifier.makeItem(
            text: payload,
            sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords",
            autoProtectSecrets: true,
            existingItem: nil
        )
        sensitive.autoExpire = false
        sensitive.expiresAt = nil
        sensitive.localOnly = true
        let visible = ClipboardClassifier.makeItem(
            text: "shopping list",
            sourceApp: "Notes",
            sourceBundleID: nil,
            autoProtectSecrets: true,
            existingItem: nil
        )
        let historyURL = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode([sensitive, visible]).write(to: historyURL)

        let historyStore = makeStore(in: directory, defaults: defaults, payloads: payloads)
        XCTAssertEqual(historyStore.items.first { $0.privacy == .vault }?.fullText, payload)
        XCTAssertEqual(historyStore.items.first { $0.privacy == .standard }?.fullText, "shopping list")

        let raw = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(payload), raw)
        XCTAssertTrue(raw.contains("shopping list"))
        let persisted = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL))
        let migrated = try XCTUnwrap(persisted.first { $0.secretPayloadRef != nil })
        XCTAssertEqual(migrated.fullText, "")
        XCTAssertEqual(migrated.snippet, "")

        let reloaded = makeStore(in: directory, defaults: defaults, payloads: payloads)
        XCTAssertEqual(reloaded.items.first { $0.privacy == .vault }?.fullText, payload)
        XCTAssertEqual(reloaded.items.first { $0.privacy == .vault }?.snippet, payload)
    }

    func testUnchangedSecretDoesNotWriteThePayloadStoreAgain() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let secret = "clip-secret-unchanged-44b1"
        store.ingestCopiedText(secret, sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let secretID = try XCTUnwrap(store.items.first { $0.privacy == .vault }?.id)
        ClipFlowAppDelegate(store: store).applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(payloads.saveCount, 1)

        store.ingestCopiedText("shopping list", sourceApp: "Notes", sourceBundleID: nil)
        store.togglePin(secretID)
        ClipFlowAppDelegate(store: store).applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(payloads.saveCount, 1)

        store.ingestCopiedText("clip-secret-changed-88e2", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        ClipFlowAppDelegate(store: store).applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(payloads.saveCount, 2)

        let reloaded = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let reloadedSecret = try XCTUnwrap(reloaded.items.first { $0.id == secretID })
        XCTAssertEqual(reloadedSecret.fullText, secret)
        reloaded.togglePin(secretID)
        ClipFlowAppDelegate(store: reloaded).applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(payloads.saveCount, 2)
    }

    func testUnreadablePayloadStaysMarkedAndIsNotWrittenBack() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        payloads.loadFailure = SensitivePayloadTestFailure()
        var item = ClipboardClassifier.makeItem(
            text: "clip-secret-unreadable-19aa",
            sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords",
            autoProtectSecrets: true,
            existingItem: nil
        )
        item.autoExpire = false
        item.expiresAt = nil
        item.fullText = ""
        item.snippet = ""
        item.secretPayloadRef = item.id.uuidString
        let historyURL = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode([item]).write(to: historyURL)

        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let loaded = try XCTUnwrap(store.items.first)
        XCTAssertEqual(loaded.secretPayloadUnavailable, true)
        XCTAssertEqual(loaded.fullText, "")
        XCTAssertEqual(loaded.snippet, "")
        XCTAssertEqual(store.displayFullText(for: loaded), SensitivePayloadStore.unreadableStatus)
        XCTAssertEqual(store.displaySnippet(for: loaded), SensitivePayloadStore.unreadableStatus)
        XCTAssertEqual(payloads.saveCount, 0)

        ClipFlowAppDelegate(store: store).applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let raw = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(SensitivePayloadStore.unreadableStatus), raw)
        XCTAssertFalse(raw.contains("clip-secret-unreadable-19aa"), raw)
        XCTAssertEqual(payloads.saveCount, 0)
    }
}
