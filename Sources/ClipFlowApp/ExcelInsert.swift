import AppKit
import Foundation

/// Rows and columns of a TSV grid. Quoted fields keep embedded newlines inside the cell.
struct SpreadsheetInsertRange: Equatable, Sendable {
    var rows: Int
    var columns: Int

    static let maxRows = 10_000
    static let maxColumns = 1_024

    static func measure(tsv: String) -> SpreadsheetInsertRange? {
        guard let grid = parse(tsv), !grid.isEmpty else { return nil }
        let columns = grid.map(\.count).max() ?? 0
        guard columns > 0, grid.count <= maxRows, columns <= maxColumns else { return nil }
        return SpreadsheetInsertRange(rows: grid.count, columns: columns)
    }

    /// Excel wraps a field in quotes when it contains a tab, quote, or newline, and doubles quotes inside it.
    static func parse(_ tsv: String) -> [[String]]? {
        guard !tsv.isEmpty else { return nil }
        // `\r\n` is one Swift Character, so walk scalars or a Windows row break stays inside the cell.
        let scalars = Array(tsv.unicodeScalars)
        let quote = UnicodeScalar("\"")
        let tab = UnicodeScalar("\t")
        let lineFeed = UnicodeScalar("\n")
        let carriageReturn = UnicodeScalar("\r")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == quote {
                    if index + 1 < scalars.count, scalars[index + 1] == quote {
                        field.unicodeScalars.append(quote)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            if scalar == quote, field.isEmpty {
                inQuotes = true
                index += 1
                continue
            }
            if scalar == tab {
                row.append(field)
                field = ""
                index += 1
                continue
            }
            if scalar == lineFeed || scalar == carriageReturn {
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                if scalar == carriageReturn, index + 1 < scalars.count, scalars[index + 1] == lineFeed {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            field.unicodeScalars.append(scalar)
            index += 1
        }
        if inQuotes {
            row.append(field)
            rows.append(row)
        } else if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        let hasCell = rows.contains { row in row.contains { ClipboardCapture.isMeaningful($0) } }
        guard hasCell else { return nil }
        return rows
    }
}

enum SpreadsheetShift: Equatable, Sendable {
    case down
    case right

    var menuTitle: String {
        switch self {
        case .down: "插入到 Excel（下移单元格）"
        case .right: "插入到 Excel（右移单元格）"
        }
    }

    var statusWord: String {
        switch self {
        case .down: "下移"
        case .right: "右移"
        }
    }

    /// Enumerator name in Excel's scripting dictionary (`XlInsertShiftDirection`).
    var appleScriptTerm: String {
        switch self {
        case .down: "shift down"
        case .right: "shift to right"
        }
    }
}

enum SpreadsheetClipboard {
    static let excelBundleID = "com.microsoft.Excel"
    static let copyOnlyTitle = "只放回剪贴板（不粘贴）"
    static let copyOnlyStatus = "已放回剪贴板，未粘贴。可在 Excel 中使用选择性粘贴或「插入复制的单元格」。若这次复制的 Excel 会话已经结束，该命令可能不可用，可改用「插入到 Excel」。"

    static func hasOriginalTypes(_ item: ClipboardItem) -> Bool {
        item.extraTypes?.isEmpty == false
    }

    static func hasTabularData(_ item: ClipboardItem) -> Bool {
        guard !item.isImage else { return false }
        let native = item.extraTypes?.contains { ClipboardPasteboardKinds.isSpreadsheetNative($0.type) } == true
        let tableHTML: Bool = {
            guard let data = item.htmlData, let html = ClipboardCaptureDecision.decodeText(data) else { return false }
            return ClipboardHTMLText.isTabularDocument(html)
        }()
        let tsv = item.fullText.contains("\t")
        guard native || tableHTML || tsv else { return false }
        return SpreadsheetInsertRange.measure(tsv: item.fullText) != nil
    }
}

enum ExcelInsertOffer {
    static func shouldOffer(item: ClipboardItem, bundleIDs: [String?]) -> Bool {
        guard bundleIDs.contains(where: { $0 == SpreadsheetClipboard.excelBundleID }) else { return false }
        return SpreadsheetClipboard.hasTabularData(item)
    }
}

@MainActor
enum ExcelInsertContext {
    static var lastBundleID: String?

    static func currentBundleIDs() -> [String?] {
        [NSWorkspace.shared.frontmostApplication?.bundleIdentifier, lastBundleID]
    }
}

enum ExcelInsertOutcome: Equatable {
    case inserted
    case notPermitted
    case failed
}

/// Builds the Excel Apple event that inserts a rectangle at the active cell, then selects that cell for paste.
enum ExcelCellInserter {
    static func script(rows: Int, columns: Int, shift: SpreadsheetShift) -> String? {
        guard rows > 0, columns > 0, rows <= SpreadsheetInsertRange.maxRows, columns <= SpreadsheetInsertRange.maxColumns else {
            return nil
        }
        return """
        tell application "Microsoft Excel"
            if (count of workbooks) is 0 then error "ClipFlow: no workbook"
            set anchorCell to active cell
            set destRange to get resize anchorCell row size \(rows) column size \(columns)
            insert into range destRange shift \(shift.appleScriptTerm)
            select anchorCell
        end tell
        """
    }

    static func isPermissionDenial(number: Int, message: String?) -> Bool {
        if number == -1743 || number == -1744 { return true }
        let lower = message?.lowercased() ?? ""
        return lower.contains("not authorized") || lower.contains("not permitted") || lower.contains("不允许")
    }

    @MainActor
    static func insert(rows: Int, columns: Int, shift: SpreadsheetShift, runner: @MainActor (String) -> ExcelInsertOutcome = ExcelAppleScript.run) -> ExcelInsertOutcome {
        guard let source = script(rows: rows, columns: columns, shift: shift) else { return .failed }
        return runner(source)
    }
}

@MainActor
enum ExcelAvailability {
    static var isRunning: () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SpreadsheetClipboard.excelBundleID).isEmpty
    }
    static var application: () -> NSRunningApplication? = {
        NSRunningApplication.runningApplications(withBundleIdentifier: SpreadsheetClipboard.excelBundleID).first
    }
}

enum ExcelAppleScript {
    @MainActor
    static func run(_ source: String) -> ExcelInsertOutcome {
        guard let script = NSAppleScript(source: source) else { return .failed }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return .inserted }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            ?? (error["NSAppleScriptErrorNumber"] as? Int)
            ?? 0
        let message = error[NSAppleScript.errorMessage] as? String
        if ExcelCellInserter.isPermissionDenial(number: number, message: message) {
            return .notPermitted
        }
        return .failed
    }
}
