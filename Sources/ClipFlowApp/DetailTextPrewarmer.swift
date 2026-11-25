import AppKit
import Foundation
import JavaScriptCore
import SwiftUI

// MARK: - Pre-Rendered Native Rich Document Models (Zero-WebView 120Hz Rendering)

struct PreRenderedCode: Sendable {
    let light: AttributedString
    let dark: AttributedString
    let highlightedHTML: String
    let isMarkdown: Bool
    let markdownBlocks: [PreRenderedMarkdownBlock]?
    let renderedMarkdownHTML: String?
}

enum PreRenderedMarkdownBlock: Identifiable, Sendable {
    case heading(id: Int, level: Int, text: AttributedString)
    case paragraph(id: Int, text: AttributedString)
    case quote(id: Int, text: AttributedString)
    case listItem(id: Int, marker: String, text: AttributedString)
    case table(id: Int, headers: [String], rows: [[String]])
    case codeBlock(id: Int, language: String?, light: AttributedString, dark: AttributedString)
    case divider(id: Int)

    var id: Int {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .quote(let id, _),
             .listItem(let id, _, _),
             .table(let id, _, _),
             .codeBlock(let id, _, _, _),
             .divider(let id):
            return id
        }
    }
}

// MARK: - Background JavaScriptCore Pre-Renderer (Loads highlight.js + markdown-it ONCE)

private final class DetailTextJSEngine: @unchecked Sendable {
    static let shared = DetailTextJSEngine()

    private let queue = DispatchQueue(label: "ClipFlow.DetailTextJSEngine", qos: .userInitiated)
    private var context: JSContext?
    private var loaded = false

    private init() {}

    func preRender(text: String, isCode: Bool, isMarkdown: Bool, language: String) -> PreRenderedCode {
        queue.sync {
            ensureLoaded()
            let sample = text.count > 16_000 ? String(text.prefix(16_000)) : text
            let resolvedLang: String
            if language == "自动识别" {
                if isMarkdown && !isCode {
                    resolvedLang = "markdown"
                } else {
                    resolvedLang = DetailTextFormat.languageHint(sample) ?? ""
                }
            } else {
                resolvedLang = language
            }

            let hlHTML = highlightHTML(text: sample, language: resolvedLang)
            let lightAttr = HighlightedHTMLParser.attributedString(from: hlHTML, dark: false)
            let darkAttr = HighlightedHTMLParser.attributedString(from: hlHTML, dark: true)

            var mdBlocks: [PreRenderedMarkdownBlock]? = nil
            var mdHTML: String? = nil
            if isMarkdown {
                mdBlocks = MarkdownBlockParser.parse(sample) { code, lang in
                    let blockHTML = self.highlightHTML(text: code, language: lang ?? "")
                    return (
                        HighlightedHTMLParser.attributedString(from: blockHTML, dark: false),
                        HighlightedHTMLParser.attributedString(from: blockHTML, dark: true)
                    )
                }
                mdHTML = renderMarkdownHTML(text: sample)
            }

            return PreRenderedCode(
                light: lightAttr,
                dark: darkAttr,
                highlightedHTML: hlHTML,
                isMarkdown: isMarkdown,
                markdownBlocks: mdBlocks,
                renderedMarkdownHTML: mdHTML
            )
        }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let ctx = JSContext() else { return }
        let scripts = DetailTextDocument.scripts
        guard !scripts.isEmpty else { return }
        ctx.evaluateScript(scripts)
        ctx.evaluateScript("""
        function __cfEscape(s) {
            return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }
        function __cfHighlight(src, lang) {
            if (!src) return '';
            if (src.length > 120000 || typeof hljs === 'undefined') return __cfEscape(src);
            try {
                if (lang && hljs.getLanguage(lang)) {
                    return hljs.highlight(src, { language: lang, ignoreIllegals: true }).value;
                }
                return hljs.highlightAuto(src).value;
            } catch (_) {
                return __cfEscape(src);
            }
        }
        function __cfMarkdown(src) {
            if (!src || typeof markdownit === 'undefined') return '<pre>' + __cfEscape(src) + '</pre>';
            try {
                var md = markdownit({
                    html: false,
                    linkify: false,
                    typographer: false,
                    highlight: function(code, lang) { return __cfHighlight(code, lang); }
                });
                md.renderer.rules.image = function(tokens, idx) {
                    return '<span>' + __cfEscape(tokens[idx].content || '图片') + '</span>';
                };
                return '<article>' + md.render(src) + '</article>';
            } catch (_) {
                return '<pre>' + __cfEscape(src) + '</pre>';
            }
        }
        """)
        context = ctx
    }

    private func highlightHTML(text: String, language: String) -> String {
        guard let fn = context?.objectForKeyedSubscript("__cfHighlight"),
              let result = fn.call(withArguments: [text, language])?.toString() else {
            return Self.escapeHTML(text)
        }
        return result
    }

    private func renderMarkdownHTML(text: String) -> String {
        guard let fn = context?.objectForKeyedSubscript("__cfMarkdown"),
              let result = fn.call(withArguments: [text])?.toString() else {
            return "<pre>\(Self.escapeHTML(text))</pre>"
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Main-Actor O(1) Cache & Capture/Startup Pre-Warmer

/// Pre-renders Code, Markdown, and Tables into native `AttributedString` + structured blocks
/// at capture time and app startup, so scrolling & time-dial jumps render styled cards at 0ms.
@MainActor
final class DetailTextPrewarmer {
    static let shared = DetailTextPrewarmer()

    private struct CacheKey: Hashable {
        let itemID: UUID
        let textHash: Int
        let language: String
    }

    private var cache: [CacheKey: PreRenderedCode] = [:]
    private var inFlight: Set<CacheKey> = []
    private let maxEntries = 120

    private init() {}

    func cached(for item: ClipboardItem, text: String, language: String = "自动识别") -> PreRenderedCode? {
        let key = CacheKey(itemID: item.id, textHash: text.hashValue, language: language)
        return cache[key]
    }

    func prewarm(items: [ClipboardItem], store: ClipFlowStore, priority: TaskPriority = .utility) {
        var jobs: [(key: CacheKey, text: String, isCode: Bool, isMarkdown: Bool)] = []
        for item in items where !item.isImage && !item.isExpired() {
            if item.isSensitive && !store.isRevealed(item) { continue }
            let text = store.displayFullText(for: item)
            guard !text.isEmpty else { continue }
            let isCode = item.kind == .code
            let isMarkdown = DetailTextFormat.isMarkdown(text)
            guard isCode || isMarkdown else { continue }
            let key = CacheKey(itemID: item.id, textHash: text.hashValue, language: "自动识别")
            if cache[key] == nil, !inFlight.contains(key) {
                inFlight.insert(key)
                jobs.append((key, text, isCode, isMarkdown))
            }
        }
        guard !jobs.isEmpty else { return }

        Task.detached(priority: priority) { [weak self] in
            for job in jobs {
                let rendered = DetailTextJSEngine.shared.preRender(
                    text: job.text,
                    isCode: job.isCode,
                    isMarkdown: job.isMarkdown,
                    language: job.key.language
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(job.key)
                    if self.cache.count >= self.maxEntries {
                        self.cache.removeAll(keepingCapacity: true)
                    }
                    self.cache[job.key] = rendered
                }
            }
        }
    }

    /// Synchronous helper for tests or immediate single-item pre-rendering when a language override is chosen.
    func renderNow(for item: ClipboardItem, text: String, isMarkdown: Bool, language: String = "自动识别") -> PreRenderedCode {
        let key = CacheKey(itemID: item.id, textHash: text.hashValue, language: language)
        if let existing = cache[key] { return existing }
        let rendered = DetailTextJSEngine.shared.preRender(
            text: text,
            isCode: item.kind == .code,
            isMarkdown: isMarkdown,
            language: language
        )
        cache[key] = rendered
        return rendered
    }
}

// MARK: - Fast Linear Parser: highlight.js HTML -> Native AttributedString

enum HighlightedHTMLParser {
    static func attributedString(from html: String, dark: Bool) -> AttributedString {
        let palette = ClipFlowSyntax.colors(dark: dark)
        let defaultColor = color(hex: palette.foreground)

        var result = AttributedString()
        var colorStack: [Color] = [defaultColor]
        var italicStack: [Bool] = [false]
        var boldStack: [Bool] = [false]

        let scalars = html
        var idx = scalars.startIndex

        while idx < scalars.endIndex {
            if scalars[idx] == "<" {
                guard let close = scalars[idx...].firstIndex(of: ">") else {
                    appendChunk(String(scalars[idx...]), color: colorStack.last ?? defaultColor,
                                bold: boldStack.last ?? false, italic: italicStack.last ?? false, to: &result)
                    break
                }
                let tag = String(scalars[scalars.index(after: idx)..<close])
                if tag.hasPrefix("/span") {
                    if colorStack.count > 1 { colorStack.removeLast() }
                    if italicStack.count > 1 { italicStack.removeLast() }
                    if boldStack.count > 1 { boldStack.removeLast() }
                } else if tag.hasPrefix("span") {
                    let cls = extractClassName(from: tag)
                    let style = resolveStyle(forClass: cls, palette: palette, fallback: colorStack.last ?? defaultColor)
                    colorStack.append(style.color)
                    boldStack.append(style.bold)
                    italicStack.append(style.italic)
                }
                idx = scalars.index(after: close)
            } else {
                let nextTag = scalars[idx...].firstIndex(of: "<") ?? scalars.endIndex
                let rawChunk = String(scalars[idx..<nextTag])
                let unescaped = unescapeHTML(rawChunk)
                appendChunk(unescaped, color: colorStack.last ?? defaultColor,
                            bold: boldStack.last ?? false, italic: italicStack.last ?? false, to: &result)
                idx = nextTag
            }
        }
        return result
    }

    private static func appendChunk(_ text: String, color: Color, bold: Bool, italic: Bool, to output: inout AttributedString) {
        guard !text.isEmpty else { return }
        var chunk = AttributedString(text)
        chunk.foregroundColor = color
        if bold || italic {
            let base = Font.system(size: 12, weight: bold ? .semibold : .regular, design: .monospaced)
            chunk.font = italic ? base.italic() : base
        }
        output.append(chunk)
    }

    private static func extractClassName(from tag: String) -> String {
        guard let range = tag.range(of: "class=\"") else { return "" }
        let after = tag[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return "" }
        return String(after[..<end])
    }

    private static func resolveStyle(forClass cls: String, palette: ClipFlowSyntax.Colors, fallback: Color) -> (color: Color, bold: Bool, italic: Bool) {
        let tokens = cls.split(separator: " ").map(String.init)
        for token in tokens {
            switch token {
            case "hljs-keyword", "hljs-selector-tag", "hljs-literal", "hljs-section", "hljs-link":
                return (color(hex: palette.keyword), true, false)
            case "hljs-string", "hljs-regexp", "hljs-addition":
                return (color(hex: palette.string), false, false)
            case "hljs-comment", "hljs-quote":
                return (color(hex: palette.comment), false, true)
            case "hljs-number", "hljs-symbol", "hljs-bullet", "hljs-variable", "hljs-template-variable":
                return (color(hex: palette.number), false, false)
            case "hljs-title", "hljs-title.function_", "hljs-function", "hljs-name":
                return (color(hex: palette.title), true, false)
            case "hljs-attr", "hljs-attribute", "hljs-property":
                return (color(hex: palette.attribute), false, false)
            case "hljs-type", "hljs-built_in", "hljs-class", "hljs-title.class_":
                return (color(hex: palette.typeName), false, false)
            case "hljs-meta", "hljs-doctag", "hljs-deletion":
                return (color(hex: palette.meta), false, false)
            default:
                continue
            }
        }
        return (fallback, false, false)
    }

    private static func color(hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return .primary }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    private static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x60;", with: "`")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Native Structured Markdown & Table Parser (0ms Native SwiftUI Rendering)

enum MarkdownBlockParser {
    static func parse(
        _ text: String,
        highlightCode: (String, String?) -> (light: AttributedString, dark: AttributedString)
    ) -> [PreRenderedMarkdownBlock] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [PreRenderedMarkdownBlock] = []
        var i = 0
        var nextID = 0

        func makeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block ```lang
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                let styled = highlightCode(code, lang.isEmpty ? nil : lang)
                blocks.append(.codeBlock(id: makeID(), language: lang.isEmpty ? nil : lang, light: styled.light, dark: styled.dark))
                continue
            }

            // Markdown pipe table: header row + separator row (| --- | --- |)
            if i + 1 < lines.count,
               line.contains("|"),
               isTableSeparator(lines[i + 1]) {
                let headers = splitTableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let rowLine = lines[i]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    guard !rowTrimmed.isEmpty, rowLine.contains("|") else { break }
                    var cells = splitTableCells(rowLine)
                    if cells.count < headers.count {
                        cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
                    } else if cells.count > headers.count {
                        cells = Array(cells.prefix(headers.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                if !headers.isEmpty {
                    blocks.append(.table(id: makeID(), headers: headers, rows: rows))
                    continue
                }
            }

            // Horizontal divider --- / ***
            if trimmed.count >= 3,
               trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }),
               trimmed.filter({ $0 != " " }).count >= 3 {
                blocks.append(.divider(id: makeID()))
                i += 1
                continue
            }

            // Headings # ... ######
            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(id: makeID(), level: heading.level, text: inlineStyled(heading.content)))
                i += 1
                continue
            }

            // Blockquote > ...
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let qt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qt.hasPrefix(">") else { break }
                    quoteLines.append(String(qt.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(id: makeID(), text: inlineStyled(quoteLines.joined(separator: "\n"))))
                continue
            }

            // Bullet / ordered list item
            if let listItem = parseListItem(trimmed) {
                blocks.append(.listItem(id: makeID(), marker: listItem.marker, text: inlineStyled(listItem.content)))
                i += 1
                continue
            }

            // Paragraph (coalesce consecutive plain lines)
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nt = next.trimmingCharacters(in: .whitespaces)
                if nt.isEmpty || nt.hasPrefix("```") || nt.hasPrefix(">")
                    || parseHeading(nt) != nil || parseListItem(nt) != nil
                    || (i + 1 < lines.count && next.contains("|") && isTableSeparator(lines[i + 1])) {
                    break
                }
                paraLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(id: makeID(), text: inlineStyled(paraLines.joined(separator: "\n"))))
        }

        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let cells = splitTableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.count >= 2 else { return false }
            let stripped = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !stripped.isEmpty && stripped.allSatisfy({ $0 == "-" })
        }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, content: String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ trimmed: String) -> (marker: String, content: String)? {
        if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")), trimmed.count > 2 {
            return ("•", String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        if let dotIdx = trimmed.firstIndex(of: "."), dotIdx > trimmed.startIndex {
            let numPart = trimmed[..<dotIdx]
            let afterDot = trimmed.index(after: dotIdx)
            if numPart.allSatisfy(\.isNumber), afterDot < trimmed.endIndex, trimmed[afterDot] == " " {
                return ("\(numPart).", String(trimmed[trimmed.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func inlineStyled(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(text)
    }
}

// MARK: - Native 0ms Markdown & Table View (Renders identically during 120Hz scroll AND at rest!)

struct NativeMarkdownDocumentView: View {
    let blocks: [PreRenderedMarkdownBlock]
    let dark: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    Text(text)
                        .font(.system(size: level == 1 ? 17 : (level == 2 ? 15 : 13.5), weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .padding(.top, level <= 2 ? 4 : 2)

                case .paragraph(_, let text):
                    Text(text)
                        .font(.system(size: ClipFlowType.cardTitle, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(Color.primary.opacity(0.88))

                case .quote(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(FolioTheme.sageAccent(for: colorScheme).opacity(0.65))
                            .frame(width: 3)
                        Text(text)
                            .font(.system(size: ClipFlowType.body, weight: .regular))
                            .lineSpacing(3.5)
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    }
                    .padding(.vertical, 2)

                case .listItem(_, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker)
                            .font(.system(size: ClipFlowType.body, weight: .semibold))
                            .foregroundStyle(FolioTheme.sageAccent(for: colorScheme))
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(text)
                            .font(.system(size: ClipFlowType.cardTitle, weight: .regular))
                            .lineSpacing(3.5)
                            .foregroundStyle(Color.primary.opacity(0.88))
                    }

                case .divider:
                    Divider().overlay(FolioTheme.hairline(for: colorScheme))
                        .padding(.vertical, 2)

                case .codeBlock(_, let language, let light, let darkAttr):
                    VStack(alignment: .leading, spacing: 4) {
                        if let language, !language.isEmpty {
                            Text(language)
                                .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        }
                        Text(dark ? darkAttr : light)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .lineSpacing(3.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(
                        (dark ? Color.black.opacity(0.24) : Color.white.opacity(0.82)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                    )

                case .table(_, let headers, let rows):
                    nativeArchivalTable(headers: headers, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nativeArchivalTable(headers: [String], rows: [[String]]) -> some View {
        let border = FolioTheme.hairline(for: colorScheme)
        let headerBg = dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
        let stripeBg = dark ? Color.white.opacity(0.025) : Color.black.opacity(0.02)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, header in
                    Text(header)
                        .font(.system(size: ClipFlowType.meta, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.90))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    if colIdx + 1 < headers.count {
                        Rectangle().fill(border).frame(width: 1)
                    }
                }
            }
            .background(headerBg)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                Rectangle().fill(border).frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        Text(cell)
                            .font(.system(size: ClipFlowType.meta, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.84))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5.5)
                        if colIdx + 1 < row.count {
                            Rectangle().fill(border).frame(width: 1)
                        }
                    }
                }
                .background(rowIdx % 2 == 1 ? stripeBg : Color.clear)
            }
        }
        .background(dark ? Color.black.opacity(0.16) : Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
    }
}
