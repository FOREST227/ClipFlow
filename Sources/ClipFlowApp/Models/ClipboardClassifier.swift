import Foundation
import CoreGraphics

enum ClipboardClassifier {
    static func kind(
        for text: String,
        sourceBundleID: String? = nil,
        recentSourceBundleIDs: [String] = []
    ) -> ClipboardKind {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()
        let codeLike = looksLikeCode(normalized)
        let secretLike = looksLikeSecretPayload(
            normalized,
            lowered: lowered,
            codeLike: codeLike,
            sourceBundleID: sourceBundleID,
            recentSourceBundleIDs: recentSourceBundleIDs
        )

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

    static func privacy(
        for text: String,
        kind: ClipboardKind,
        sourceBundleID: String?,
        autoProtectSecrets: Bool,
        recentSourceBundleIDs: [String] = []
    ) -> PrivacyLevel {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()
        let codeLike = kind == .code || looksLikeCode(normalized)
        let sensitiveSource = PasswordManagerApps.contains(sourceBundleID)
        let secretLike = looksLikeSecretPayload(
            normalized,
            lowered: lowered,
            codeLike: codeLike,
            sourceBundleID: sourceBundleID,
            recentSourceBundleIDs: recentSourceBundleIDs
        )

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
            let swiftSyntax = lowered.range(of: #"(?m)^\s*(?:func\s+\w+\s*\(|import\s+(?:swiftui|foundation)\b|@(?:state|binding|published)\b)"#,
                options: .regularExpression) != nil
            if swiftSyntax || lowered.contains("import swiftui") || lowered.contains("import foundation") {
                labels.append("Swift")
            }
            if !swiftSyntax && (lowered.contains("python") || lowered.contains("def ") || lowered.contains("print(")) {
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

    static func makeItem(
        text: String,
        sourceApp: String,
        sourceBundleID: String?,
        autoProtectSecrets: Bool,
        existingItem: ClipboardItem?,
        recentSourceBundleIDs: [String] = [],
        richContent: ClipboardRepresentations.Snapshot = .empty
    ) -> ClipboardItem {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind(for: normalized, sourceBundleID: sourceBundleID, recentSourceBundleIDs: recentSourceBundleIDs)
        let privacy = privacy(
            for: normalized,
            kind: kind,
            sourceBundleID: sourceBundleID,
            autoProtectSecrets: autoProtectSecrets,
            recentSourceBundleIDs: recentSourceBundleIDs
        )
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
            capturedAt: capturedAt,
            pinnedAt: existingItem?.pinnedAt,
            secretPayloadRef: nil,
            rtfData: richContent.rtfData.flatMap { $0.isEmpty ? nil : $0 },
            htmlData: richContent.htmlData.flatMap { $0.isEmpty ? nil : $0 },
            fileURLs: richContent.fileURLs.isEmpty ? nil : richContent.fileURLs
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
            capturedAt: capturedAt,
            pinnedAt: existingItem?.pinnedAt,
            secretPayloadRef: nil
        )
    }
}
