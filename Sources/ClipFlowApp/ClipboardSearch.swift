import Foundation

/// Matches a clipboard query against history.
///
/// Sensitive items match only safe metadata: the generic title, the source app,
/// and labels. The secret payload (`snippet` / `fullText`) is never compared,
/// and this type never reads the Keychain. Decoding a secret just to search it
/// would confirm the hidden value to anyone who can type.
final class ClipboardSearch {
    static func matches(_ item: ClipboardItem, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }

        if item.title.lowercased().contains(normalized)
            || item.sourceApp.lowercased().contains(normalized)
            || item.labels.joined(separator: " ").lowercased().contains(normalized) {
            return true
        }

        if item.isSensitive {
            return false
        }

        return item.snippet.lowercased().contains(normalized)
            || item.fullText.lowercased().contains(normalized)
    }

    private init() {}
}
