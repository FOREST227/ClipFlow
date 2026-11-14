import Foundation
import SwiftUI

enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text
    case code
    case link
    case secret
    case image

    var category: ClipCategory {
        switch self {
        case .text: .text
        case .code: .code
        case .link: .links
        case .secret: .protected
        case .image: .images
        }
    }

    /// Decorative wash. Text on a light row uses `labelColor`.
    var tint: Color { category.tint }

    func labelColor(for colorScheme: ColorScheme) -> Color {
        category.labelColor(for: colorScheme)
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .secret: "lock.shield"
        case .image: "photo.on.rectangle"
        }
    }

    var label: String {
        switch self {
        case .text: "文本"
        case .code: "代码"
        case .link: "链接"
        case .secret: "敏感"
        case .image: "图片"
        }
    }
}

enum PrivacyLevel: String, Codable, Sendable {
    case standard
    case masked
    case vault

    var label: String {
        switch self {
        case .standard: "普通"
        case .masked: "遮罩"
        case .vault: "保险箱"
        }
    }

    var color: Color {
        switch self {
        case .standard: Color(red: 0.36, green: 0.62, blue: 0.54)
        case .masked: Color(red: 0.89, green: 0.61, blue: 0.25)
        case .vault: Color(red: 0.79, green: 0.32, blue: 0.28)
        }
    }
}

struct ClipboardItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var snippet: String
    var fullText: String
    var sourceApp: String
    var sourceBundleID: String?
    var createdAt: Date
    var kind: ClipboardKind
    var privacy: PrivacyLevel
    var labels: [String]
    var pinned: Bool
    var localOnly: Bool
    var autoExpire: Bool
    var pasteTargets: [String]
    var expiresAt: Date?
    var imageFilename: String?
    var imageWidth: Double?
    var imageHeight: Double?
    var imageSignature: String?
    // Capture time. Pinning must not change this or `createdAt`; tombstones compare against it.
    var capturedAt: Date?
    // Last pin or unpin. Pinned items sort by this so pin order survives without moving `createdAt`.
    var pinnedAt: Date? = nil
    /// Keychain account for text that must not appear in history.json.
    var secretPayloadRef: String?
    /// Set when the Keychain entry could not be read. The secret text stays empty.
    var secretPayloadUnavailable: Bool? = nil
    /// Original `public.rtf` bytes. Nil when the copy had no formatted text, and on history written before rich restore.
    var rtfData: Data? = nil
    /// Original HTML bytes (`public.html` or the Apple HTML pasteboard type).
    var htmlData: Data? = nil
    /// `file://` URLs captured with the copy (`public.file-url`).
    var fileURLs: [String]? = nil

    var captureTimestamp: Date {
        capturedAt ?? createdAt
    }

    var timeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh-Hans")
        return formatter.localizedString(for: captureTimestamp, relativeTo: Date())
    }

    var isSensitive: Bool {
        kind == .secret || privacy != .standard || localOnly || autoExpire
    }

    func applyingExpirationPolicy(enabled: Bool) -> ClipboardItem {
        var item = self
        let sensitive = isSensitive
        // Expiry can fall back to createdAt, but that value must not be stored as
        // capturedAt. Pinning used to rewrite createdAt, and copying it here made
        // a legacy pin look like a capture newer than a deletion.
        let captured = capturedAt ?? createdAt
        item.localOnly = localOnly || sensitive
        item.autoExpire = sensitive && enabled
        item.expiresAt = item.autoExpire ? captured.addingTimeInterval(300) : nil
        return item
    }

    func isExpired(at now: Date = Date()) -> Bool {
        autoExpire && expiresAt.map { $0 <= now } == true
    }

    var isImage: Bool {
        kind == .image
    }

    var imageDimensionText: String? {
        guard let imageWidth, let imageHeight else { return nil }
        let width = max(Int(imageWidth.rounded()), 1)
        let height = max(Int(imageHeight.rounded()), 1)
        return "\(width) × \(height)"
    }

    var primaryURL: URL? {
        guard kind == .link else { return nil }

        let sourceText = (fullText.isEmpty ? snippet : fullText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return nil }

        let range = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
        if let match = Self.linkDetector?.firstMatch(in: sourceText, options: [], range: range),
           let url = match.url {
            return url
        }

        return URL(string: sourceText)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

/// Pinned rows stay in pin order. Everything else stays in capture order.
final class ClipboardItemOrder {
    private init() {}

    static func isBefore(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.pinned != rhs.pinned {
            return lhs.pinned
        }
        let left = lhs.pinned ? pinTimestamp(of: lhs) : lhs.captureTimestamp
        let right = rhs.pinned ? pinTimestamp(of: rhs) : rhs.captureTimestamp
        if left != right {
            return left > right
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func pinTimestamp(of item: ClipboardItem) -> Date {
        item.pinnedAt ?? item.createdAt
    }
}
