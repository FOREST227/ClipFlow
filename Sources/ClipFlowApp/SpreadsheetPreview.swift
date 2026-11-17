import Foundation

/// Rows and columns for a history preview. Built from text already stored on the item:
/// the plain-text TSV in `fullText`, the HTML table in `htmlData`, or an XML Spreadsheet
/// flavor in `extraTypes`. Nothing here writes the pasteboard or changes insert-into-Excel.
struct SpreadsheetPreviewGrid: Equatable, Sendable {
    var rows: [[String]]
    var columnCount: Int
    var omittedRowCount: Int
    var omittedColumnCount: Int

    var overflowCaption: String? {
        Self.overflowCaption(omittedRows: omittedRowCount, omittedColumns: omittedColumnCount)
    }

    static func overflowCaption(omittedRows: Int, omittedColumns: Int) -> String? {
        switch (omittedRows > 0, omittedColumns > 0) {
        case (true, true):
            return "还有 \(omittedRows) 行、\(omittedColumns) 列未显示"
        case (true, false):
            return "还有 \(omittedRows) 行未显示"
        case (false, true):
            return "还有 \(omittedColumns) 列未显示"
        case (false, false):
            return nil
        }
    }
}

enum SpreadsheetPreview {
    static let tableLabel = "表格"
    /// Enough to scroll through a normal copy. Larger sheets keep a visible cue instead of building every cell.
    static let maxRows = 120
    static let maxColumns = 32

    static func grid(for item: ClipboardItem) -> SpreadsheetPreviewGrid? {
        guard !item.isImage, isRecognized(item), let measured = bestMeasured(for: item) else { return nil }
        return finalize(measured)
    }

    static func presentsAsTable(_ item: ClipboardItem) -> Bool {
        grid(for: item) != nil
    }

    /// Detail and list badges. The stored kind stays text so paste behavior does not change.
    static func typeLabel(for item: ClipboardItem) -> String {
        presentsAsTable(item) ? tableLabel : item.kind.label
    }

    static func title(for item: ClipboardItem) -> String {
        guard presentsAsTable(item), item.title == item.kind.label else { return item.title }
        return tableLabel
    }

    static func symbolName(for item: ClipboardItem) -> String {
        presentsAsTable(item) ? "tablecells" : item.kind.symbolName
    }

    /// One cell still fits the compact row. Two or more cells need the taller card the code rows already use.
    static func usesExpandedListRow(_ item: ClipboardItem) -> Bool {
        guard let grid = grid(for: item) else { return false }
        return grid.rows.count > 1 || grid.columnCount > 1
    }

    static func spokenSummary(for item: ClipboardItem) -> String? {
        guard let first = grid(for: item)?.rows.first else { return nil }
        let cells = first.prefix(4).map { cell in
            cell.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !cells.isEmpty else { return nil }
        let line = cells.joined(separator: "，")
        if line.count <= 80 { return line }
        return String(line.prefix(80))
    }

    private static func isRecognized(_ item: ClipboardItem) -> Bool {
        if item.labels.contains(tableLabel) { return true }
        if item.extraTypes?.contains(where: { ClipboardPasteboardKinds.isSpreadsheetNative($0.type) }) == true {
            return true
        }
        if let html = htmlString(in: item), ClipboardHTMLText.isTabularDocument(html) { return true }
        return false
    }

    /// A multi-column TSV is the display text Excel put on the pasteboard, so it wins without parsing HTML.
    /// A single column, or no TSV, loses to an HTML table that still has the missing columns.
    private static func bestMeasured(for item: ClipboardItem) -> MeasuredGrid? {
        let tsv = SpreadsheetInsertRange.parse(item.fullText).flatMap(measure)
        if let tsv, tsv.columnCount > 1 { return tsv }
        let html = htmlMeasured(in: item)
        let ranked = [tsv, html].compactMap { $0 }
        if var best = ranked.first {
            for candidate in ranked.dropFirst() where structure(candidate) > structure(best) {
                best = candidate
            }
            return best
        }
        return xmlMeasured(in: item)
    }

    private static func structure(_ grid: MeasuredGrid) -> (Int, Int) {
        (grid.columnCount, grid.rowCount)
    }

    private static func htmlMeasured(in item: ClipboardItem) -> MeasuredGrid? {
        guard let html = htmlString(in: item), ClipboardHTMLText.isTabularDocument(html),
              let cells = SpreadsheetFormatParser.parseHTML(html) else { return nil }
        return measure(cells: cells)
    }

    private static func xmlMeasured(in item: ClipboardItem) -> MeasuredGrid? {
        guard let data = item.extraTypes?.first(where: isXMLSpreadsheet)?.data,
              let cells = SpreadsheetFormatParser.parseXML(data) else { return nil }
        return measure(cells: cells)
    }

    private static func htmlString(in item: ClipboardItem) -> String? {
        if let data = item.htmlData, let text = ClipboardCaptureDecision.decodeText(data) { return text }
        guard let entries = item.extraTypes else { return nil }
        for entry in entries where ClipboardPasteboardKinds.isHTMLType(entry.type) {
            if let text = ClipboardCaptureDecision.decodeText(entry.data) { return text }
        }
        return nil
    }

    private static func isXMLSpreadsheet(_ entry: ClipboardPasteboardType) -> Bool {
        let lower = entry.type.lowercased()
        return lower.contains("xml spreadsheet") || lower.contains("spreadsheetml") || lower.contains("xmlss")
    }

    private static func measure(_ rows: [[String]]) -> MeasuredGrid? {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0, !rows.isEmpty else { return nil }
        return MeasuredGrid(rows: rows, rowCount: rows.count, columnCount: columns)
    }

    /// Cell indexes already account for skipped blanks and colspan, so empty columns stay put.
    private static func measure(cells: [SpreadsheetCellFormat]) -> MeasuredGrid? {
        let valid = cells.filter { $0.row >= 0 && $0.column >= 0 }
        guard let maxRow = valid.map(\.row).max(), let maxColumn = valid.map(\.column).max() else { return nil }
        let rowCount = maxRow + 1
        let columnCount = maxColumn + 1
        let shownRows = min(rowCount, maxRows)
        let shownColumns = min(columnCount, maxColumns)
        var rows = Array(repeating: Array(repeating: "", count: shownColumns), count: shownRows)
        for cell in valid where cell.row < shownRows && cell.column < shownColumns {
            rows[cell.row][cell.column] = cell.text
        }
        return MeasuredGrid(rows: rows, rowCount: rowCount, columnCount: columnCount)
    }

    private static func finalize(_ measured: MeasuredGrid) -> SpreadsheetPreviewGrid? {
        let shownRows = min(measured.rowCount, maxRows)
        let shownColumns = min(measured.columnCount, maxColumns)
        let visible = measured.rows.prefix(shownRows).map { row -> [String] in
            let padded = row.count >= shownColumns
                ? row
                : row + Array(repeating: "", count: shownColumns - row.count)
            return Array(padded.prefix(shownColumns))
        }
        let rows = Array(visible)
        guard rows.contains(where: { $0.contains(where: ClipboardCapture.isMeaningful) }) else { return nil }
        return SpreadsheetPreviewGrid(
            rows: rows,
            columnCount: shownColumns,
            omittedRowCount: measured.rowCount - shownRows,
            omittedColumnCount: measured.columnCount - shownColumns
        )
    }
}

private struct MeasuredGrid {
    var rows: [[String]]
    var rowCount: Int
    var columnCount: Int
}
