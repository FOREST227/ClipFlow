import Compression
import Foundation

/// Reads the workbook Mac Excel nests in `Embed-Source`.
///
/// The HTML flavor for a text-formatted block often says General and has no `x:str`, so a paste turns
/// `2025-11-01` into the serial 45962. The embedded worksheet still has `t="inlineStr"` for those cells
/// and a real number format on the others. The package is parsed here and never written back to the pasteboard.
enum SpreadsheetPackageParser {
    static func parse(_ data: Data, rows: Int? = nil, columns: Int? = nil) -> [SpreadsheetCellFormat]? {
        guard let parts = ZipArchive.extract(data) else { return nil }
        let styles = parts["xl/styles.xml"].flatMap(StyleTable.init(xml:)) ?? StyleTable()
        let shared = parts["xl/sharedstrings.xml"].flatMap(SharedStrings.init(xml:)) ?? SharedStrings(values: [])
        let sheets = parts.compactMap { name, xml -> WorksheetSnapshot? in
            guard name.hasPrefix("xl/worksheets/"), name.hasSuffix(".xml") else { return nil }
            return WorksheetSnapshot(xml: xml, shared: shared)
        }
        guard !sheets.isEmpty else { return nil }
        let ordered = sheets.sorted { lhs, rhs in
            if lhs.tabSelected != rhs.tabSelected { return lhs.tabSelected }
            return false
        }
        for sheet in ordered {
            if let cells = sheet.cells(styles: styles, rows: rows, columns: columns), !cells.isEmpty {
                return cells
            }
        }
        return nil
    }
}

private struct StyleTable {
    var formats: [String]

    init() {
        formats = ["General"]
    }

    init?(xml: Data) {
        let parser = XMLParser(data: xml)
        let delegate = StyleParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        formats = delegate.formats
    }

    func format(at index: Int) -> String {
        guard index >= 0, formats.indices.contains(index) else { return "General" }
        return formats[index]
    }
}

private struct SharedStrings {
    var values: [String]

    init(values: [String]) {
        self.values = values
    }

    init?(xml: Data) {
        let parser = XMLParser(data: xml)
        let delegate = SharedStringParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        values = delegate.values
    }
}

private struct WorksheetSnapshot {
    var tabSelected: Bool
    var areas: [CellArea]
    var stored: [StoredCell]

    init?(xml: Data, shared: SharedStrings) {
        let parser = XMLParser(data: xml)
        let delegate = WorksheetParser(shared: shared)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        tabSelected = delegate.tabSelected
        areas = delegate.selection.flatMap(CellArea.parse(sqref:)) ?? []
        stored = delegate.cells
    }

    func cells(styles: StyleTable, rows: Int?, columns: Int?) -> [SpreadsheetCellFormat]? {
        let area = Self.matchingArea(areas: areas, stored: stored, rows: rows, columns: columns)
        guard let area else { return nil }
        var seen: [String: SpreadsheetCellFormat] = [:]
        for cell in stored {
            guard area.contains(row: cell.row, column: cell.column) else { continue }
            let format = styles.format(at: cell.style)
            let relativeRow = cell.row - area.row
            let relativeColumn = cell.column - area.column
            guard relativeRow >= 0, relativeColumn >= 0 else { continue }
            let mapped = map(cell, format: format, row: relativeRow, column: relativeColumn)
            guard let mapped else { continue }
            seen["\(relativeRow),\(relativeColumn)"] = mapped
        }
        let cells = seen.values.sorted {
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.column < $1.column
        }
        return cells.isEmpty ? nil : cells
    }

    private func map(_ cell: StoredCell, format: String, row: Int, column: Int) -> SpreadsheetCellFormat? {
        switch cell.value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, format == "General" || format.isEmpty { return nil }
            let numberFormat = format.isEmpty ? "General" : format
            return SpreadsheetCellFormat(row: row, column: column, kind: .text, numberFormat: numberFormat, text: trimmed)
        case .number(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, format == "General" || format.isEmpty { return nil }
            let numberFormat = format.isEmpty ? "General" : format
            let kind = SpreadsheetFormatParser.cellKind(format: numberFormat, sourceType: cell.sourceType, markedText: false)
            return SpreadsheetCellFormat(row: row, column: column, kind: kind, numberFormat: numberFormat, text: trimmed)
        }
    }

    private static func matchingArea(areas: [CellArea], stored: [StoredCell], rows: Int?, columns: Int?) -> CellArea? {
        if let rows, let columns {
            if let match = areas.first(where: { $0.rows == rows && $0.columns == columns }) {
                return match
            }
            if let box = CellArea.bounding(stored), box.rows == rows, box.columns == columns {
                return box
            }
            return nil
        }
        if let largest = areas.max(by: { $0.rows * $0.columns < $1.rows * $1.columns }) {
            return largest
        }
        return CellArea.bounding(stored)
    }
}

private struct CellArea: Equatable {
    /// 1-based origin, matching worksheet cell references.
    var row: Int
    var column: Int
    var rows: Int
    var columns: Int

    func contains(row: Int, column: Int) -> Bool {
        row >= self.row && row < self.row + rows && column >= self.column && column < self.column + columns
    }

    static func bounding(_ cells: [StoredCell]) -> CellArea? {
        guard let first = cells.first else { return nil }
        var minRow = first.row
        var maxRow = first.row
        var minColumn = first.column
        var maxColumn = first.column
        for cell in cells.dropFirst() {
            minRow = min(minRow, cell.row)
            maxRow = max(maxRow, cell.row)
            minColumn = min(minColumn, cell.column)
            maxColumn = max(maxColumn, cell.column)
        }
        return CellArea(row: minRow, column: minColumn, rows: maxRow - minRow + 1, columns: maxColumn - minColumn + 1)
    }

    static func parse(sqref: String) -> [CellArea] {
        sqref.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { token in
            var part = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            if let bang = part.lastIndex(of: "!") {
                part = String(part[part.index(after: bang)...])
            }
            let pieces = part.split(separator: ":").map(String.init)
            guard let start = parseCellRef(pieces[0]) else { return nil }
            let end = pieces.count > 1 ? parseCellRef(pieces[1]) ?? start : start
            let row = min(start.row, end.row)
            let column = min(start.column, end.column)
            return CellArea(
                row: row,
                column: column,
                rows: abs(end.row - start.row) + 1,
                columns: abs(end.column - start.column) + 1
            )
        }
    }

    static func parseCellRef(_ ref: String) -> (row: Int, column: Int)? {
        let cleaned = ref.replacingOccurrences(of: "$", with: "")
        let letters = cleaned.prefix { $0.isLetter }
        let digits = cleaned.drop { $0.isLetter }
        guard !letters.isEmpty, let row = Int(digits), row > 0, let column = columnNumber(String(letters)) else {
            return nil
        }
        return (row, column)
    }

    static func columnNumber(_ letters: String) -> Int? {
        var number = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar >= "A", scalar <= "Z" else { return nil }
            number = number * 26 + Int(scalar.value - 64)
            if number > 16_384 { return nil }
        }
        return number > 0 ? number : nil
    }
}

private struct StoredCell {
    enum Value {
        case text(String)
        case number(String)
    }

    var row: Int
    var column: Int
    var style: Int
    var value: Value
    var sourceType: String?
}

private final class StyleParser: NSObject, XMLParserDelegate {
    private static let builtin: [Int: String] = [
        0: "General",
        1: "0",
        2: "0.00",
        3: "#,##0",
        4: "#,##0.00",
        9: "0%",
        10: "0.00%",
        11: "0.00E+00",
        12: "# ?/?",
        13: "# ??/??",
        14: "mm-dd-yy",
        15: "d-mmm-yy",
        16: "d-mmm",
        17: "mmm-yy",
        18: "h:mm AM/PM",
        19: "h:mm:ss AM/PM",
        20: "h:mm",
        21: "h:mm:ss",
        22: "m/d/yy h:mm",
        37: "#,##0_);(#,##0)",
        38: "#,##0_);[Red](#,##0)",
        39: "#,##0.00_);(#,##0.00)",
        40: "#,##0.00_);[Red](#,##0.00)",
        45: "mm:ss",
        46: "[h]:mm:ss",
        47: "mmss.0",
        48: "##0.0E+0",
        49: "@"
    ]

    var formats: [String] = []
    private var custom: [Int: String] = [:]
    private var inCellXfs = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch localName(elementName, qName) {
        case "numfmt":
            if let id = attribute(attributes, "numFmtId").flatMap(Int.init),
               let code = attribute(attributes, "formatCode") {
                custom[id] = code
            }
        case "cellxfs":
            inCellXfs = true
        case "xf" where inCellXfs:
            let id = attribute(attributes, "numFmtId").flatMap(Int.init) ?? 0
            formats.append(resolve(id))
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if localName(elementName, qName) == "cellxfs" {
            inCellXfs = false
        }
    }

    private func resolve(_ id: Int) -> String {
        let raw = custom[id] ?? Self.builtin[id] ?? "General"
        return SpreadsheetFormatParser.normalizedFormat(raw)
    }
}

private final class SharedStringParser: NSObject, XMLParserDelegate {
    var values: [String] = []
    private var buffer = ""
    private var capture = false
    private var inPhonetic = false
    private var inItem = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch localName(elementName, qName) {
        case "si":
            inItem = true
            buffer = ""
        case "rph":
            inPhonetic = true
        case "t" where inItem && !inPhonetic:
            capture = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qName) {
        case "t":
            capture = false
        case "rph":
            inPhonetic = false
        case "si":
            values.append(buffer)
            inItem = false
            buffer = ""
        default:
            break
        }
    }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    var tabSelected = false
    var selection: String?
    var cells: [StoredCell] = []

    private let shared: SharedStrings
    private var row = 1
    private var nextRow = 1
    private var nextColumn = 1
    private var cellRow = 1
    private var cellColumn = 1
    private var cellStyle = 0
    private var cellType: String?
    private var buffer = ""
    private var capture = false
    private var inPhonetic = false
    private var inCell = false

    init(shared: SharedStrings) {
        self.shared = shared
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch localName(elementName, qName) {
        case "sheetview":
            if attribute(attributes, "tabSelected") == "1" {
                tabSelected = true
            }
        case "selection":
            if selection == nil {
                selection = attribute(attributes, "sqref")
            }
        case "row":
            if let index = attribute(attributes, "r").flatMap(Int.init), index > 0 {
                row = index
                nextRow = index + 1
            } else {
                row = nextRow
                nextRow += 1
            }
            nextColumn = 1
        case "c":
            inCell = true
            buffer = ""
            cellType = attribute(attributes, "t")?.lowercased()
            cellStyle = attribute(attributes, "s").flatMap(Int.init) ?? 0
            if let ref = attribute(attributes, "r"), let parsed = CellArea.parseCellRef(ref) {
                cellRow = parsed.row
                cellColumn = parsed.column
                nextColumn = parsed.column + 1
            } else {
                cellRow = row
                cellColumn = nextColumn
                nextColumn += 1
            }
        case "rph":
            inPhonetic = true
        case "v":
            capture = true
            buffer = ""
        case "t" where inCell && !inPhonetic:
            capture = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qName) {
        case "v", "t":
            capture = false
        case "rph":
            inPhonetic = false
        case "c":
            if let cell = makeCell() {
                cells.append(cell)
            }
            inCell = false
            buffer = ""
        default:
            break
        }
    }

    private func makeCell() -> StoredCell? {
        let raw = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = cellType ?? ""
        let value: StoredCell.Value
        let sourceType: String?
        switch type {
        case "inlinestr", "str":
            value = .text(buffer)
            sourceType = "String"
        case "s":
            guard let index = Int(raw), shared.values.indices.contains(index) else { return nil }
            value = .text(shared.values[index])
            sourceType = "String"
        case "b":
            value = .text(raw == "1" ? "TRUE" : "FALSE")
            sourceType = "String"
        case "e":
            value = .text(raw)
            sourceType = "String"
        case "d":
            value = .number(raw)
            sourceType = "DateTime"
        default:
            value = .number(raw)
            sourceType = "Number"
        }
        return StoredCell(row: cellRow, column: cellColumn, style: cellStyle, value: value, sourceType: sourceType)
    }
}

/// Minimal ZIP reader for the stored and deflated parts inside an OLE package.
private enum ZipArchive {
    private static let localSignature = 0x04034b50
    private static let maximumEntry = 32 * 1024 * 1024

    static func extract(_ data: Data) -> [String: Data]? {
        let bytes = [UInt8](data)
        guard let start = bytes.indices.dropLast(3).first(where: { index in
            bytes[index] == 0x50 && bytes[index + 1] == 0x4B && bytes[index + 2] == 0x03 && bytes[index + 3] == 0x04
        }) else { return nil }
        var cursor = start
        var files: [String: Data] = [:]
        while cursor + 30 <= bytes.count {
            let signature = integer(bytes, cursor, 4)
            if signature != localSignature { break }
            let method = integer(bytes, cursor + 8, 2)
            let compressedSize = integer(bytes, cursor + 18, 4)
            let uncompressedSize = integer(bytes, cursor + 22, 4)
            let nameLength = integer(bytes, cursor + 26, 2)
            let extraLength = integer(bytes, cursor + 28, 2)
            let nameStart = cursor + 30
            let dataStart = nameStart + nameLength + extraLength
            guard nameLength >= 0, extraLength >= 0, compressedSize >= 0, dataStart + compressedSize <= bytes.count else {
                return nil
            }
            let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""
            let compressed = Data(bytes[dataStart..<(dataStart + compressedSize)])
            if wanted(name) {
                guard let payload = inflate(compressed, method: method, size: uncompressedSize) else { return nil }
                files[name.lowercased()] = payload
            }
            cursor = dataStart + compressedSize
        }
        return files.isEmpty ? nil : files
    }

    private static func wanted(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "xl/styles.xml" || lower == "xl/sharedstrings.xml" { return true }
        return lower.hasPrefix("xl/worksheets/") && lower.hasSuffix(".xml")
    }

    private static func inflate(_ data: Data, method: Int, size: Int) -> Data? {
        guard size >= 0, size <= maximumEntry else { return nil }
        if method == 0 {
            return data.count == size ? data : nil
        }
        guard method == 8, size > 0 else { return nil }
        var output = Data(count: size)
        let decoded = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(destinationBase, size, sourceBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == size else { return nil }
        return output
    }

    private static func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        guard offset >= 0, count > 0, offset + count <= bytes.count else { return -1 }
        var value = 0
        for shift in 0..<count {
            value |= Int(bytes[offset + shift]) << (8 * shift)
        }
        return value
    }
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
