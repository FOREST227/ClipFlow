import CryptoKit
import Foundation
import os
import Security

struct SensitivePayload: Codable, Equatable, Sendable {
    var fullText: String
    var snippet: String
}

protocol SensitivePayloadRepository: AnyObject {
    func save(_ payload: SensitivePayload, account: String) throws
    func load(account: String) throws -> SensitivePayload?
    func delete(account: String)
}

/// Remembers the fingerprint of each secret already stored, so a later history save can skip the Keychain.
final class SensitivePayloadDigest {
    private var fingerprints: [String: String] = [:]

    func matches(_ payload: SensitivePayload, account: String) -> Bool {
        fingerprints[account] == Self.fingerprint(payload)
    }

    func remember(_ payload: SensitivePayload, account: String) {
        fingerprints[account] = Self.fingerprint(payload)
    }

    func forget(account: String) {
        fingerprints.removeValue(forKey: account)
    }

    static func fingerprint(_ payload: SensitivePayload) -> String {
        var data = Data(payload.fullText.utf8)
        data.append(0x1f)
        data.append(contentsOf: payload.snippet.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps sensitive clipboard text out of `history.json` and the synced document.
final class SensitivePayloadStore {
    struct MaterializedItem {
        var item: ClipboardItem
        var rewrotePlaintext: Bool
    }

    static let unreadableStatus = "敏感内容无法从钥匙串读取"
    static let keychainWriteFailure = "敏感内容未能写入钥匙串"
    static let encodingFailure = "历史记录编码失败"

    private static let log = Logger(subsystem: "ClipFlow", category: "SensitivePayload")

    private init() {}

    static func protectsPayload(_ item: ClipboardItem) -> Bool {
        guard item.isSensitive, !item.isImage else { return false }
        return item.secretPayloadRef != nil || !item.fullText.isEmpty || !item.snippet.isEmpty
    }

    static func containsProtectedPlaintext(_ item: ClipboardItem) -> Bool {
        protectsPayload(item) && (!item.fullText.isEmpty || !item.snippet.isEmpty)
    }

    /// Drops anything that could carry a secret before it is written to the synced document.
    static func itemsForSyncedDocument(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { !$0.isSensitive && $0.secretPayloadRef == nil }
    }

    static func materialize(
        _ item: ClipboardItem,
        repository: SensitivePayloadRepository,
        digests: SensitivePayloadDigest
    ) throws -> MaterializedItem {
        guard protectsPayload(item) else {
            return MaterializedItem(item: item, rewrotePlaintext: false)
        }

        let account = item.secretPayloadRef ?? item.id.uuidString
        if !item.fullText.isEmpty || !item.snippet.isEmpty {
            let payload = SensitivePayload(fullText: item.fullText, snippet: item.snippet)
            try storeIfChanged(payload, account: account, repository: repository, digests: digests)
            var memory = item
            memory.secretPayloadRef = account
            memory.secretPayloadUnavailable = nil
            return MaterializedItem(item: memory, rewrotePlaintext: true)
        }

        var memory = item
        memory.secretPayloadRef = account
        do {
            if let payload = try repository.load(account: account) {
                memory.fullText = payload.fullText
                memory.snippet = payload.snippet
                memory.secretPayloadUnavailable = nil
                digests.remember(payload, account: account)
            } else {
                markUnreadable(&memory, account: account, reason: "missing")
            }
        } catch {
            markUnreadable(&memory, account: account, reason: String(describing: error))
        }
        return MaterializedItem(item: memory, rewrotePlaintext: false)
    }

    static func redactedForDisk(
        _ item: ClipboardItem,
        repository: SensitivePayloadRepository,
        digests: SensitivePayloadDigest
    ) throws -> ClipboardItem {
        guard protectsPayload(item) else { return item }

        let account = item.secretPayloadRef ?? item.id.uuidString
        // A failed read must not replace the Keychain item with empty text or the status string.
        if item.secretPayloadUnavailable != true {
            let payload = SensitivePayload(fullText: item.fullText, snippet: item.snippet)
            if !payload.fullText.isEmpty || !payload.snippet.isEmpty {
                try storeIfChanged(payload, account: account, repository: repository, digests: digests)
            }
        }

        var redacted = item
        redacted.fullText = ""
        redacted.snippet = ""
        redacted.secretPayloadRef = account
        redacted.secretPayloadUnavailable = nil
        return redacted
    }

    static func deleteStoredPayload(
        for item: ClipboardItem,
        repository: SensitivePayloadRepository,
        digests: SensitivePayloadDigest
    ) {
        guard item.secretPayloadRef != nil || protectsPayload(item) else { return }
        let account = item.secretPayloadRef ?? item.id.uuidString
        repository.delete(account: account)
        digests.forget(account: account)
    }

    private static func storeIfChanged(
        _ payload: SensitivePayload,
        account: String,
        repository: SensitivePayloadRepository,
        digests: SensitivePayloadDigest
    ) throws {
        guard !digests.matches(payload, account: account) else { return }
        try repository.save(payload, account: account)
        digests.remember(payload, account: account)
    }

    private static func markUnreadable(_ item: inout ClipboardItem, account: String, reason: String) {
        item.fullText = ""
        item.snippet = ""
        item.secretPayloadUnavailable = true
        log.error("Unable to read sensitive payload \(account, privacy: .public): \(reason, privacy: .public)")
    }
}

final class SensitivePayloadKeychain: SensitivePayloadRepository {
    struct KeychainError: Error {
        var status: OSStatus
    }

    static let service = "app.clipflow.sensitive-payload"

    func save(_ payload: SensitivePayload, account: String) throws {
        let data = try JSONEncoder().encode(payload)
        let query = Self.query(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError(status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func load(account: String) throws -> SensitivePayload? {
        var query = Self.query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(SensitivePayload.self, from: data)
    }

    func delete(account: String) {
        SecItemDelete(Self.query(account: account) as CFDictionary)
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Serializes history.json writes so a quit-time flush cannot be overwritten by a stale debounce.
final class HistoryFileWriter: @unchecked Sendable {
    enum Outcome: Equatable {
        case idle
        case wrote
        case failed
    }

    private let lock = NSLock()
    private let url: URL
    private var generation = 0
    private var pending: Data?

    init(url: URL) {
        self.url = url
    }

    func stage(_ data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pending = data
        return generation
    }

    func writeIfCurrent(_ generation: Int) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, let pending else { return .idle }
        do {
            try pending.write(to: url, options: [.atomic])
            if self.generation == generation {
                self.pending = nil
            }
            return .wrote
        } catch {
            return .failed
        }
    }

    func flush() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        guard let pending else { return .idle }
        let data = pending
        do {
            try data.write(to: url, options: [.atomic])
            self.pending = nil
            return .wrote
        } catch {
            return .failed
        }
    }

    func writeNow(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pending = nil
        try data.write(to: url, options: [.atomic])
    }
}
