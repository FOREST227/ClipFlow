import Foundation

/// Reusable plain text that is not part of clipboard history.
///
/// History trimming and sensitive expiry never remove these. `localOnly` is set
/// when the text came from a sensitive history item: it stays on this Mac and is
/// left out of 文稿 sync.
struct SavedSnippet: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var category: String?
    var createdAt: Date
    var updatedAt: Date
    /// Lower values appear first.
    var order: Int
    var localOnly: Bool
}

enum SnippetSaveOutcome: Equatable {
    case saved(SavedSnippet)
    case needsSensitiveConfirmation
    case unavailable
}

struct SensitiveSnippetPrompt: Identifiable, Equatable {
    let itemID: UUID
    var id: UUID { itemID }
}

/// Rules for creating, searching, and ordering snippets.
final class SnippetLibrary {
    private init() {}

    static let sensitiveConfirmationTitle = "将敏感内容存为片段？"
    static let sensitiveConfirmationMessage = "这条内容已标记为敏感。只有确认后才会保存。保存后以明文留在本机，不会自动过期，也不会写入文稿同步。"
    static let emptyBodyStatus = "片段内容不能为空"
    static let unavailableStatus = "这条内容没有可保存的文本"
    static let savedStatus = "已存为片段"
    static let savedSensitiveStatus = "已将敏感内容存为仅本机片段"
    static let updatedStatus = "已更新片段"
    static let deletedStatus = "已删除片段"

    static func hasBody(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func normalizedTitle(_ title: String, body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(80))
        }
        return Self.title(fromBody: body)
    }

    static func normalizedCategory(_ category: String?) -> String? {
        let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(40))
    }

    static func title(fromBody body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "未命名片段" }
        if trimmed.count <= 24 { return trimmed }
        return String(trimmed.prefix(24)) + "…"
    }

    static func plainText(for item: ClipboardItem) -> String? {
        if item.secretPayloadUnavailable == true { return nil }
        if item.isImage { return nil }
        guard hasBody(item.fullText) else { return nil }
        return item.fullText
    }

    static func canSave(_ item: ClipboardItem) -> Bool {
        plainText(for: item) != nil
    }

    static func make(
        id: UUID = UUID(),
        title: String,
        body: String,
        category: String?,
        order: Int,
        localOnly: Bool,
        now: Date = Date()
    ) -> SavedSnippet {
        SavedSnippet(
            id: id,
            title: normalizedTitle(title, body: body),
            body: body,
            category: normalizedCategory(category),
            createdAt: now,
            updatedAt: now,
            order: order,
            localOnly: localOnly
        )
    }

    static func accessibilityLabel(for snippet: SavedSnippet) -> String {
        var parts = [snippet.title, "片段"]
        if let category = snippet.category, !category.isEmpty {
            parts.append(category)
        }
        if snippet.localOnly {
            parts.append("仅本机")
        }
        return parts.joined(separator: "，")
    }

    static func matches(_ snippet: SavedSnippet, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if snippet.title.lowercased().contains(normalized) { return true }
        if snippet.body.lowercased().contains(normalized) { return true }
        if let category = snippet.category, category.lowercased().contains(normalized) { return true }
        return false
    }

    static func sorted(_ snippets: [SavedSnippet]) -> [SavedSnippet] {
        snippets.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// `destination` uses the same index as `Array.move(fromOffsets:toOffset:)`.
    static func moving(
        _ snippets: [SavedSnippet],
        from offsets: IndexSet,
        to destination: Int,
        now: Date
    ) -> [SavedSnippet] {
        var ordered = sorted(snippets)
        guard !offsets.isEmpty, offsets.allSatisfy({ ordered.indices.contains($0) }) else { return ordered }
        guard destination >= 0, destination <= ordered.count else { return ordered }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        return normalizingOrder(ordered, now: now)
    }

    static func moving(_ snippets: [SavedSnippet], id: UUID, by direction: Int, now: Date) -> [SavedSnippet] {
        let ordered = sorted(snippets)
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return ordered }
        if direction < 0 && index == 0 { return ordered }
        if direction > 0 && index == ordered.count - 1 { return ordered }
        let destination = direction > 0 ? index + 2 : index - 1
        return moving(ordered, from: IndexSet(integer: index), to: destination, now: now)
    }

    static func normalizingOrder(_ snippets: [SavedSnippet], now: Date) -> [SavedSnippet] {
        snippets.enumerated().map { index, snippet in
            var snippet = snippet
            if snippet.order != index {
                snippet.order = index
                snippet.updatedAt = now
            }
            return snippet
        }
    }
}
