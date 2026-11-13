import XCTest
@testable import ClipFlowApp

@MainActor
final class SensitiveSearchAndOTPTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, LoadCountingPayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let payloads = LoadCountingPayloadRepository()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults, payloads)
    }

    private func makeStore(
        in directory: URL,
        defaults: UserDefaults,
        payloads: LoadCountingPayloadRepository
    ) -> ClipFlowStore {
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        addTeardownBlock { store.flushPendingPersistenceForTests() }
        return store
    }

    func testSearchDoesNotRevealMaskedItemByItsSecret() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let secret = "correct-horse-battery-7f3a"
        let command = "export PATH=\"$HOME/clipflow-hidden-path-9f3a/bin:$PATH\""

        store.ingestCopiedText("shopping list for horse tack", sourceApp: "Notes", sourceBundleID: "com.apple.Notes")
        store.ingestCopiedText(secret, sourceApp: "Sketch", sourceBundleID: "com.bohemiancoding.sketch3")
        store.ingestCopiedText(command, sourceApp: "Terminal", sourceBundleID: "com.apple.Terminal")

        let password = try XCTUnwrap(store.items.first { $0.fullText == secret })
        let masked = try XCTUnwrap(store.items.first { $0.fullText == command })
        XCTAssertEqual(password.privacy, .vault)
        XCTAssertTrue(password.isSensitive)
        XCTAssertEqual(masked.privacy, .masked)
        XCTAssertTrue(masked.isSensitive)
        XCTAssertFalse(store.isRevealed(password))
        XCTAssertFalse(store.displaySnippet(for: password).contains("horse"))

        store.searchText = "horse"
        XCTAssertEqual(store.filteredItems.map(\.sourceApp), ["Notes"])
        XCTAssertEqual(store.hudItems(matching: "horse").map(\.sourceApp), ["Notes"])

        store.searchText = "clipflow-hidden-path-9f3a"
        XCTAssertTrue(store.filteredItems.isEmpty)
        XCTAssertTrue(store.hudItems(matching: "clipflow-hidden-path-9f3a").isEmpty)

        store.toggleReveal(password.id)
        XCTAssertTrue(store.isRevealed(password))
        store.searchText = "horse"
        XCTAssertEqual(store.filteredItems.map(\.sourceApp), ["Notes"])
        XCTAssertEqual(store.hudItems(matching: "battery").map(\.sourceApp), [])

        store.searchText = "Sketch"
        let found = try XCTUnwrap(store.filteredItems.first)
        XCTAssertEqual(found.id, password.id)
        XCTAssertEqual(store.hudItems(matching: "sketch").map(\.id), [password.id])

        store.searchText = "终端"
        XCTAssertEqual(store.filteredItems.map(\.id), [masked.id])
        XCTAssertEqual(store.hudItems(matching: "Terminal").map(\.id), [masked.id])
        XCTAssertEqual(payloads.loadCount, 0)
    }

    func testSearchDoesNotDecodeKeychainSecrets() throws {
        let (directory, defaults, payloads) = try fixture()
        let secret = "correct-horse-battery-7f3a"
        var item = ClipboardClassifier.makeItem(
            text: secret,
            sourceApp: "Sketch",
            sourceBundleID: "com.bohemiancoding.sketch3",
            autoProtectSecrets: true,
            existingItem: nil
        )
        let account = item.id.uuidString
        try payloads.save(SensitivePayload(fullText: item.fullText, snippet: item.snippet), account: account)
        item.fullText = ""
        item.snippet = ""
        item.secretPayloadRef = account
        try JSONEncoder().encode([item]).write(to: directory.appendingPathComponent("history.json"))

        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let restored = try XCTUnwrap(store.items.first)
        XCTAssertEqual(restored.fullText, secret)
        XCTAssertEqual(payloads.loadCount, 1)

        store.searchText = "horse"
        XCTAssertTrue(store.filteredItems.isEmpty)
        XCTAssertTrue(store.hudItems(matching: "battery").isEmpty)
        store.searchText = "Sketch"
        XCTAssertEqual(store.filteredItems.map(\.id), [item.id])
        XCTAssertEqual(store.hudItems(matching: "受保护").map(\.id), [item.id])
        XCTAssertEqual(payloads.loadCount, 1, "Search must not decode the Keychain payload")

        store.flushPendingPersistenceForTests()
        let raw = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains(secret), raw)
        XCTAssertEqual(payloads.loadCount, 1)
    }

    func testPlainNumbersAreNotSensitiveWithoutAnOTPSignal() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)

        for text in ["2024", "12345", "1234", "1234567", "20241113"] {
            let item = ClipboardClassifier.makeItem(
                text: text,
                sourceApp: "Notes",
                sourceBundleID: "com.apple.Notes",
                autoProtectSecrets: true,
                existingItem: nil
            )
            XCTAssertFalse(item.isSensitive, text)
            XCTAssertEqual(item.kind, .text, text)
            XCTAssertEqual(item.privacy, .standard, text)

            store.ingestCopiedText(text, sourceApp: "Notes", sourceBundleID: "com.apple.Notes")
            let stored = try XCTUnwrap(store.items.first { $0.fullText == text })
            XCTAssertFalse(stored.isSensitive, text)
        }
    }

    func testRealOTPStaysSensitive() throws {
        let standalone = ClipboardClassifier.makeItem(
            text: "123456",
            sourceApp: "Notes",
            sourceBundleID: "com.apple.Notes",
            autoProtectSecrets: true,
            existingItem: nil
        )
        XCTAssertTrue(standalone.isSensitive)
        XCTAssertEqual(standalone.kind, .secret)

        let phrased = ClipboardClassifier.makeItem(
            text: "验证码：2024",
            sourceApp: "Notes",
            sourceBundleID: "com.apple.Notes",
            autoProtectSecrets: true,
            existingItem: nil
        )
        XCTAssertTrue(phrased.isSensitive)
        XCTAssertEqual(phrased.kind, .secret)
        XCTAssertEqual(phrased.privacy, .vault)

        let fromMessages = ClipboardClassifier.makeItem(
            text: "2024",
            sourceApp: "信息",
            sourceBundleID: "com.apple.MobileSMS",
            autoProtectSecrets: true,
            existingItem: nil
        )
        XCTAssertTrue(fromMessages.isSensitive)
        XCTAssertEqual(fromMessages.kind, .secret)

        let (directory, defaults, payloads) = try fixture()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        store.ingestCopiedText("短信已收到", sourceApp: "信息", sourceBundleID: "com.apple.MobileSMS")
        store.ingestCopiedText("12345", sourceApp: "Safari", sourceBundleID: "com.apple.Safari")
        let recentCode = try XCTUnwrap(store.items.first { $0.fullText == "12345" })
        XCTAssertTrue(recentCode.isSensitive)
        XCTAssertEqual(recentCode.kind, .secret)

        var staleSMS = ClipboardClassifier.makeItem(
            text: "earlier message",
            sourceApp: "信息",
            sourceBundleID: "com.apple.MobileSMS",
            autoProtectSecrets: true,
            existingItem: nil
        )
        staleSMS.capturedAt = Date().addingTimeInterval(-(OTPDetector.recentWindow + 30))
        staleSMS.createdAt = staleSMS.capturedAt ?? Date()
        XCTAssertTrue(OTPDetector.recentSourceBundleIDs(in: [staleSMS]).isEmpty)
        let staleCode = ClipboardClassifier.makeItem(
            text: "12345",
            sourceApp: "Safari",
            sourceBundleID: "com.apple.Safari",
            autoProtectSecrets: true,
            existingItem: nil,
            recentSourceBundleIDs: OTPDetector.recentSourceBundleIDs(in: [staleSMS])
        )
        XCTAssertFalse(staleCode.isSensitive)
    }
}

private final class LoadCountingPayloadRepository: SensitivePayloadRepository {
    private var storage: [String: SensitivePayload] = [:]
    private(set) var loadCount = 0

    func save(_ payload: SensitivePayload, account: String) throws {
        storage[account] = payload
    }

    func load(account: String) throws -> SensitivePayload? {
        loadCount += 1
        return storage[account]
    }

    func delete(account: String) {
        storage.removeValue(forKey: account)
    }
}
