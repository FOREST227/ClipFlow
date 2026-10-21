import ApplicationServices
import CryptoKit
import Foundation
import ImageIO
import ServiceManagement
import SwiftUI

enum ClipCategory: String, CaseIterable, Identifiable {
    case all
    case quickPaste
    case smartStacks
    case code
    case links
    case protected

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部内容"
        case .quickPaste: "快速粘贴"
        case .smartStacks: "智能分组"
        case .code: "代码片段"
        case .links: "链接资源"
        case .protected: "隐私保护"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "按时间和来源整理的本地剪贴历史"
        case .quickPaste: "置顶内容与高置信推荐"
        case .smartStacks: "按语义、来源和复用行为自动归类"
        case .code: "命令、代码和终端可直接使用的文本"
        case .links: "网址、参考资料与可分享内容"
        case .protected: "遮罩显示、本地保存或自动过期的条目"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .quickPaste: "cursorarrow.click"
        case .smartStacks: "sparkles.rectangle.stack"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .links: "link"
        case .protected: "lock.shield"
        }
    }

    var tint: Color {
        switch self {
        case .all: Color(red: 0.34, green: 0.58, blue: 0.95)
        case .quickPaste: Color(red: 0.92, green: 0.58, blue: 0.23)
        case .smartStacks: Color(red: 0.39, green: 0.72, blue: 0.68)
        case .code: Color(red: 0.42, green: 0.66, blue: 0.98)
        case .links: Color(red: 0.29, green: 0.62, blue: 0.86)
        case .protected: Color(red: 0.83, green: 0.35, blue: 0.31)
        }
    }
}

enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text
    case code
    case link
    case secret
    case image

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
    // Separate capture time from the ordering timestamp changed by pinning.
    var capturedAt: Date?

    var timeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh-Hans")
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    var isSensitive: Bool {
        kind == .secret || privacy != .standard || localOnly || autoExpire
    }

    func applyingExpirationPolicy(enabled: Bool) -> ClipboardItem {
        var item = self
        let sensitive = isSensitive
        item.capturedAt = capturedAt ?? createdAt
        item.localOnly = localOnly || sensitive
        item.autoExpire = sensitive && enabled
        item.expiresAt = item.autoExpire ? item.capturedAt?.addingTimeInterval(300) : nil
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

struct FlowMetric: Identifiable {
    let id = UUID()
    let value: String
    let title: String
    let detail: String
    let icon: String
    let tint: Color
}

struct IntegrationPill: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let detail: String
    let tint: Color
}

enum ClipFlowPermissionStatus {
    case granted
    case needsAttention
    case notRequired

    var label: String {
        switch self {
        case .granted:
            return "正常"
        case .needsAttention:
            return "需要处理"
        case .notRequired:
            return "当前无需"
        }
    }

    var tint: Color {
        switch self {
        case .granted:
            return Color(red: 0.34, green: 0.67, blue: 0.53)
        case .needsAttention:
            return ClipCategory.protected.tint
        case .notRequired:
            return ClipCategory.all.tint
        }
    }
}

struct ClipFlowPermissionItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
    let status: ClipFlowPermissionStatus
}

struct ClipFlowPermissionReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let items: [ClipFlowPermissionItem]

    var needsAttention: Bool {
        items.contains { $0.status == .needsAttention }
    }
}

enum ClipboardClassifier {
    static func kind(for text: String) -> ClipboardKind {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()
        let codeLike = looksLikeCode(normalized)
        let secretLike = looksLikeSecretPayload(normalized, lowered: lowered, codeLike: codeLike)

        if secretLike {
            return .secret
        }

        if looksLikeURL(normalized) && !codeLike {
            return .link
        }

        if codeLike {
            return .code
        }

        return .text
    }

    static func privacy(for text: String, kind: ClipboardKind, sourceBundleID: String?, autoProtectSecrets: Bool) -> PrivacyLevel {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()
        let codeLike = kind == .code || looksLikeCode(normalized)
        let sensitiveSource = (sourceBundleID.map(sensitiveSourceBundleIDs.contains) ?? false)
        let secretLike = looksLikeSecretPayload(normalized, lowered: lowered, codeLike: codeLike)

        if kind == .secret || (autoProtectSecrets && secretLike) || sensitiveSource {
            return .vault
        }

        if kind == .code && looksLikeOperationalCommand(lowered) {
            return .masked
        }

        return .standard
    }

    static func labels(for text: String, kind: ClipboardKind, sourceApp: String, privacy: PrivacyLevel) -> [String] {
        var labels: [String] = []
        let lowered = text.lowercased()

        labels.append(sourceApp)

        switch kind {
        case .text:
            if text.count > 120 {
                labels.append("长文本")
            } else {
                labels.append("便签")
            }
        case .code:
            labels.append(isLikelyShellCommand(text, lowered: lowered) ? "命令" : "代码")
            if lowered.contains("swift") || lowered.contains("import swiftui") || lowered.contains("import foundation") {
                labels.append("Swift")
            }
            if lowered.contains("python") || lowered.contains("def ") || lowered.contains("print(") {
                labels.append("Python")
            }
            if lowered.contains("select ") || lowered.contains("insert into") || lowered.contains("update ") || lowered.contains("delete from") {
                labels.append("SQL")
            }
            if lowered.contains("<div") || lowered.contains("</") || lowered.contains("/>") || lowered.contains("<html") {
                labels.append("HTML")
            }
            if looksLikeJSON(text) {
                labels.append("JSON")
            }
            if isLikelyShellCommand(text, lowered: lowered) {
                labels.append("终端")
            }
        case .link:
            labels.append("参考")
            if lowered.contains("figma") {
                labels.append("设计")
            }
            if lowered.contains("github") || lowered.contains("developer.apple.com") {
                labels.append("文档")
            }
        case .secret:
            labels.append("敏感")
            if lowered.range(of: #"\b\d{4,8}\b"#, options: .regularExpression) != nil {
                labels.append("验证码")
            }
        case .image:
            labels.append("图片")
        }

        if privacy != .standard {
            labels.append("受保护")
        }

        return Array(NSOrderedSet(array: labels)) as? [String] ?? labels
    }

    static func pasteTargets(for kind: ClipboardKind) -> [String] {
        switch kind {
        case .text:
            return ["备忘录", "邮件", "微信/Slack"]
        case .code:
            return ["Xcode", "终端", "Cursor"]
        case .link:
            return ["Slack", "邮件", "信息"]
        case .secret:
            return ["浏览器", "密码管理器", "终端"]
        case .image:
            return ["备忘录", "设计工具", "聊天窗口"]
        }
    }

    static func makeItem(text: String, sourceApp: String, sourceBundleID: String?, autoProtectSecrets: Bool, existingItem: ClipboardItem?) -> ClipboardItem {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind(for: normalized)
        let privacy = privacy(for: normalized, kind: kind, sourceBundleID: sourceBundleID, autoProtectSecrets: autoProtectSecrets)
        let localOnly = privacy != .standard
        let autoExpire = privacy != .standard
        let capturedAt = Date()
        let title = kind.label
        let snippet = makeSnippet(for: normalized)
        let labels = labels(for: normalized, kind: kind, sourceApp: sourceApp, privacy: privacy)
        let pasteTargets = pasteTargets(for: kind)

        return ClipboardItem(
            id: existingItem?.id ?? UUID(),
            title: title,
            snippet: snippet,
            fullText: text,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            createdAt: capturedAt,
            kind: kind,
            privacy: privacy,
            labels: labels,
            pinned: existingItem?.pinned ?? false,
            localOnly: localOnly,
            autoExpire: autoExpire,
            pasteTargets: pasteTargets,
            expiresAt: autoExpire ? capturedAt.addingTimeInterval(300) : nil,
            imageFilename: nil,
            imageWidth: nil,
            imageHeight: nil,
            imageSignature: nil,
            capturedAt: capturedAt
        )
    }

    static func makeImageItem(
        imageFilename: String,
        imageSignature: String,
        imageSize: CGSize,
        sourceApp: String,
        sourceBundleID: String?,
        existingItem: ClipboardItem?
    ) -> ClipboardItem {
        let privacy = imagePrivacy(sourceBundleID: sourceBundleID)
        let capturedAt = Date()

        return ClipboardItem(
            id: existingItem?.id ?? UUID(),
            title: makeImageTitle(for: imageSize),
            snippet: makeImageSnippet(for: imageSize),
            fullText: "",
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            createdAt: capturedAt,
            kind: .image,
            privacy: privacy,
            labels: imageLabels(for: imageSize, sourceApp: sourceApp, privacy: privacy),
            pinned: existingItem?.pinned ?? false,
            localOnly: privacy != .standard,
            autoExpire: privacy != .standard,
            pasteTargets: pasteTargets(for: .image),
            expiresAt: privacy != .standard ? capturedAt.addingTimeInterval(300) : nil,
            imageFilename: imageFilename,
            imageWidth: imageSize.width,
            imageHeight: imageSize.height,
            imageSignature: imageSignature,
            capturedAt: capturedAt
        )
    }

    static let sensitiveSourceBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop"
    ]

    private static func looksLikeURL(_ text: String) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        return detector.firstMatch(in: text, options: [], range: range)?.url != nil
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if trimmed.hasPrefix("```") || trimmed.contains("\n```") {
            return true
        }

        if looksLikeJSON(trimmed) {
            return true
        }

        if isLikelyShellCommand(trimmed, lowered: lowered) || looksLikeSQL(trimmed, lowered: lowered) {
            return true
        }

        var score = 0

        if lines.count >= 2 {
            score += 1
        }

        let keywordHits = codeKeywordPatterns.filter {
            lowered.range(of: $0, options: .regularExpression) != nil
        }.count
        score += min(keywordHits, 3)

        let symbolHits = codeSymbolPatterns.filter {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }.count
        score += min(symbolHits, 2)

        let codeLikeLines = lines.filter { lineLooksLikeCode($0) }.count
        if codeLikeLines >= max(1, lines.count / 2) {
            score += 2
        }

        if lines.count == 1,
           trimmed.range(of: #"^(?:<[^>]+>.*</[^>]+>|[a-z_][a-z0-9_]*\s*\(.*\)|[a-z_][a-z0-9_]*\s*=\s*.+)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 2
        }

        return score >= (lines.count <= 1 ? 3 : 4)
    }

    private static func looksLikeOperationalCommand(_ lowered: String) -> Bool {
        lowered.contains("ssh ")
            || lowered.contains("export ")
            || lowered.contains("token")
            || lowered.contains("api_key")
            || lowered.contains("secret")
    }

    private static func looksLikeSecretPayload(_ text: String, lowered: String, codeLike: Bool) -> Bool {
        if lowered.range(of: #"^\d{4,8}$"#, options: .regularExpression) != nil {
            return true
        }

        let hardSecretPatterns = [
            #"\b(?:sk|rk)-[a-z0-9]{16,}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#,
            #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            #"\beyJ[a-zA-Z0-9_\-]{10,}\.[a-zA-Z0-9_\-]{10,}\.[a-zA-Z0-9_\-]{10,}\b"#,
            #"\bssh-rsa\s+[A-Za-z0-9+/=]{40,}"#,
            #"\bAKIA[0-9A-Z]{16}\b"#
        ]

        if hardSecretPatterns.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }

        if looksLikeHardcodedCredential(text, lowered: lowered, codeLike: codeLike) {
            return true
        }

        if codeLike {
            return false
        }

        let softSecretMarkers = [
            "otp", "verification code", "one-time code", "password",
            "passcode", "api_key", "secret", "token", "bearer ", "private key"
        ]

        if text.count <= 160, softSecretMarkers.contains(where: lowered.contains) {
            return true
        }

        if lowered.range(of: #"[a-z0-9_\-]{24,}"#, options: .regularExpression) != nil,
           !lowered.contains(" ") {
            return true
        }

        return false
    }

    private static func imagePrivacy(sourceBundleID: String?) -> PrivacyLevel {
        let sensitiveSource = sourceBundleID.map(sensitiveSourceBundleIDs.contains) ?? false
        return sensitiveSource ? .vault : .standard
    }

    private static func makeImageTitle(for size: CGSize) -> String {
        "图片 \(formattedDimensionLabel(for: size))"
    }

    private static func makeImageSnippet(for size: CGSize) -> String {
        "图片内容 · \(formattedDimensionLabel(for: size))"
    }

    private static func imageLabels(for size: CGSize, sourceApp: String, privacy: PrivacyLevel) -> [String] {
        var labels = [sourceApp, "图片"]

        if size.width > size.height {
            labels.append("横向")
        } else if size.height > size.width {
            labels.append("纵向")
        } else {
            labels.append("方图")
        }

        if max(size.width, size.height) >= 2_000 {
            labels.append("高清")
        }

        if privacy != .standard {
            labels.append("受保护")
        }

        return Array(NSOrderedSet(array: labels)) as? [String] ?? labels
    }

    private static func formattedDimensionLabel(for size: CGSize) -> String {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        return "\(width) × \(height)"
    }

    private static func makeTitle(for text: String, kind: ClipboardKind) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? text

        let compact = firstLine.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let prefix = String(compact.prefix(54))

        if compact.count <= 54 {
            return prefix
        }

        switch kind {
        case .secret:
            return "受保护内容"
        case .image:
            return "图片"
        default:
            return "\(prefix)…"
        }
    }

    private static func makeSnippet(for text: String) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let prefix = String(compact.prefix(120))
        return compact.count > 120 ? "\(prefix)…" : prefix
    }

    private static func isLikelyShellCommand(_ text: String, lowered: String) -> Bool {
        let commandRegex = #"^(?:[$>%#]\s*)?(?:git|ssh|scp|brew|npm|pnpm|yarn|npx|node|python|python3|pip|pip3|curl|wget|docker|kubectl|defaults|chmod|chown|find|grep|sed|awk|cat|ls|cd|pwd|cp|mv|rm|mkdir|touch|swift|xcodebuild|pod|bundle|rails)\b"#
        if lowered.range(of: commandRegex, options: .regularExpression) != nil {
            return true
        }

        return text.contains("\n$ ")
            || text.contains("\n% ")
            || text.contains("\n> ")
    }

    private static func looksLikeSQL(_ text: String, lowered: String) -> Bool {
        let sqlRegex = #"^(?:with|select|insert\s+into|update|delete\s+from|create\s+table|alter\s+table|drop\s+table)\b"#
        return lowered.range(of: sqlRegex, options: .regularExpression) != nil
            || text.range(of: #"\bfrom\b.+\bwhere\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard text.first == "{" || text.first == "[" else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func looksLikeHardcodedCredential(_ text: String, lowered: String, codeLike: Bool) -> Bool {
        if codeLike {
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains(where: lineLooksLikeHardcodedCredential)
        }

        let assignmentPatterns = [
            #"(?:api[_\- ]?key|access[_\- ]?token|refresh[_\- ]?token|client[_\- ]?secret|password|passcode|bearer)\s*[:=]\s*[\"']?[A-Za-z0-9_\-\/+=]{8,}"#,
            #"(?:authorization)\s*[:=]\s*[\"']?bearer\s+[A-Za-z0-9_\-\/+=\.]{8,}"#
        ]

        if assignmentPatterns.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }

        return text.range(of: #"(?:api[_\- ]?key|token|secret|password)\s*[:=]\s*`[^`]{8,}`"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func lineLooksLikeHardcodedCredential(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        guard !lineLooksLikeRegexPatternDefinition(line) else { return false }

        let inlineSecretAssignmentPatterns = [
            #"\b(?:api[_\- ]?key|access[_\- ]?token|refresh[_\- ]?token|client[_\- ]?secret|password|passcode)\b.{0,24}(?:=|:)\s*(?:\"[^\"]{8,}\"|'[^']{8,}'|`[^`]{8,}`)"#,
            #"\b(?:authorization|bearer)\b.{0,24}(?:=|:)\s*(?:\"bearer\s+[A-Za-z0-9_\-\/+=\.]{8,}\"|'bearer\s+[A-Za-z0-9_\-\/+=\.]{8,}'|bearer\s+[A-Za-z0-9_\-\/+=\.]{8,})"#,
            #"^(?:export\s+)?(?:api[_\- ]?key|token|secret|password)\s*=\s*[A-Za-z0-9_\-\/+=\.]{12,}$"#
        ]

        return inlineSecretAssignmentPatterns.contains {
            line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func lineLooksLikeRegexPatternDefinition(_ line: String) -> Bool {
        let lowered = line.lowercased()

        if lowered.contains("options: .regularexpression") || lowered.contains("nsregularexpression") {
            return true
        }

        let regexMarkers = [
            #"\"#, #"\d"#, #"\w"#, #"\b"#, #"\s"#,
            "(?:", "(?=", "(?!", "[a-z", "[0-9", "[^", "{8,}", "{10,}", ".*", ".+",
            #"range(of: #""#, #"try? regularexpression"#, #"checkingtype.link"#, #"detector.firstmatch"#
        ]

        return regexMarkers.contains { line.contains($0) }
    }

    private static func lineLooksLikeCode(_ line: String) -> Bool {
        let lowered = line.lowercased()

        if isLikelyShellCommand(line, lowered: lowered) || looksLikeSQL(line, lowered: lowered) {
            return true
        }

        if lowered.range(of: #"^(?:func|let|var|const|import|from|def|class|struct|enum|interface|public|private|protected|return|if|else|for|while|switch|case)\b"#, options: .regularExpression) != nil {
            return true
        }

        return line.range(of: #"[{}[\]();:=<>]|=>|->|::|</|/>"#, options: .regularExpression) != nil
    }

    private static let codeKeywordPatterns = [
        #"\bfunc\b"#,
        #"\blet\b"#,
        #"\bvar\b"#,
        #"\bconst\b"#,
        #"\bimport\b"#,
        #"\bfrom\b"#,
        #"\bdef\b"#,
        #"\bclass\b"#,
        #"\bstruct\b"#,
        #"\benum\b"#,
        #"\binterface\b"#,
        #"\bpublic\b"#,
        #"\bprivate\b"#,
        #"\breturn\b"#,
        #"\bif\s*\("#,
        #"\bfor\s*\("#,
        #"\bwhile\s*\("#,
        #"\bselect\b"#,
        #"\bcreate\s+table\b"#,
        #"\b<!doctype\b"#,
        #"<[a-z][^>]*>"#
    ]

    private static let codeSymbolPatterns = [
        #"[{}]"#,
        #"\=\>"#,
        #"\-\>"#,
        #"\=\s*[^=]"#,
        #";"#,
        #"</"#,
        #"/>"#,
        #"\[[^\]]+\]"#
    ]
}

@MainActor
final class ClipFlowStore: ObservableObject {
    static let shared = ClipFlowStore()

    @Published var searchText = "" {
        didSet { ensureSelectionStillValid() }
    }
    @Published var selectedCategory: ClipCategory = .all {
        didSet { ensureSelectionStillValid() }
    }
    @Published var selectedItemID: ClipboardItem.ID?
    @Published var capturePaused: Bool {
        didSet { defaults.set(capturePaused, forKey: Keys.capturePaused) }
    }
    @Published var appearanceMode: ClipFlowAppearance {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }
    @Published var autoProtectSecrets: Bool {
        didSet { defaults.set(autoProtectSecrets, forKey: Keys.autoProtectSecrets) }
    }
    @Published var sensitiveAutoExpireEnabled: Bool {
        didSet {
            defaults.set(sensitiveAutoExpireEnabled, forKey: Keys.sensitiveAutoExpireEnabled)
            items = items.map { $0.applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled) }
            purgeExpired()
        }
    }
    @Published var launchAtLogin: Bool
    @Published var menuQuickPasteModeEnabled: Bool {
        didSet { defaults.set(menuQuickPasteModeEnabled, forKey: Keys.menuQuickPasteModeEnabled) }
    }
    @Published var iCloudSyncEnabled: Bool
    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }
    @Published var revealedItemIDs: Set<UUID> = []
    @Published var lastCaptureStatus: String = "准备就绪"
    @Published private(set) var iCloudSyncPhase: ClipFlowCloudSyncPhase = .disabled
    @Published private(set) var iCloudLastSyncedAt: Date?
    @Published var startupPermissionReport: ClipFlowPermissionReport?
    @Published private(set) var quickPasteShortcut: ClipFlowShortcut
    @Published var shortcutError: String?
    @Published private(set) var isRecordingShortcut = false
    var registerShortcut: ((ClipFlowShortcut) -> String?)?
    var suspendShortcut: (() -> Void)?
    @Published private(set) var historyLoadError: String?

    @Published private(set) var items: [ClipboardItem] = [] {
        didSet {
            itemsRevision += 1
            schedulePersistItems()
            ensureSelectionStillValid()
            if iCloudSyncEnabled && !isApplyingCloudSnapshot {
                scheduleICloudSync()
            }
        }
    }

    let integrations = ClipFlowCatalog.integrations
    let maxItems = 80

    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let persistenceQueue = DispatchQueue(label: "ClipFlow.persistence", qos: .utility)
    private let imagePreviewCache = NSCache<NSString, NSImage>()
    private let historyURL: URL
    private let imagesDirectoryURL: URL
    private let cloudSyncCoordinator: ClipFlowCloudSyncCoordinator
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var localSyncTombstones: [UUID: Date] = [:] {
        didSet { persistLocalSyncTombstones() }
    }
    private var cloudSyncLoopTask: Task<Void, Never>?
    private var pendingCloudSyncTask: Task<Void, Never>?
    private let cloudSyncWorker = ClipFlowCloudSyncWorker()
    private var activeCloudSyncTask: Task<Void, Never>?
    private var cloudSyncGeneration = 0
    private var syncRequestedWhileRunning = false
    private var isApplyingCloudSnapshot = false
    private var itemsRevision = 0

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard, syncDirectory: URL? = nil) {
        self.defaults = defaults
        appearanceMode = ClipFlowAppearance.load(from: defaults)
        quickPasteShortcut = ClipFlowShortcut.load(from: defaults)
        let appSupport = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipFlow", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        historyURL = appSupport.appendingPathComponent("history.json")
        imagesDirectoryURL = appSupport.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
        imagePreviewCache.countLimit = maxItems + 20
        imagePreviewCache.totalCostLimit = 64 * 1024 * 1024
        cloudSyncCoordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: imagesDirectoryURL, documentsDirectoryURL: syncDirectory)

        capturePaused = defaults.object(forKey: Keys.capturePaused) as? Bool ?? false
        autoProtectSecrets = defaults.object(forKey: Keys.autoProtectSecrets) as? Bool ?? true
        sensitiveAutoExpireEnabled = defaults.object(forKey: Keys.sensitiveAutoExpireEnabled) as? Bool ?? true
        launchAtLogin = Self.currentLaunchAtLoginState()
        menuQuickPasteModeEnabled = defaults.object(forKey: Keys.menuQuickPasteModeEnabled) as? Bool ?? true
        iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSyncEnabled) as? Bool ?? false
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? Self.defaultExcludedBundleIDs
        iCloudLastSyncedAt = defaults.object(forKey: Keys.iCloudLastSyncedAt) as? Date
        localSyncTombstones = Self.decodeTombstones(from: defaults.data(forKey: Keys.iCloudSyncTombstones))
        items = loadItems()
        cleanupOrphanedImageFiles()
        selectedItemID = items.first?.id
    }

    func start() {
        schedulePersistItems()
        runStartupPermissionCheck()
        if iCloudSyncEnabled {
            Task { [weak self] in
                self?.enableICloudSyncIfPossible(announceResult: false)
            }
        }
    }

    @discardableResult
    func setQuickPasteShortcut(_ shortcut: ClipFlowShortcut) -> Bool {
        if let error = shortcut.validationError {
            shortcutError = error
            return false
        }
        guard let registerShortcut else {
            shortcutError = "快捷键服务尚未就绪，请重启应用后重试。"
            return false
        }
        if let error = registerShortcut(shortcut) {
            shortcutError = error
            return false
        }
        quickPasteShortcut = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: ClipFlowShortcut.defaultsKey)
        shortcutError = nil
        lastCaptureStatus = "快捷键已设为 \(shortcut.displayName)"
        return true
    }

    func beginShortcutRecording() -> Bool {
        guard !isRecordingShortcut else { return false }
        guard registerShortcut != nil, suspendShortcut != nil else {
            shortcutError = "快捷键服务尚未就绪，请重启应用后重试。"
            return false
        }
        suspendShortcut?()
        isRecordingShortcut = true
        shortcutError = nil
        return true
    }

    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        if let error = registerShortcut?(quickPasteShortcut) {
            shortcutError = "快捷键未能恢复：\(error)"
        }
    }

    var filteredItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = sortedItems.filter(matchesSelectedCategory)

        guard !query.isEmpty else {
            return base
        }

        return base.filter { item in
            item.title.lowercased().contains(query)
                || item.snippet.lowercased().contains(query)
                || item.fullText.lowercased().contains(query)
                || item.sourceApp.lowercased().contains(query)
                || item.labels.joined(separator: " ").lowercased().contains(query)
        }
    }

    var selectedItem: ClipboardItem? {
        if let selectedItemID,
           let selected = filteredItems.first(where: { $0.id == selectedItemID }) {
            return selected
        }

        return filteredItems.first
    }

    var metrics: [FlowMetric] {
        let protectedCount = items.filter(\.isSensitive).count
        let codeCount = items.filter { $0.kind == .code }.count
        let stackCount = Set(items.flatMap(\.labels)).count

        return [
            FlowMetric(
                value: "\(items.count)",
                title: "当前条目",
                detail: "仅保存在这台 Mac 上的最近剪贴内容",
                icon: "waveform.path.ecg.rectangle",
                tint: ClipCategory.quickPaste.tint
            ),
            FlowMetric(
                value: "\(max(stackCount, 1))",
                title: "智能信号",
                detail: "结合内容类型、来源应用与复用行为生成",
                icon: "square.3.layers.3d.top.filled",
                tint: ClipCategory.smartStacks.tint
            ),
            FlowMetric(
                value: "\(max(protectedCount, codeCount))",
                title: "重点内容",
                detail: "高价值代码或敏感内容会被优先显示",
                icon: "lock.badge.clock",
                tint: ClipCategory.protected.tint
            )
        ]
    }

    var recentItems: [ClipboardItem] {
        Array(sortedItems.prefix(50))
    }

    var quickPasteItems: [ClipboardItem] {
        let pins = sortedItems.filter(\.pinned)
        let recent = sortedItems.filter { !$0.pinned }
        return Array((pins + recent).prefix(50))
    }

    func count(for category: ClipCategory) -> Int {
        sortedItems.filter { matchesSelectedCategory($0, category: category) }.count
    }

    func item(withID id: UUID) -> ClipboardItem? {
        items.first { $0.id == id && !$0.isExpired() }
    }

    func select(_ item: ClipboardItem) {
        selectedItemID = item.id
    }

    func togglePin(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].pinned.toggle()
        items[index].createdAt = Date()
        lastCaptureStatus = items[index].pinned ? "已置顶到快速粘贴" : "已取消快速置顶"
    }

    func delete(_ itemID: UUID) {
        if let item = items.first(where: { $0.id == itemID }) {
            rememberCloudDeletion(for: [item])
            removeStoredAssetIfNeeded(for: item)
        }
        items.removeAll { $0.id == itemID }
        revealedItemIDs.remove(itemID)
        lastCaptureStatus = "已删除该条内容"
    }

    func clearHistory() {
        let pinned = items.filter(\.pinned)
        rememberCloudDeletion(for: items.filter { !$0.pinned })
        items.filter { !$0.pinned }.forEach(removeStoredAssetIfNeeded)
        items = pinned
        revealedItemIDs.removeAll()
        lastCaptureStatus = pinned.isEmpty ? "历史记录已清空" : "历史记录已清空，已保留置顶内容"
    }

    func ingestCopiedText(_ text: String, sourceApp: String, sourceBundleID: String?) {
        guard !text.isEmpty else { return }
        guard text.count <= 20_000 else {
            lastCaptureStatus = "已跳过过大的剪贴内容"
            return
        }

        purgeExpired()

        let existingIndex = items.firstIndex { !$0.isImage && $0.fullText == text }
        let existing = existingIndex.map { items.remove(at: $0) }
        let item = ClipboardClassifier.makeItem(
            text: text,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            autoProtectSecrets: autoProtectSecrets,
            existingItem: existing
        ).applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled)

        items.insert(item, at: 0)
        trimItemsToLimit()

        selectedItemID = selectedItemID ?? item.id
        lastCaptureStatus = "已从 \(sourceApp) 捕获新内容"
    }

    func ingestCopiedImage(_ imageData: Data, size: CGSize, sourceApp: String, sourceBundleID: String?) {
        guard !imageData.isEmpty else { return }
        guard imageData.count <= 25_000_000 else {
            lastCaptureStatus = "已跳过过大的图片"
            return
        }

        purgeExpired()

        let signature = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        let existingIndex = items.firstIndex { $0.imageSignature == signature }
        let existing = existingIndex.map { items.remove(at: $0) }
        let itemID = existing?.id ?? UUID()
        let imageFilename = "\(itemID.uuidString).png"
        let imageURL = imagesDirectoryURL.appendingPathComponent(imageFilename)

        do {
            try imageData.write(to: imageURL, options: [.atomic])
        } catch {
            if let existing {
                items.insert(existing, at: 0)
            }
            lastCaptureStatus = "保存图片失败"
            return
        }

        imagePreviewCache.removeObject(forKey: imageFilename as NSString)

        if let existing, existing.imageFilename != imageFilename {
            removeStoredAssetIfNeeded(for: existing)
        }

        let item = ClipboardClassifier.makeImageItem(
            imageFilename: imageFilename,
            imageSignature: signature,
            imageSize: size,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            existingItem: existing
        ).applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled)

        items.insert(item, at: 0)
        trimItemsToLimit()

        selectedItemID = selectedItemID ?? item.id
        lastCaptureStatus = "已从 \(sourceApp) 捕获图片"
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    func updateExcludedApps(from rawValue: String) {
        let cleaned = rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        excludedBundleIDs = cleaned.isEmpty ? Self.defaultExcludedBundleIDs : cleaned
    }

    func resetExcludedAppsToDefaults() {
        excludedBundleIDs = Self.defaultExcludedBundleIDs
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13, *) else {
            launchAtLogin = false
            lastCaptureStatus = "macOS 12 请在系统偏好设置的用户与群组中添加登录项"
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            launchAtLogin = enabled
            defaults.set(enabled, forKey: Keys.launchAtLogin)
            lastCaptureStatus = enabled ? "已开启开机自动启动" : "已关闭开机自动启动"
        } catch {
            launchAtLogin = Self.currentLaunchAtLoginState()
            lastCaptureStatus = "开机自动启动设置失败，请将 ClipFlow 放在应用程序目录后再试"
        }
    }

    func toggleMenuQuickPasteMode() {
        menuQuickPasteModeEnabled.toggle()
        lastCaptureStatus = menuQuickPasteModeEnabled
            ? "已开启快贴模式，双击最近条目会直接粘贴"
            : "已关闭快贴模式，左键点击最近条目会复制到剪贴板"
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        cloudSyncGeneration += 1
        if enabled {
            iCloudSyncEnabled = true
            defaults.set(true, forKey: Keys.iCloudSyncEnabled)
            refreshPermissionReport(showEvenIfHealthy: false, promptForAccessibility: false)
            Task { [weak self] in
                self?.enableICloudSyncIfPossible(announceResult: true)
            }
        } else {
            pendingCloudSyncTask?.cancel()
            cloudSyncLoopTask?.cancel()
            iCloudSyncEnabled = false
            defaults.set(false, forKey: Keys.iCloudSyncEnabled)
            iCloudSyncPhase = .disabled
            lastCaptureStatus = "已关闭文稿目录同步"
        }
    }

    func dismissStartupPermissionReport() {
        startupPermissionReport = nil
    }

    func rerunPermissionCheck() {
        refreshPermissionReport(showEvenIfHealthy: true, promptForAccessibility: false)
    }

    func requestAccessibilityPermissionPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissionReport(showEvenIfHealthy: true, promptForAccessibility: false)
    }

    func toggleReveal(_ itemID: UUID) {
        if revealedItemIDs.contains(itemID) {
            revealedItemIDs.remove(itemID)
            lastCaptureStatus = "敏感内容已隐藏"
        } else {
            revealedItemIDs.insert(itemID)
            lastCaptureStatus = "敏感内容已显示"
        }
    }

    func isRevealed(_ item: ClipboardItem) -> Bool {
        item.privacy == .standard || revealedItemIDs.contains(item.id)
    }

    func displaySnippet(for item: ClipboardItem) -> String {
        guard !item.isExpired() else { return "内容已过期" }
        if item.isImage && !isRevealed(item) {
            return "图片预览已隐藏"
        }
        return isRevealed(item) ? item.snippet : masked(text: item.snippet)
    }

    func displayFullText(for item: ClipboardItem) -> String {
        guard !item.isExpired() else { return "内容已过期" }
        if item.isImage && !isRevealed(item) {
            return "图片预览已隐藏"
        }
        if item.isImage {
            return item.snippet
        }
        return isRevealed(item) ? item.fullText : masked(text: item.fullText)
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let imageFilename = item.imageFilename else { return nil }
        return imagesDirectoryURL.appendingPathComponent(imageFilename)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let imageURL = imageURL(for: item) else { return nil }
        return try? Data(contentsOf: imageURL, options: [.mappedIfSafe])
    }

    func imagePreview(for item: ClipboardItem) -> NSImage? {
        guard !item.isExpired() else { return nil }
        guard let imageFilename = item.imageFilename else { return nil }

        let cacheKey = imageFilename as NSString
        if let cachedImage = imagePreviewCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let imageURL = imageURL(for: item),
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            return nil
        }

        let image = NSImage(cgImage: thumbnail, size: .zero)
        imagePreviewCache.setObject(image, forKey: cacheKey, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }

    func purgeExpired(at now: Date = Date()) {
        let expiredItems = items.filter { $0.isExpired(at: now) }
        guard !expiredItems.isEmpty else { return }
        let expiredIDs = Set(expiredItems.map(\.id))
        expiredItems.forEach(removeStoredAssetIfNeeded)
        items.removeAll { expiredIDs.contains($0.id) }
        revealedItemIDs.subtract(expiredIDs)
        lastCaptureStatus = "已清理过期的敏感内容"
    }

    func hudItems(matching query: String) -> [ClipboardItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = quickPasteItems.isEmpty ? recentItems : quickPasteItems

        guard !normalized.isEmpty else {
            return base
        }

        return base.filter { item in
            item.title.lowercased().contains(normalized)
                || item.snippet.lowercased().contains(normalized)
                || item.fullText.lowercased().contains(normalized)
                || item.sourceApp.lowercased().contains(normalized)
                || item.labels.joined(separator: " ").lowercased().contains(normalized)
        }
    }

    var protectedCount: Int {
        items.filter(\.isSensitive).count
    }

    var excludedAppCount: Int {
        excludedBundleIDs.count
    }

    var statusSummary: String {
        capturePaused ? "已暂停剪贴监听" : lastCaptureStatus
    }

    var iCloudSyncStatusValue: String {
        switch iCloudSyncPhase {
        case .disabled:
            return "未启用"
        case .syncing:
            return "整理中"
        case .active:
            return "已启用"
        case .unavailable:
            return "不可用"
        case .failed:
            return "异常"
        }
    }

    var iCloudSyncTint: Color {
        switch iCloudSyncPhase {
        case .disabled:
            return ClipCategory.all.tint
        case .syncing:
            return ClipCategory.quickPaste.tint
        case .active:
            return ClipCategory.smartStacks.tint
        case .unavailable, .failed:
            return ClipCategory.protected.tint
        }
    }

    var iCloudSyncDetail: String {
        switch iCloudSyncPhase {
        case .disabled:
            return "将普通文本与图片历史镜像到“文稿/ClipFlow”。如果系统已开启 iCloud Drive 的“桌面与文稿文件夹”，这些内容会随系统同步。"
        case .syncing:
            return "正在合并本机与“文稿/ClipFlow”中的历史内容。"
        case .active:
            if let iCloudLastSyncedAt {
                return "已启用文稿目录同步，上次整理于 \(Self.syncFormatter.string(from: iCloudLastSyncedAt))。受保护内容不会写入“文稿/ClipFlow”。"
            }
            return "已启用文稿目录同步。若系统已开启文稿同步，普通历史内容会随系统在设备间同步。"
        case .unavailable:
            return cloudSyncCoordinator.resolveAvailabilityDescription() ?? "当前无法访问“文稿/ClipFlow”。"
        case .failed(let message):
            return message
        }
    }

    private var sortedItems: [ClipboardItem] {
        sortItems(items.filter { !$0.isExpired() })
    }

    private func masked(text: String) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(repeating: "•", count: max(8, min(compact.count, 28)))
    }

    private func ensureSelectionStillValid() {
        guard let selectedItemID else {
            self.selectedItemID = filteredItems.first?.id
            return
        }

        if !filteredItems.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = filteredItems.first?.id
        }
    }

    private func matchesSelectedCategory(_ item: ClipboardItem) -> Bool {
        matchesSelectedCategory(item, category: selectedCategory)
    }

    private func matchesSelectedCategory(_ item: ClipboardItem, category: ClipCategory) -> Bool {
        switch category {
        case .all:
            return true
        case .quickPaste:
            return item.pinned || item.createdAt > Date().addingTimeInterval(-900)
        case .smartStacks:
            return item.labels.count >= 3
        case .code:
            return item.kind == .code
        case .links:
            return item.kind == .link
        case .protected:
            return item.isSensitive
        }
    }

    private func loadItems() -> [ClipboardItem] {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: historyURL)
            } catch CocoaError.fileReadNoSuchFile {
                return []
            }
            let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
            return decoded.map { $0.applyingExpirationPolicy(enabled: sensitiveAutoExpireEnabled) }.filter {
                if $0.isImage, let imageURL = imageURL(for: $0), !fileManager.fileExists(atPath: imageURL.path) {
                    return false
                }
                return !$0.isExpired()
            }
        } catch {
            historyLoadError = "历史文件读取失败，已保留原文件和图片。新记录暂存于内存，请恢复历史文件后重启应用。"
            lastCaptureStatus = historyLoadError ?? "历史文件读取失败"
            return []
        }
    }

    private func schedulePersistItems() {
        guard historyLoadError == nil else { return }
        let destinationURL = historyURL

        pendingPersistWorkItem?.cancel()

        let data: Data
        do {
            data = try JSONEncoder().encode(items)
        } catch {
            lastCaptureStatus = "保存历史记录失败"
            return
        }

        let writer: @Sendable () -> Void = {
            do {
                try data.write(to: destinationURL, options: [.atomic])
            } catch {
                Task { @MainActor in
                    ClipFlowStore.shared.lastCaptureStatus = "保存历史记录失败"
                }
            }
        }

        let workItem = DispatchWorkItem(qos: .utility, flags: .assignCurrentContext, block: writer)

        pendingPersistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func trimItemsToLimit() {
        guard items.count > maxItems else { return }
        let ordered = sortItems(items)
        let retained = ordered.filter(\.pinned) + ordered.filter { !$0.pinned }
            .prefix(max(0, maxItems - ordered.filter(\.pinned).count))
        let retainedIDs = Set(retained.map(\.id))
        let overflow = items.filter { !retainedIDs.contains($0.id) }
        rememberCloudDeletion(for: overflow)
        overflow.forEach(removeStoredAssetIfNeeded)
        items = retained
    }

    private func removeStoredAssetIfNeeded(for item: ClipboardItem) {
        if let imageFilename = item.imageFilename {
            imagePreviewCache.removeObject(forKey: imageFilename as NSString)
        }

        guard let imageURL = imageURL(for: item), fileManager.fileExists(atPath: imageURL.path) else {
            return
        }

        try? fileManager.removeItem(at: imageURL)
    }

    private func cleanupOrphanedImageFiles() {
        guard historyLoadError == nil else { return }
        guard let fileURLs = try? fileManager.contentsOfDirectory(at: imagesDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        let activeFilenames = Set(items.compactMap(\.imageFilename))
        for fileURL in fileURLs where !activeFilenames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func isEligibleForICloudSync(_ item: ClipboardItem) -> Bool {
        !item.isSensitive
    }

    private func rememberCloudDeletion(for removedItems: [ClipboardItem]) {
        let now = Date()
        for item in removedItems where isEligibleForICloudSync(item) {
            localSyncTombstones[item.id] = now
        }
    }

    private func enableICloudSyncIfPossible(announceResult: Bool) {
        guard iCloudSyncEnabled, historyLoadError == nil else { return }
        startCloudSyncLoop()
        runICloudSync(announceSuccess: announceResult)
    }

    private func startCloudSyncLoop() {
        cloudSyncLoopTask?.cancel()
        cloudSyncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refreshICloudSyncIfNeeded()
            }
        }
    }

    private func refreshICloudSyncIfNeeded() {
        guard iCloudSyncEnabled else { return }
        runICloudSync(announceSuccess: false)
    }

    private func scheduleICloudSync() {
        pendingCloudSyncTask?.cancel()
        pendingCloudSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 900_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshICloudSyncIfNeeded()
        }
    }

    private func runICloudSync(announceSuccess: Bool) {
        guard iCloudSyncEnabled, historyLoadError == nil else { return }
        guard activeCloudSyncTask == nil else {
            syncRequestedWhileRunning = true
            return
        }

        iCloudSyncPhase = .syncing
        let snapshot = items
        let tombstones = localSyncTombstones
        let revision = itemsRevision
        let generation = cloudSyncGeneration
        let coordinator = cloudSyncCoordinator
        let worker = cloudSyncWorker
        let limit = maxItems
        activeCloudSyncTask = Task { [weak self] in
            let result: Result<ClipFlowCloudSyncResult, Error>
            do {
                result = .success(try await worker.synchronize(
                    using: coordinator, localItems: snapshot, tombstones: tombstones, maxItems: limit
                ))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.activeCloudSyncTask = nil
            let changedDuringSync = self.itemsRevision != revision
            let needsFollowUp = self.syncRequestedWhileRunning || changedDuringSync
                || self.cloudSyncGeneration != generation
            self.syncRequestedWhileRunning = false
            guard self.iCloudSyncEnabled else {
                self.cleanupOrphanedImageFiles()
                return
            }
            guard self.cloudSyncGeneration == generation else {
                self.cleanupOrphanedImageFiles()
                self.scheduleICloudSync()
                return
            }
            switch result {
            case .success(let result):
                // A copy/delete/pin performed during disk I/O must not be overwritten
                // by the older snapshot. Reconcile it in the next serialized run.
                if !changedDuringSync {
                    self.applyCloudItems(result.localItems)
                    self.localSyncTombstones = result.tombstones
                }
                // A background download may have recreated an asset deleted
                // during this run, even when its stale snapshot is discarded.
                self.cleanupOrphanedImageFiles()
                self.iCloudLastSyncedAt = Date()
                self.defaults.set(self.iCloudLastSyncedAt, forKey: Keys.iCloudLastSyncedAt)
                self.iCloudSyncPhase = .active
                if announceSuccess {
                    self.lastCaptureStatus = "已开启文稿目录同步"
                }
                if needsFollowUp { self.scheduleICloudSync() }
            case .failure(let error):
                if changedDuringSync {
                    self.cleanupOrphanedImageFiles()
                    self.scheduleICloudSync()
                } else {
                    self.handleICloudSyncFailure((error as? ClipFlowCloudSyncError) ?? .writeFailed)
                }
            }
        }
    }

    private func handleICloudSyncFailure(_ error: ClipFlowCloudSyncError) {
        cloudSyncGeneration += 1
        pendingCloudSyncTask?.cancel()
        cloudSyncLoopTask?.cancel()
        iCloudSyncEnabled = false
        defaults.set(false, forKey: Keys.iCloudSyncEnabled)

        switch error {
        case .unavailable:
            iCloudSyncPhase = .unavailable
            lastCaptureStatus = cloudSyncCoordinator.resolveAvailabilityDescription() ?? "无法访问“文稿”目录"
        case .invalidState, .writeFailed:
            iCloudSyncPhase = .failed(error.errorDescription ?? "文稿目录同步失败")
            lastCaptureStatus = error.errorDescription ?? "文稿目录同步失败"
        }
    }

    private func applyCloudItems(_ cloudItems: [ClipboardItem]) {
        let preservedLocalItems = items.filter { !isEligibleForICloudSync($0) }
        var combinedByID = Dictionary(uniqueKeysWithValues: preservedLocalItems.map { ($0.id, $0) })

        for item in cloudItems where combinedByID[item.id] == nil {
            combinedByID[item.id] = item
        }

        let combinedItems = sortItems(Array(combinedByID.values))
        guard combinedItems != items else { return }

        isApplyingCloudSnapshot = true
        items = combinedItems
        isApplyingCloudSnapshot = false
        cleanupOrphanedImageFiles()
    }

    private func sortItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func persistLocalSyncTombstones() {
        guard let data = try? JSONEncoder().encode(localSyncTombstones) else { return }
        defaults.set(data, forKey: Keys.iCloudSyncTombstones)
    }

    private func runStartupPermissionCheck() {
        refreshPermissionReport(showEvenIfHealthy: false, promptForAccessibility: true)
    }

    private func refreshPermissionReport(showEvenIfHealthy: Bool, promptForAccessibility: Bool) {
        let report = buildPermissionReport(promptForAccessibility: promptForAccessibility)

        if report.needsAttention || showEvenIfHealthy {
            startupPermissionReport = report
        } else {
            startupPermissionReport = nil
            lastCaptureStatus = "启动权限检查完成"
        }
    }

    private func buildPermissionReport(promptForAccessibility: Bool) -> ClipFlowPermissionReport {
        let accessibilityGranted = checkAccessibilityPermission(promptIfNeeded: promptForAccessibility)
        let accessibilityItem = ClipFlowPermissionItem(
            title: "辅助功能",
            detail: accessibilityGranted
                ? "已授权。ClipFlow 可以在回填剪贴板后自动触发粘贴。"
                : "未授权。没有这个权限时，ClipFlow 只能保存历史，无法自动把内容粘贴回输入框。",
            icon: "figure.wave.circle",
            status: accessibilityGranted ? .granted : .needsAttention
        )

        let documentsAccessGranted = checkDocumentsFolderAccessIfNeeded()
        let documentsItem = ClipFlowPermissionItem(
            title: "文稿目录",
            detail: iCloudSyncEnabled
                ? (documentsAccessGranted
                    ? "已可读写“文稿/ClipFlow”，普通历史内容会镜像到这个文件夹。"
                    : "文稿目录同步已开启，但当前还不能稳定读写“文稿/ClipFlow”。如系统弹出权限提示，请选择允许。")
                : "当前未开启文稿目录同步，因此不需要检查这个权限。",
            icon: "folder.badge.gearshape",
            status: iCloudSyncEnabled ? (documentsAccessGranted ? .granted : .needsAttention) : .notRequired
        )

        let items = [accessibilityItem, documentsItem]
        let hasIssue = items.contains { $0.status == .needsAttention }

        return ClipFlowPermissionReport(
            title: hasIssue ? "启动时发现权限未完整" : "权限检查完成",
            message: hasIssue
                ? "ClipFlow 已在启动时完成权限检测。部分系统权限还未就绪，相关功能可能会受影响。"
                : "ClipFlow 已完成本次启动权限检测，当前核心权限状态正常。",
            items: items
        )
    }

    private func checkAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }

        return AXIsProcessTrusted()
    }

    private func checkDocumentsFolderAccessIfNeeded() -> Bool {
        guard iCloudSyncEnabled else { return true }
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }

        let clipFlowDirectory = documentsURL.appendingPathComponent("ClipFlow", isDirectory: true)
        let probeURL = clipFlowDirectory.appendingPathComponent(".permission-probe")

        do {
            try fileManager.createDirectory(at: clipFlowDirectory, withIntermediateDirectories: true)
            let probeData = Data("clipflow".utf8)
            try probeData.write(to: probeURL, options: [.atomic])
            try? fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private enum Keys {
        static let appearanceMode = "appearanceMode"
        static let capturePaused = "capturePaused"
        static let autoProtectSecrets = "autoProtectSecrets"
        static let sensitiveAutoExpireEnabled = "sensitiveAutoExpireEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let menuQuickPasteModeEnabled = "menuQuickPasteModeEnabled"
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let iCloudLastSyncedAt = "iCloudLastSyncedAt"
        static let iCloudSyncTombstones = "iCloudSyncTombstones"
        static let excludedBundleIDs = "excludedBundleIDs"
    }

    private static let defaultExcludedBundleIDs: [String] = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop"
    ]

    private static func currentLaunchAtLoginState() -> Bool {
        guard #available(macOS 13, *) else { return false }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    private static func decodeTombstones(from data: Data?) -> [UUID: Date] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([UUID: Date].self, from: data)) ?? [:]
    }

    private static let syncFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum ClipFlowCatalog {
    static let integrations: [IntegrationPill] = [
        IntegrationPill(
            title: "菜单栏入口",
            icon: "menubar.rectangle",
            detail: "从菜单栏暂停监听、查看最近内容，或重新打开主窗口。",
            tint: ClipCategory.all.tint
        ),
        IntegrationPill(
            title: "全局呼出",
            icon: "command.circle",
            detail: "用全局快捷键在指针附近呼出快速粘贴面板，可在设置中自定义组合。",
            tint: ClipCategory.quickPaste.tint
        ),
        IntegrationPill(
            title: "隐私优先",
            icon: "lock.rectangle.stack",
            detail: "敏感内容默认遮罩显示，仅本地保存，并可自动过期。",
            tint: ClipCategory.protected.tint
        ),
        IntegrationPill(
            title: "原生粘贴",
            icon: "arrow.up.doc",
            detail: "选中条目后会重新写入剪贴板，并向目标应用发送粘贴操作。",
            tint: ClipCategory.links.tint
        )
    ]
}
