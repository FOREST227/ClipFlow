import Combine
import Foundation

enum LibraryViewMode: String, Codable, CaseIterable, Sendable {
    case deck
    case list

    var label: String {
        switch self {
        case .deck: "叠卡"
        case .list: "清单"
        }
    }

    var icon: String {
        switch self {
        case .deck: "rectangle.stack"
        case .list: "list.bullet"
        }
    }
}

enum QuickPastePresentationMode: String, Codable, CaseIterable, Sendable {
    case fan
    case list
}

/// Sequential FIFO collector ("Paste Stack · ① → ② → ③") kept independent of
/// `ClipFlowStore.objectWillChange` so selection and queue interactions stay lightweight.
@MainActor
final class PasteStackState: ObservableObject {
    @Published var autoCollectEnabled = false
    @Published private(set) var queuedIDs: [UUID] = []
    let maxCapacity = 12

    func contains(_ id: UUID) -> Bool {
        queuedIDs.contains(id)
    }

    func enqueue(_ id: UUID) {
        guard !queuedIDs.contains(id) else { return }
        if queuedIDs.count >= maxCapacity {
            queuedIDs.removeFirst()
        }
        queuedIDs.append(id)
    }

    func toggle(_ id: UUID) {
        if let index = queuedIDs.firstIndex(of: id) {
            queuedIDs.remove(at: index)
        } else {
            enqueue(id)
        }
    }

    func remove(_ id: UUID) {
        queuedIDs.removeAll { $0 == id }
    }

    func clear() {
        guard !queuedIDs.isEmpty else { return }
        queuedIDs.removeAll()
    }

    func prune(validIDs: Set<UUID>) {
        let filtered = queuedIDs.filter { validIDs.contains($0) }
        if filtered != queuedIDs {
            queuedIDs = filtered
        }
    }

    func queuedItems(from items: [ClipboardItem]) -> [ClipboardItem] {
        let byID = Dictionary(uniqueKeysWithValues: items.filter { !$0.isExpired() }.map { ($0.id, $0) })
        return queuedIDs.compactMap { byID[$0] }
    }

    @discardableResult
    func popNext(from items: [ClipboardItem]) -> ClipboardItem? {
        let byID = Dictionary(uniqueKeysWithValues: items.filter { !$0.isExpired() }.map { ($0.id, $0) })
        while !queuedIDs.isEmpty {
            let nextID = queuedIDs.removeFirst()
            if let item = byID[nextID] {
                return item
            }
        }
        return nil
    }
}
