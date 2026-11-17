import Foundation
import UniformTypeIdentifiers

/// One cell's number format, taken from Excel's XML Spreadsheet or HTML clipboard.
struct SpreadsheetCellFormat: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case date
        case time
        case number
    }

    var row: Int
    var column: Int
    var kind: Kind
    /// Excel format code. Text cells use `@`.
    var numberFormat: String
    /// Display text from the source cell. Text cells are written back as this string.
    var text: String
}

/// Decides which stored pasteboard flavors Excel will paste as cells, and reads per-cell formats.
///
/// After the copy session ends, Mac Excel no longer honors `com.microsoft.ole.source.<pid>` (it has no bytes).
/// Replaying `Embed-Source` / `DataObject` / link flavors asks Excel to embed or link an object, and a
/// TIFF-only board pastes a picture. HTML that carries `mso-number-format` pastes real cells: text stays
/// text, and dates keep a date format instead of General. Mac Excel's HTML often marks text-stored dates and
/// numbers as General and leaves the real cell type in the embedded workbook, so formats are read from that
/// package without putting it back on the pasteboard. XML Spreadsheet and Biff, when present, go first.
enum SpreadsheetReplay {
    /// XML Spreadsheet, then Biff / Excel cell payloads, then HTML, RTF, and plain text.
    static func pasteRecords(from entries: [ClipboardPasteboardType]) -> [ClipboardPasteboardType] {
        let present = Set(entries.map(\.type))
        let kept = entries.enumerated().filter { item in
            let type = item.element.type
            if item.element.data.isEmpty || isExcluded(type) { return false }
            // AppKit lists a classic name and its `dyn.` alias as two types. Keep the classic name.
            if type.hasPrefix("dyn.") {
                let classic = declaredName(type)
                if classic != type && present.contains(classic) { return false }
            }
            return true
        }
        return kept.sorted { lhs, rhs in
            let left = rank(lhs.element.type)
            let right = rank(rhs.element.type)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func shouldReplay(_ entries: [ClipboardPasteboardType]) -> Bool {
        if entries.contains(where: { ClipboardPasteboardKinds.isSpreadsheetNative($0.type) }) { return true }
        guard let html = htmlText(in: entries) else { return false }
        return ClipboardHTMLText.isTabularDocument(html)
    }

    /// Session stubs and the preview picture. Putting these back makes Excel embed an object or paste a picture.
    static func isExcluded(_ type: String) -> Bool {
        aliases(of: type).contains(where: isExcludedName)
    }

    /// `rows` and `columns` are the copied block. An embedded workbook usually holds the whole sheet, so the
    /// package parser keeps only the selection of this size.
    static func cells(
        in entries: [ClipboardPasteboardType],
        htmlData: Data? = nil,
        rows: Int? = nil,
        columns: Int? = nil
    ) -> [SpreadsheetCellFormat] {
        if let xml = entries.first(where: { isXMLSpreadsheet($0.type) }),
           let parsed = SpreadsheetFormatParser.parseXML(xml.data), !parsed.isEmpty {
            return parsed
        }
        if let parsed = packageCells(in: entries, rows: rows, columns: columns), !parsed.isEmpty {
            return parsed
        }
        let html = htmlText(in: entries) ?? htmlData.flatMap { ClipboardCaptureDecision.decodeText($0) }
        guard let html, let parsed = SpreadsheetFormatParser.parseHTML(html), !parsed.isEmpty else { return [] }
        return parsed
    }

    /// Applies parsed number formats on the active cell. Text cells are written as text so leading zeros stay.
    static func formatScript(for cells: [SpreadsheetCellFormat]) -> String? {
        let lines = cells.compactMap(formatStatement)
        guard !lines.isEmpty else { return nil }
        return """
        tell application "Microsoft Excel"
            if (count of workbooks) is 0 then error "ClipFlow: no workbook"
            set anchorCell to active cell
        \(lines.joined(separator: "\n"))
        end tell
        """
    }

    static let pasteScript = """
    tell application "Microsoft Excel"
        if (count of workbooks) is 0 then error "ClipFlow: no workbook"
        paste worksheet active sheet
    end tell
    """

    private static func formatStatement(_ cell: SpreadsheetCellFormat) -> String? {
        guard cell.row >= 0, cell.column >= 0 else { return nil }
        let target = "    set targetCell to get offset anchorCell row offset \(cell.row) column offset \(cell.column)"
        // A General cell parses "2025-11-01" and "5026.70505" as values. Text has to be written while the
        // format is @, and only then can the original format be put back. Doing it the other way stores a serial.
        if cell.kind == .text {
            var lines = [
                target,
                "    set number format of targetCell to \"@\"",
                "    set value of targetCell to \(appleScriptLiteral(cell.text))"
            ]
            if cell.numberFormat != "@" {
                lines.append("    set number format of targetCell to \(appleScriptLiteral(cell.numberFormat))")
            }
            return lines.joined(separator: "\n")
        }
        return [
            target,
            "    set number format of targetCell to \(appleScriptLiteral(cell.numberFormat))"
        ].joined(separator: "\n")
    }

    /// Embedded workbook inside an OLE package. It is not pasted; Excel would embed an object.
    private static func packageCells(
        in entries: [ClipboardPasteboardType],
        rows: Int?,
        columns: Int?
    ) -> [SpreadsheetCellFormat]? {
        for entry in entries where isEmbeddedWorkbook(entry.type) && !entry.data.isEmpty {
            if let parsed = SpreadsheetPackageParser.parse(entry.data, rows: rows, columns: columns), !parsed.isEmpty {
                return parsed
            }
        }
        return nil
    }

    private static func isEmbeddedWorkbook(_ type: String) -> Bool {
        let compact = type.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        return compact.contains("embedsource")
    }

    static func appleScriptLiteral(_ text: String) -> String {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        return parts.map { part in
            let escaped = String(part)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " & return & ")
    }

    private static func rank(_ type: String) -> Int {
        aliases(of: type).map(rankName).min() ?? 4
    }

    private static func rankName(_ type: String) -> Int {
        let lower = type.lowercased()
        if isXMLSpreadsheet(type) { return 0 }
        if lower.contains("biff") || (lower.contains("excel") && !isExcludedName(type)) { return 1 }
        if ClipboardPasteboardKinds.isHTMLType(type) { return 2 }
        if ClipboardPasteboardKinds.isRTFType(type) { return 3 }
        return 4
    }

    /// Classic pasteboard name for a `dyn.` alias, otherwise the type itself.
    private static func declaredName(_ type: String) -> String {
        aliases(of: type).first { !$0.hasPrefix("dyn.") } ?? type
    }

    private static func aliases(of type: String) -> [String] {
        var names = [type]
        if let uti = UTType(type) {
            let tagClass = UTTagClass(rawValue: "com.apple.nspboard-type")
            names.append(contentsOf: uti.tags[tagClass] ?? [])
        }
        return names
    }

    private static func isExcludedName(_ type: String) -> Bool {
        if ClipboardPasteboardKinds.isPreviewImage(type) || ClipboardPasteboardKinds.isPDF(type) { return true }
        let lower = type.lowercased()
        if lower.contains("pdf") || lower.contains("webarchive") || lower.contains("web archive") { return true }
        let compact = lower
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        if compact.contains("olesource") || compact.contains("embedsource") || compact.contains("dataobject") { return true }
        if compact.contains("objectdescriptor") || compact.contains("linksource") || compact.contains("objectlink") { return true }
        if compact.contains("ownerlink") || compact.contains("dsptext") || compact.contains("appbundleid") { return true }
        if compact.contains("hyperlink") { return true }
        if lower == "link" || lower.hasSuffix(" link") || lower.hasSuffix(".link") { return true }
        return false
    }

    private static func isXMLSpreadsheet(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower.contains("xml spreadsheet") || lower.contains("spreadsheetml") || lower.contains("xmlss")
    }

    private static func htmlText(in entries: [ClipboardPasteboardType]) -> String? {
        for entry in entries where ClipboardPasteboardKinds.isHTMLType(entry.type) {
            if let text = ClipboardCaptureDecision.decodeText(entry.data) { return text }
        }
        return nil
    }
}

enum SpreadsheetFormatParser {
    static func parseHTML(_ html: String) -> [SpreadsheetCellFormat]? {
        let formats = styleFormats(in: html)
        let defaultFormat = formats["td"] ?? "General"
        guard let rowExpression = try? NSRegularExpression(pattern: "(?is)<tr\\b[^>]*>(.*?)</tr>"),
              let cellExpression = try? NSRegularExpression(
                pattern: "(?is)<t[dh]\\b([^>]*)>(.*?)</t[dh]>|<t[dh]\\b([^>]*)/>"
              ) else {
            return nil
        }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        var cells: [SpreadsheetCellFormat] = []
        var rowIndex = 0
        for rowMatch in rowExpression.matches(in: html, range: full) {
            guard let bodyRange = Range(rowMatch.range(at: 1), in: html) else { continue }
            let body = String(html[bodyRange])
            let bodyRangeNS = NSRange(body.startIndex..<body.endIndex, in: body)
            var column = 0
            var sawCell = false
            for cellMatch in cellExpression.matches(in: body, range: bodyRangeNS) {
                let attributeRange = Range(cellMatch.range(at: 1), in: body) ?? Range(cellMatch.range(at: 3), in: body)
                let innerRange = Range(cellMatch.range(at: 2), in: body)
                let attributes = attributeRange.map { String(body[$0]) } ?? ""
                let inner = innerRange.map { String(body[$0]) } ?? ""
                let text = plainCellText(inner)
                let format = numberFormat(attributes: attributes, styles: formats, defaultFormat: defaultFormat)
                let type = attribute(attributes, named: "ss:Type") ?? attribute(attributes, named: "Type")
                let kind = cellKind(format: format, sourceType: type, markedText: attributes.range(of: "x:str", options: .caseInsensitive) != nil)
                let span = max(intAttribute(attributes, named: "colspan") ?? 1, 1)
                if !text.isEmpty || kind == .text || format != "General" {
                    cells.append(SpreadsheetCellFormat(
                        row: rowIndex,
                        column: column,
                        kind: kind,
                        numberFormat: kind == .text && (format == "General" || format.isEmpty) ? "@" : format,
                        text: text
                    ))
                }
                column += span
                sawCell = true
            }
            if sawCell { rowIndex += 1 }
        }
        return cells.isEmpty ? nil : cells
    }

    static func parseXML(_ data: Data) -> [SpreadsheetCellFormat]? {
        let parser = XMLParser(data: data)
        let delegate = XMLSpreadsheetParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.cells.isEmpty ? nil : delegate.cells
    }

    static func normalizedFormat(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 {
            let first = value.first
            let last = value.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
        }
        var current = value
        for _ in 0..<4 {
            var next = ""
            var characters = current.makeIterator()
            while let character = characters.next() {
                if character == "\\" {
                    if let escaped = characters.next() {
                        next.append(escaped)
                    }
                } else {
                    next.append(character)
                }
            }
            if next == current { break }
            current = next
        }
        switch current.lowercased() {
        case "fixed": return "0.00"
        case "standard": return "#,##0.00"
        case "percent": return "0%"
        case "general": return "General"
        case "@": return "@"
        default: return current.isEmpty ? "General" : current
        }
    }

    static func cellKind(format: String, sourceType: String?, markedText: Bool) -> SpreadsheetCellFormat.Kind {
        let type = sourceType?.lowercased()
        if markedText || type == "string" || format == "@" { return .text }
        if isTimeFormat(format) { return .time }
        if type == "datetime" || isDateFormat(format) { return .date }
        return .number
    }

    private static func isDateFormat(_ format: String) -> Bool {
        let lower = format.lowercased()
        return lower.contains("y") || lower.contains("d")
    }

    private static func isTimeFormat(_ format: String) -> Bool {
        let lower = format.lowercased()
        guard !lower.contains("y"), !lower.contains("d") else { return false }
        return lower.contains("h") || lower.contains("s")
    }

    private static func styleFormats(in html: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: "(?is)([.#]?[A-Za-z0-9_-]+)\\s*\\{([^}]*)\\}") else {
            return [:]
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var formats: [String: String] = [:]
        for match in expression.matches(in: html, range: range) {
            guard let selectorRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let selector = String(html[selectorRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(html[bodyRange])
            guard let format = msoNumberFormat(in: body) else { continue }
            let key = selector.hasPrefix(".") ? String(selector.dropFirst()) : selector
            formats[key.lowercased()] = normalizedFormat(format)
        }
        return formats
    }

    private static func msoNumberFormat(in body: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "(?i)mso-number-format\\s*:\\s*(\"(?:\\\\.|[^\"])*\"|'(?:\\\\.|[^'])*'|[^;}]+)"
        ) else { return nil }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = expression.firstMatch(in: body, range: range),
              let valueRange = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[valueRange])
    }

    private static func numberFormat(attributes: String, styles: [String: String], defaultFormat: String) -> String {
        if let inline = attribute(attributes, named: "style"), let format = msoNumberFormat(in: inline) {
            return normalizedFormat(format)
        }
        let classes = (attribute(attributes, named: "class") ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.lowercased() }
        for name in classes {
            if let format = styles[String(name)] { return format }
        }
        return defaultFormat
    }

    private static func attribute(_ attributes: String, named name: String) -> String? {
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = expression.firstMatch(in: attributes, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let valueRange = Range(match.range(at: index), in: attributes) {
                return String(attributes[valueRange])
            }
        }
        return nil
    }

    private static func intAttribute(_ attributes: String, named name: String) -> Int? {
        attribute(attributes, named: name).flatMap(Int.init)
    }

    private static func plainCellText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
        return decode(withoutTags).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ text: String) -> String {
        var decoded = text
        let named = [
            ("&nbsp;", " "),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&")
        ]
        for (entity, value) in named {
            decoded = decoded.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return decoded
    }
}

private final class XMLSpreadsheetParser: NSObject, XMLParserDelegate {
    var cells: [SpreadsheetCellFormat] = []
    private var styles: [String: String] = [:]
    private var styleID: String?
    private var styleFormat: String?
    private var row = 0
    private var nextRow = 1
    private var column = 0
    private var cellStyleID: String?
    private var cellType: String?
    private var cellText = ""
    private var inData = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch localName(elementName, qName) {
        case "style":
            styleID = attribute(attributes, "ID")
            styleFormat = nil
        case "numberformat":
            styleFormat = attribute(attributes, "Format")
        case "row":
            if let index = attribute(attributes, "Index").flatMap(Int.init), index > 0 {
                row = index - 1
                nextRow = index + 1
            } else {
                row = nextRow - 1
                nextRow += 1
            }
            column = 0
        case "cell":
            cellText = ""
            cellType = nil
            cellStyleID = attribute(attributes, "StyleID")
            if let index = attribute(attributes, "Index").flatMap(Int.init), index > 0 {
                column = index - 1
            }
        case "data":
            inData = true
            cellType = attribute(attributes, "Type")
            cellText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inData { cellText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qName) {
        case "style":
            if let styleID {
                styles[styleID] = SpreadsheetFormatParser.normalizedFormat(styleFormat ?? "")
            }
            styleID = nil
        case "data":
            inData = false
        case "cell":
            let format = SpreadsheetFormatParser.normalizedFormat(styles[cellStyleID ?? ""] ?? "")
            let kind = SpreadsheetFormatParser.cellKind(format: format, sourceType: cellType, markedText: false)
            let text = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || kind == .text {
                let numberFormat = kind == .text && (format == "General" || format.isEmpty) ? "@" : format
                cells.append(SpreadsheetCellFormat(
                    row: row,
                    column: column,
                    kind: kind,
                    numberFormat: numberFormat,
                    text: displayText(text, kind: kind)
                ))
            }
            column += 1
        default:
            break
        }
    }

    private func displayText(_ text: String, kind: SpreadsheetCellFormat.Kind) -> String {
        guard kind == .date || kind == .time, let separator = text.firstIndex(of: "T") else { return text }
        let date = text[..<separator]
        let time = text[text.index(after: separator)...].prefix(5)
        if kind == .time { return String(time) }
        return String(date)
    }

    private func localName(_ elementName: String, _ qName: String?) -> String {
        let raw = (qName?.isEmpty == false ? qName! : elementName)
        let name = raw.split(separator: ":").last.map(String.init) ?? raw
        return name.lowercased()
    }

    private func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let value = attributes[name] { return value }
        let suffix = ":\(name)"
        return attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame || $0.key.hasSuffix(suffix) }?.value
    }
}

/// Drops the picture Excel publishes after a cell copy, so the table stays the newest item.
enum SpreadsheetImageFollowUp {
    /// Large ranges take longer than a second to collapse into a TIFF. History on this Mac showed up to about two minutes.
    static let recentInterval: TimeInterval = 180

    struct Context: Equatable, Sendable {
        var sourceBundleID: String?
        var hasMeaningfulText: Bool
        var imagePayloads: [Data]
        var previousBundleID: String?
        var previousIsSpreadsheetText: Bool
        var previousCapturedAt: Date?
        var previousPreviewPayloads: [Data]
        var now: Date
        /// ClipFlow just wrote a spreadsheet pasteboard. Excel may replace it with the preview TIFF.
        var suppressingOwnRewrite: Bool
    }

    static func isSpreadsheetApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if bundleID == SpreadsheetClipboard.excelBundleID || bundleID == "com.apple.iWork.Numbers" { return true }
        if bundleID.hasPrefix("com.kingsoft.") || bundleID.localizedCaseInsensitiveContains("wpsoffice") { return true }
        return false
    }

    static func isSpreadsheetTextItem(_ item: ClipboardItem) -> Bool {
        guard !item.isImage, ClipboardCapture.isMeaningful(item.fullText) else { return false }
        if isSpreadsheetApp(item.sourceBundleID) { return true }
        if item.extraTypes?.contains(where: { ClipboardPasteboardKinds.isSpreadsheetNative($0.type) }) == true { return true }
        if let html = item.htmlData, let text = ClipboardCaptureDecision.decodeText(html), ClipboardHTMLText.isTabularDocument(text) {
            return true
        }
        return false
    }

    static func shouldIgnore(_ context: Context) -> Bool {
        guard isSpreadsheetApp(context.sourceBundleID) else { return false }
        guard !context.hasMeaningfulText else { return false }
        guard context.previousIsSpreadsheetText, let capturedAt = context.previousCapturedAt else { return false }
        let sameApp = context.previousBundleID == context.sourceBundleID || context.suppressingOwnRewrite
        guard sameApp else { return false }
        let recent = context.now.timeIntervalSince(capturedAt) <= recentInterval
        guard recent || context.suppressingOwnRewrite else { return false }
        let previewMatches = context.imagePayloads.contains { payload in
            context.previousPreviewPayloads.contains(payload)
        }
        // The follow-up board has no cell text. A matching stored preview is the same signal when the bytes survived.
        if previewMatches { return true }
        if !context.hasMeaningfulText { return true }
        return false
    }
}
