import Combine

/// Selection changes are independent of clipboard content and settings.
@MainActor
final class HistorySelection: ObservableObject {
    @Published var itemID: ClipboardItem.ID?
    /// Keyboard navigation asks the owning list to scroll; pointer selection never does.
    let revealRequests = PassthroughSubject<ClipboardItem.ID, Never>()

    func select(_ id: ClipboardItem.ID, reveal: Bool) {
        if itemID != id { itemID = id }
        if reveal { revealRequests.send(id) }
    }

    /// Moves within `ids`, clamping at both ends. Returns the newly selected id.
    @discardableResult
    func move(by offset: Int, in ids: [ClipboardItem.ID]) -> ClipboardItem.ID? {
        guard !ids.isEmpty else { return nil }
        let next: Int
        if let itemID, let current = ids.firstIndex(of: itemID) {
            next = min(max(current + offset, 0), ids.count - 1)
        } else {
            next = offset < 0 ? ids.count - 1 : 0
        }
        select(ids[next], reveal: true)
        return ids[next]
    }
}
