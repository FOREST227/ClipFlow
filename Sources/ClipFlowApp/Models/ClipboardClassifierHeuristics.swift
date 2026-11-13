import Foundation
import CoreGraphics

extension ClipboardClassifier {
    static func looksLikeURL(_ text: String) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        return detector.firstMatch(in: text, options: [], range: range)?.url != nil
    }

    static func looksLikeCode(_ text: String) -> Bool {
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

        // Syntax-shaped fragments also cover single-line calls and partial snippets.
        let syntaxPatterns = [
            #"(?m)^\s*(?:[A-Za-z_$][\w$]*\.)*[A-Za-z_$][\w$]*\([^\n]*\)(?:\.[A-Za-z_$][\w$]*\([^\n]*\))*\s*;?\s*$"#,
            #"(?m)^\s*\.[A-Za-z_][\w]*\([^\n]*\)\s*$"#,
            #"(?m)^\s*#\s*(?:include|define|ifn?def|endif)\b"#,
            #"(?m)^\s*(?:using\s+[\w.]+\s*;|package\s+[\w.]+\s*;?)\s*$"#,
            #"(?m)^\s*(?:(?:unsigned|signed|static|final|volatile)\s+)*(?:int|long|short|double|float|bool|char|String|boolean|size_t)\s+\**[A-Za-z_]\w*\s*(?:=|;|\()"#,
            #"(?m)^\s*(?:std::\w+\s*<<|\[\w+\s+\w+:.*\];)"#,
            #"(?s)^[.#@]?[A-Za-z_][\w.# :>,-]*\s*\{\s*[\w-]+\s*:[^{}]+;\s*.*\}$"#
        ]
        if syntaxPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        let yamlKeys = lines.filter { $0.range(of: #"^[A-Za-z_][\w.-]*:\s*(?:.*)$"#, options: .regularExpression) != nil }
        if yamlKeys.count >= 2,
           text.range(of: #"(?m)^[ \t]+[A-Za-z_][\w.-]*:"#, options: .regularExpression) != nil {
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
        // English keywords alone ("from", "return", "class") are not code.
        guard symbolHits > 0 else { return false }
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

    static func looksLikeOperationalCommand(_ lowered: String) -> Bool {
        lowered.contains("ssh ")
            || lowered.contains("export ")
            || lowered.contains("token")
            || lowered.contains("api_key")
            || lowered.contains("secret")
    }

    static func looksLikeSecretPayload(
        _ text: String,
        lowered: String,
        codeLike: Bool,
        sourceBundleID: String? = nil,
        recentSourceBundleIDs: [String] = []
    ) -> Bool {
        if OTPDetector.shouldTreatStandaloneCodeAsOTP(
            lowered: lowered,
            sourceBundleID: sourceBundleID,
            recentSourceBundleIDs: recentSourceBundleIDs
        ) {
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

        if OTPDetector.hasContextualCode(lowered) {
            return true
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

    static func imagePrivacy(sourceBundleID: String?) -> PrivacyLevel {
        PasswordManagerApps.contains(sourceBundleID) ? .vault : .standard
    }

    static func makeImageTitle(for size: CGSize) -> String {
        "图片 \(formattedDimensionLabel(for: size))"
    }

    static func makeImageSnippet(for size: CGSize) -> String {
        "图片内容 · \(formattedDimensionLabel(for: size))"
    }

    static func imageLabels(for size: CGSize, sourceApp: String, privacy: PrivacyLevel) -> [String] {
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

    static func makeSnippet(for text: String) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let prefix = String(compact.prefix(120))
        return compact.count > 120 ? "\(prefix)…" : prefix
    }

    static func isLikelyShellCommand(_ text: String, lowered: String) -> Bool {
        let structuredCommands = [
            #"^(?:PS\s+[^>]+>\s*)?(?:Get|Set|New|Remove|Clear|Add|Copy|Move|Rename|Test|Start|Stop|Restart|Invoke|Import|Export|Install|Uninstall|Update|Write|Read|Select|Where|ForEach|Sort|Format|Out|ConvertTo|ConvertFrom|Enable|Disable|Resolve|Join|Split|Measure|Wait)-[A-Za-z][\w-]*\b"#,
            #"^\$(?:env:)?[A-Za-z_]\w*\s*(?:\+?=)"#,
            #"^\[System\.[\w.]+\]::\w+\("#,
            #"^(?:export\s+)[A-Za-z_]\w*="#,
            #"^open\s+(?:-|/|\./|~/|["'])"#,
            #"^(?:\./|/usr/bin/|/bin/|/usr/sbin/|/opt/homebrew/bin/)[\w./-]+(?:\s|$)"#
        ]
        if structuredCommands.contains(where: { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return true
        }
        let commandRegex = #"^(?:[$>%#]\s*)?(?:git|ssh|scp|brew|npm|pnpm|yarn|npx|node|python|python3|pip|pip3|curl|wget|docker|kubectl|defaults|chmod|chown|find|grep|sed|awk|cat|ls|cd|pwd|cp|mv|rm|mkdir|touch|swift|xcodebuild|pod|bundle|rails|sudo|launchctl|diskutil|plutil|osascript|ditto|codesign|xattr|kill|killall|ps|lsof|du|df|uname|whoami|which|env|printenv|echo|printf|pbcopy|pbpaste|source|zsh|bash|sh|fish|make|cmake|cargo|rustc|go|dotnet|pwsh|powershell|winget|choco|scoop)\b"#
        if lowered.range(of: commandRegex, options: .regularExpression) != nil {
            return true
        }

        return text.contains("\n$ ")
            || text.contains("\n% ")
            || text.contains("\n> ")
    }

    private static func looksLikeSQL(_ text: String, lowered: String) -> Bool {
        let patterns = [
            #"(?s)^select\s+.+\s+from\s+[\w\[\]".]+(?:\s|;|$)"#,
            #"(?s)^select\s+(?:\d+|count\s*\(|sum\s*\(|now\s*\(|version\s*\()"#,
            #"(?s)^with\s+\w+\s+as\s*\("#,
            #"^insert\s+into\s+\w+"#,
            #"(?s)^update\s+\w+\s+set\s+"#,
            #"^delete\s+from\s+\w+"#,
            #"^(?:create|alter|drop)\s+(?:table|database|index|view)\s+\w+"#
        ]
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    static func looksLikeJSON(_ text: String) -> Bool {
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
