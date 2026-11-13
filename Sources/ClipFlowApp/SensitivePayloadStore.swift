import Foundation
import Security

/// Keeps sensitive clipboard text out of `history.json` and the synced document.
/// The history file stores metadata plus `secretPayloadRef`. The text itself is a
/// Keychain item. Under tests, that item goes into a private keychain file so the
/// login keychain is never touched.
final class SensitivePayloadStore {
    struct Payload: Codable, Equatable, Sendable {
        var fullText: String
        var snippet: String
    }

    struct MaterializedItem {
        var item: ClipboardItem
        var rewrotePlaintext: Bool
    }

    struct StoreError: Error {
        var status: OSStatus
    }

    static let service = "app.clipflow.sensitive-payload"

    private final class KeychainState: @unchecked Sendable {
        let lock = NSLock()
        var ephemeralKeychain: SecKeychain?
        var didPrepareEphemeralKeychain = false
    }

    private static let state = KeychainState()

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

    static func materialize(_ item: ClipboardItem) throws -> MaterializedItem {
        guard protectsPayload(item) else {
            return MaterializedItem(item: item, rewrotePlaintext: false)
        }

        let account = item.secretPayloadRef ?? item.id.uuidString
        if !item.fullText.isEmpty || !item.snippet.isEmpty {
            try save(Payload(fullText: item.fullText, snippet: item.snippet), account: account)
            var memory = item
            memory.secretPayloadRef = account
            return MaterializedItem(item: memory, rewrotePlaintext: true)
        }

        var memory = item
        memory.secretPayloadRef = account
        if let payload = load(account: account) {
            memory.fullText = payload.fullText
            memory.snippet = payload.snippet
        }
        return MaterializedItem(item: memory, rewrotePlaintext: false)
    }

    static func redactedForDisk(_ item: ClipboardItem) throws -> ClipboardItem {
        guard protectsPayload(item) else { return item }

        let account = item.secretPayloadRef ?? item.id.uuidString
        // An empty in-memory payload must not overwrite a Keychain item we failed to read.
        if !item.fullText.isEmpty || !item.snippet.isEmpty {
            try save(Payload(fullText: item.fullText, snippet: item.snippet), account: account)
        }

        var redacted = item
        redacted.fullText = ""
        redacted.snippet = ""
        redacted.secretPayloadRef = account
        return redacted
    }

    static func deleteStoredPayload(for item: ClipboardItem) {
        guard item.secretPayloadRef != nil || protectsPayload(item) else { return }
        delete(account: item.secretPayloadRef ?? item.id.uuidString)
    }

    static func save(_ payload: Payload, account: String) throws {
        let data = try JSONEncoder().encode(payload)
        try perform { keychain in
            let query = try scopedQuery(account: account, keychain: keychain)
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess { return }
            if updateStatus != errSecItemNotFound {
                throw StoreError(status: updateStatus)
            }

            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError(status: addStatus)
            }
        }
    }

    static func load(account: String) -> Payload? {
        try? perform { keychain in
            var query = try scopedQuery(account: account, keychain: keychain)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return try JSONDecoder().decode(Payload.self, from: data)
        }
    }

    static func delete(account: String) {
        try? perform { keychain in
            let query = try scopedQuery(account: account, keychain: keychain)
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func perform<T>(_ body: (SecKeychain?) throws -> T) throws -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        return try body(keychainAssumingLocked())
    }

    private static func keychainAssumingLocked() -> SecKeychain? {
        guard isRunningTests else { return nil }
        if !state.didPrepareEphemeralKeychain {
            state.didPrepareEphemeralKeychain = true
            _ = KeychainFile.setUserInteractionAllowed(false)
            state.ephemeralKeychain = makeEphemeralKeychain()
        }
        return state.ephemeralKeychain
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private static func scopedQuery(account: String, keychain: SecKeychain?) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if isRunningTests {
            guard let keychain else { throw StoreError(status: errSecNotAvailable) }
            query[kSecUseKeychain as String] = keychain
            query[kSecMatchSearchList as String] = [keychain]
            return query
        }

        // The synchronizable attribute is left unset, so the item stays in the login keychain.
        return query
    }

    private static func makeEphemeralKeychain() -> SecKeychain? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipFlowSensitivePayload-\(ProcessInfo.processInfo.processIdentifier).keychain")
        try? FileManager.default.removeItem(at: url)

        let password = "clipflow-tests"
        var keychain: SecKeychain?
        let status = url.path.withCString { path in
            password.withCString { passwordPointer in
                KeychainFile.create(
                    path,
                    UInt32(password.lengthOfBytes(using: .utf8)),
                    passwordPointer,
                    false,
                    nil,
                    &keychain
                )
            }
        }
        guard status == errSecSuccess, let keychain else { return nil }

        _ = password.withCString { passwordPointer in
            KeychainFile.unlock(
                keychain,
                UInt32(password.lengthOfBytes(using: .utf8)),
                passwordPointer,
                true
            )
        }
        return keychain
    }

    /// File-keychain calls used so tests can store secrets without the login keychain.
    /// The Swift overlays are deprecated; these declarations bind the C symbols directly.
    private final class KeychainFile {
        @_silgen_name("SecKeychainSetUserInteractionAllowed")
        static func setUserInteractionAllowed(_ state: Bool) -> OSStatus

        @_silgen_name("SecKeychainCreate")
        static func create(
            _ pathName: UnsafePointer<CChar>?,
            _ passwordLength: UInt32,
            _ password: UnsafeRawPointer?,
            _ promptUser: Bool,
            _ initialAccess: SecAccess?,
            _ keychain: UnsafeMutablePointer<SecKeychain?>?
        ) -> OSStatus

        @_silgen_name("SecKeychainUnlock")
        static func unlock(
            _ keychain: SecKeychain?,
            _ passwordLength: UInt32,
            _ password: UnsafeRawPointer?,
            _ usePassword: Bool
        ) -> OSStatus

        private init() {}
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
