import AppKit
import XCTest
@testable import ClipFlowApp

/// Drives Microsoft Excel on this Mac. Skipped unless CLIPFLOW_LIVE_EXCEL=1.
@MainActor
final class ExcelInsertLiveTests: XCTestCase {
    func testBothInsertsKeepTextDatesNumbersAndMixedFormats() throws {
        guard ProcessInfo.processInfo.environment["CLIPFLOW_LIVE_EXCEL"] == "1" else { return }
        let grid = try loadReportGrid()
        XCTAssertEqual(grid.count, 23)
        XCTAssertTrue(grid.allSatisfy { $0.count == 6 })

        let proof = try appleString("""
        tell application "Microsoft Excel"
            set proofBook to make new workbook
            return name of proofBook
        end tell
        """)
        defer {
            _ = try? appleString("""
            tell application "Microsoft Excel"
                if exists workbook "\(proof)" then close workbook "\(proof)" saving no
            end tell
            """)
        }

        try appleVoid(writeGridScript(grid, range: "A1:F23", book: proof, thenGeneral: true))
        try appleVoid("""
        tell application "Microsoft Excel"
            set ws to worksheet 1 of workbook "\(proof)"
            set number format of cell 80 of column 1 of ws to "@"
            set value of cell 80 of column 1 of ws to "00123"
            set number format of cell 80 of column 2 of ws to "yyyy-mm-dd"
            set value of cell 80 of column 2 of ws to 45962
            set number format of cell 80 of column 3 of ws to "hh:mm"
            set value of cell 80 of column 3 of ws to 0.3958333333
            set number format of cell 80 of column 4 of ws to "0.00"
            set value of cell 80 of column 4 of ws to 42.1
        end tell
        """)

        let captured = try copyAndCapture(book: proof, range: "A1:F23")
        let item = ClipboardClassifier.makeItem(
            text: captured.text,
            sourceApp: "Microsoft Excel",
            sourceBundleID: "com.microsoft.Excel",
            autoProtectSecrets: false,
            existingItem: nil,
            richContent: captured.snapshot
        )
        let measured = try XCTUnwrap(SpreadsheetInsertRange.measure(tsv: item.fullText))
        XCTAssertEqual(measured, SpreadsheetInsertRange(rows: 23, columns: 6), item.fullText.debugDescription)
        let replayed = SpreadsheetReplay.pasteRecords(from: item.extraTypes ?? []).map(\.type)
        XCTAssertFalse(replayed.contains { $0.localizedCaseInsensitiveContains("embed") })
        XCTAssertFalse(replayed.contains { $0.localizedCaseInsensitiveContains("tiff") || $0.localizedCaseInsensitiveContains("pdf") })
        let parsed = SpreadsheetReplay.cells(in: item.extraTypes ?? [], htmlData: item.htmlData, rows: 23, columns: 6)
        XCTAssertEqual(parsed.count, 138, "parsed \(parsed.count) from flavors \(item.extraTypes?.map(\.type) ?? [])")
        XCTAssertTrue(parsed.allSatisfy { $0.kind == SpreadsheetCellFormat.Kind.text && $0.numberFormat == "General" })
        XCTAssertEqual(parsed.first?.text, "2025-11-01")
        XCTAssertEqual(parsed.first { $0.row == 0 && $0.column == 5 }?.text, "5026.70505")
        XCTAssertEqual(parsed.first { $0.row == 4 && $0.column == 5 }?.text, "0.14472")

        let (directory, defaults, payloads) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        store.ingestCopiedText(
            item.fullText,
            sourceApp: item.sourceApp,
            sourceBundleID: item.sourceBundleID,
            richContent: ClipboardRepresentations.Snapshot(
                rtfData: item.rtfData,
                htmlData: item.htmlData,
                fileURLs: [],
                extraTypes: item.extraTypes ?? []
            )
        )
        let stored = try XCTUnwrap(store.items.first)
        let service = PasteService(store: store, pasteboard: .general, commitPaste: { _ in })

        try leaveCopyMode()
        try selectCell(book: proof, row: 1, column: 8)
        service.insertIntoExcel(stored, shift: .down)
        XCTAssertTrue(store.lastCaptureStatus.contains("下移"), store.lastCaptureStatus)
        try assertTextGrid(book: proof, originRow: 1, originColumn: 8, grid: grid)

        let capturedAgain = try copyAndCapture(book: proof, range: "A1:F23")
        store.ingestCopiedText(
            capturedAgain.text,
            sourceApp: "Microsoft Excel",
            sourceBundleID: "com.microsoft.Excel",
            richContent: capturedAgain.snapshot
        )
        let storedAgain = try XCTUnwrap(store.items.first)
        try leaveCopyMode()
        try selectCell(book: proof, row: 40, column: 8)
        service.insertIntoExcel(storedAgain, shift: .right)
        XCTAssertTrue(store.lastCaptureStatus.contains("右移"), store.lastCaptureStatus)
        try assertTextGrid(book: proof, originRow: 40, originColumn: 8, grid: grid)

        let mixed = try copyAndCapture(book: proof, range: "A80:D80")
        let mixedItemText = mixed.text
        store.ingestCopiedText(
            mixedItemText,
            sourceApp: "Microsoft Excel",
            sourceBundleID: "com.microsoft.Excel",
            richContent: mixed.snapshot
        )
        let mixedStored = try XCTUnwrap(store.items.first)
        let mixedCells = SpreadsheetReplay.cells(
            in: mixedStored.extraTypes ?? [],
            htmlData: mixedStored.htmlData,
            rows: 1,
            columns: 4
        )
        XCTAssertEqual(mixedCells.map(\.kind), [.text, .date, .time, .number])
        XCTAssertEqual(mixedCells.map(\.numberFormat), ["@", "yyyy-mm-dd", "hh:mm", "0.00"])

        try leaveCopyMode()
        try selectCell(book: proof, row: 80, column: 8)
        service.insertIntoExcel(mixedStored, shift: .down)
        try assertMixed(book: proof, row: 80, column: 8)

        let mixedAgain = try copyAndCapture(book: proof, range: "A80:D80")
        store.ingestCopiedText(
            mixedAgain.text,
            sourceApp: "Microsoft Excel",
            sourceBundleID: "com.microsoft.Excel",
            richContent: mixedAgain.snapshot
        )
        try leaveCopyMode()
        try selectCell(book: proof, row: 82, column: 8)
        service.insertIntoExcel(try XCTUnwrap(store.items.first), shift: .right)
        try assertMixed(book: proof, row: 82, column: 8)

        if let directory = ProcessInfo.processInfo.environment["CLIPFLOW_SHOT_DIR"] {
            try appleVoid("""
            tell application "Microsoft Excel"
                activate
                set ws to worksheet 1 of workbook "\(proof)"
                select range "H1:M6" of ws
            end tell
            """)
            Thread.sleep(forTimeInterval: 0.4)
            captureFrontWindow(to: URL(fileURLWithPath: directory).appendingPathComponent("insert-down-text.png"))
            try appleVoid("""
            tell application "Microsoft Excel"
                set ws to worksheet 1 of workbook "\(proof)"
                select range "H80:K82" of ws
            end tell
            """)
            Thread.sleep(forTimeInterval: 0.3)
            captureFrontWindow(to: URL(fileURLWithPath: directory).appendingPathComponent("insert-mixed-formats.png"))
        }
    }

    private func captureFrontWindow(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let windowID = info?.compactMap { window -> Int? in
            guard (window[kCGWindowOwnerName as String] as? String)?.contains("Excel") == true else { return nil }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            return window[kCGWindowNumber as String] as? Int
        }.first
        guard let windowID else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(windowID), url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private func assertTextGrid(book: String, originRow: Int, originColumn: Int, grid: [[String]]) throws {
        let rows = grid.count
        let columns = grid[0].count
        let report = try appleString("""
        set fieldBreak to character id 9
        tell application "Microsoft Excel"
            set ws to worksheet 1 of workbook "\(book)"
            set bad to ""
            set out to ""
            repeat with r from \(originRow) to \(originRow + rows - 1)
                set lineText to ""
                repeat with c from \(originColumn) to \(originColumn + columns - 1)
                    set target to cell r of column c of ws
                    set cls to class of (value of target) as string
                    set fmt to number format of target as string
                    set shown to string value of target as string
                    if cls does not contain "text" or fmt is not "General" then
                        set bad to bad & "r" & r & "c" & c & " " & cls & " " & fmt & " " & shown & linefeed
                    end if
                    if lineText is not "" then set lineText to lineText & fieldBreak
                    set lineText to lineText & shown
                end repeat
                set out to out & lineText & linefeed
            end repeat
            return bad & "----" & linefeed & out
        end tell
        """)
        let parts = report.components(separatedBy: "----\n")
        XCTAssertEqual(parts.count, 2, report)
        XCTAssertEqual(parts[0], "", "cells lost text or General format:\n\(parts[0])")
        let actual = parts[1].replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let expected = grid.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        XCTAssertEqual(actual, expected)
    }

    private func assertMixed(book: String, row: Int, column: Int) throws {
        let report = try appleString("""
        tell application "Microsoft Excel"
            set ws to worksheet 1 of workbook "\(book)"
            set reports to {}
            repeat with delta from 0 to 3
                set target to cell \(row) of column (\(column) + delta) of ws
                set end of reports to ((class of (value of target) as string) & "|" & (number format of target as string) & "|" & (string value of target as string))
            end repeat
            set AppleScript's text item delimiters to linefeed
            return reports as string
        end tell
        """)
        let lines = report.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, report)
        XCTAssertTrue(lines[0].contains("text") && lines[0].contains("|@|00123"), lines[0])
        XCTAssertTrue(lines[1].contains("yyyy-mm-dd") && lines[1].contains("2025-11-01"), lines[1])
        XCTAssertTrue(lines[2].contains("hh:mm") && lines[2].contains("09:30"), lines[2])
        XCTAssertTrue(lines[3].contains("0.00") && lines[3].contains("42.10"), lines[3])
        XCTAssertFalse(lines[1].localizedCaseInsensitiveContains("text"))
        XCTAssertFalse(lines[3].localizedCaseInsensitiveContains("text"))
    }

    private func copyAndCapture(book: String, range: String) throws -> (text: String, snapshot: ClipboardRepresentations.Snapshot) {
        try appleVoid("""
        tell application "Microsoft Excel"
            set ws to worksheet 1 of workbook "\(book)"
            set sourceRange to range "\(range)" of ws
            select sourceRange
            copy range sourceRange
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.2)
        let reading = ClipboardPasteboardReading.read(from: .general)
        let choice = try XCTUnwrap(ClipboardCapture.choose(reading))
        guard case .text(let text) = choice else {
            XCTFail("expected text, got \(choice)")
            return ("", .empty)
        }
        return (text, ClipboardRepresentations.capture(reading))
    }

    private func leaveCopyMode() throws {
        try appleVoid("""
        tell application "Microsoft Excel"
            set cut copy mode to false
        end tell
        """)
    }

    private func selectCell(book: String, row: Int, column: Int) throws {
        try appleVoid("""
        tell application "Microsoft Excel"
            set ws to worksheet 1 of workbook "\(book)"
            select cell \(row) of column \(column) of ws
        end tell
        """)
    }

    private func writeGridScript(_ grid: [[String]], range: String, book: String, thenGeneral: Bool) -> String {
        let rows = grid.map { row in
            "{" + row.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") + "}"
        }.joined(separator: ", ")
        let restore = thenGeneral ? "set number format of target to \"General\"" : ""
        return """
        tell application "Microsoft Excel"
            set ws to worksheet 1 of workbook "\(book)"
            set target to range "\(range)" of ws
            set number format of target to "@"
            set value of target to {\(rows)}
            \(restore)
        end tell
        """
    }

    private func loadReportGrid() throws -> [[String]] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipFlow/history.json")
        let data = try Data(contentsOf: url)
        let items = try JSONDecoder().decode([HistoryProbe].self, from: data)
        let item = try XCTUnwrap(items.first { $0.id == "085799FC-763D-4EC0-822B-5CC9C3C5EADD" })
        let rows = item.fullText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        return rows
    }

    private func fixture() throws -> (URL, UserDefaults, MemorySensitivePayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowLive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults, MemorySensitivePayloadRepository())
    }

    @discardableResult
    private func appleString(_ source: String) throws -> String {
        let result = try run(source)
        return result.stringValue ?? ""
    }

    private func appleVoid(_ source: String) throws {
        _ = try run(source)
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? String(describing: error)
            let preview = source.replacingOccurrences(of: "\n", with: " ").prefix(160)
            throw NSError(domain: "ExcelInsertLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message) :: \(preview)"])
        }
        return result
    }
}

private struct HistoryProbe: Decodable {
    var id: String
    var fullText: String
}
