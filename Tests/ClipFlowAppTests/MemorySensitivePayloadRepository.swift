import Foundation
@testable import ClipFlowApp

final class MemorySensitivePayloadRepository: SensitivePayloadRepository {
    private var storage: [String: SensitivePayload] = [:]
    private(set) var saveCount = 0
    var loadFailure: Error?

    func save(_ payload: SensitivePayload, account: String) throws {
        saveCount += 1
        storage[account] = payload
    }

    func load(account: String) throws -> SensitivePayload? {
        if let loadFailure { throw loadFailure }
        return storage[account]
    }

    func delete(account: String) {
        storage.removeValue(forKey: account)
    }
}

struct SensitivePayloadTestFailure: Error {}
