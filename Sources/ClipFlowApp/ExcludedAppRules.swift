import Foundation

/// Turns the exclusion editor into the list ClipFlow actually stores.
enum ExcludedAppRules {
    static func lines(in rawValue: String) -> [String] {
        var seen = Set<String>()
        return rawValue.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    static func invalidLines(in bundleIDs: [String]) -> [String] {
        bundleIDs.filter { !isBundleID($0) }
    }

    /// Reverse-DNS style identifiers only. App names and blank-padded duplicates are not rules.
    static func isBundleID(_ value: String) -> Bool {
        guard value.count <= 255, value.utf8.allSatisfy({ $0 < 128 }) else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...20).contains(parts.count) else { return false }
        return parts.allSatisfy(isSegment)
    }

    static func normalizedText(_ bundleIDs: [String]) -> String {
        bundleIDs.joined(separator: "\n")
    }

    static func invalidMessage(_ lines: [String]) -> String {
        let shown = lines.prefix(3).joined(separator: "、")
        let suffix = lines.count > 3 ? " 等 \(lines.count) 行" : ""
        return "无法保存：\(shown)\(suffix) 不是有效的 Bundle ID。每行应类似 com.example.app。"
    }

    private static func isSegment(_ part: Substring) -> Bool {
        guard (1...63).contains(part.count), let first = part.first, let last = part.last else { return false }
        guard first.isNumber || first.isLetter, last.isNumber || last.isLetter else { return false }
        return part.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" }
    }
}
