import Foundation

/// How many unpinned clipboard rows history may keep.
///
/// Pinned rows are outside the quota: they are never removed to satisfy it,
/// and they do not reduce how many unpinned rows can stay.
final class HistoryRetention {
    static let choices = [80, 200, 500, 1000]
    static let defaultLimit = 80
    static let confirmButtonTitle = "删除这些记录"
    static let cancelButtonTitle = "取消"

    private init() {}

    static func normalized(_ value: Int?) -> Int {
        guard let value, choices.contains(value) else { return defaultLimit }
        return value
    }

    /// Lowering the limit asks before it deletes. Raising it, or lowering it
    /// while every unpinned row still fits, applies immediately.
    static func needsConfirmation(currentLimit: Int, proposedLimit: Int, removalCount: Int) -> Bool {
        proposedLimit < currentLimit && removalCount > 0
    }

    static func confirmationMessage(removalCount: Int) -> String {
        "将删除最早的 \(removalCount) 条未置顶记录。置顶内容会保留。"
    }

    static func appliedStatus(limit: Int, removedCount: Int) -> String {
        if removedCount > 0 {
            return "已保留最近 \(limit) 条未置顶记录，并删除最早的 \(removedCount) 条"
        }
        return "已将历史保留条数设为 \(limit)"
    }

    static func removalCount(in items: [ClipboardItem], limit: Int) -> Int {
        partition(items, limit: limit).removed.count
    }

    /// Newest unpinned rows fill `limit`. Every pinned row is kept ahead of them.
    static func partition(
        _ items: [ClipboardItem],
        limit: Int
    ) -> (kept: [ClipboardItem], removed: [ClipboardItem]) {
        let ordered = items.sorted(by: ClipboardItemOrder.isBefore)
        let pinned = ordered.filter(\.pinned)
        let unpinned = ordered.filter { !$0.pinned }
        let keptUnpinned = Array(unpinned.prefix(max(0, limit)))
        var keptIDs = Set(pinned.map(\.id))
        keptIDs.formUnion(keptUnpinned.map(\.id))
        let removed = ordered.filter { !keptIDs.contains($0.id) }
        return (pinned + keptUnpinned, removed)
    }
}
