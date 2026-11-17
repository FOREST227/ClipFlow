import XCTest
@testable import ClipFlowApp

final class InspectorCommandTests: XCTestCase {
    func testEveryDetailActionHasATitleOrSymbol() {
        let plain = InspectorCommands.bar(pinned: false, canSaveSnippet: true, showsReveal: false, revealed: true)
        XCTAssertEqual(plain.map(\.id), [.copy, .paste, .pin, .saveSnippet, .more])
        assertVisible(plain)
        XCTAssertEqual(plain.first { $0.id == .copy }?.title, "复制")
        XCTAssertEqual(plain.first { $0.id == .paste }?.title, "粘贴")
        XCTAssertFalse(plain.first { $0.id == .pin }?.symbol.isEmpty ?? true)
        XCTAssertFalse(plain.first { $0.id == .saveSnippet }?.symbol.isEmpty ?? true)
        XCTAssertEqual(plain.first { $0.id == .more }?.symbol, "ellipsis")

        let pinned = InspectorCommands.bar(pinned: true, canSaveSnippet: false, showsReveal: true, revealed: false)
        assertVisible(pinned)
        XCTAssertEqual(pinned.first { $0.id == .pin }?.symbol, "pin.fill")
        XCTAssertEqual(pinned.first { $0.id == .reveal }?.title, "显示")
        XCTAssertFalse(pinned.contains { $0.id == .saveSnippet })

        let sheet = InspectorCommands.spreadsheet(hasOriginalTypes: true, offersExcelInsert: true)
        assertVisible(sheet)
        XCTAssertTrue(sheet.contains { $0.title == SpreadsheetClipboard.copyOnlyTitle })
        XCTAssertTrue(sheet.contains { $0.title == SpreadsheetShift.down.menuTitle })
        XCTAssertTrue(sheet.contains { $0.id == .insertRight && !$0.title.isEmpty && !$0.symbol.isEmpty })
        XCTAssertTrue(InspectorCommands.spreadsheet(hasOriginalTypes: false, offersExcelInsert: false).isEmpty)

        let rich = InspectorCommands.plainText(hasRichText: true)
        assertVisible(rich)
        XCTAssertEqual(rich.map(\.title), [PlainTextPaste.copyTitle, PlainTextPaste.pasteTitle])
        XCTAssertTrue(InspectorCommands.plainText(hasRichText: false).isEmpty)
    }

    private func assertVisible(_ commands: [InspectorCommand], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(commands.isEmpty, file: file, line: line)
        for command in commands {
            XCTAssertTrue(command.hasVisibleFace, "\(command.id) has neither a title nor a symbol", file: file, line: line)
        }
    }
}
