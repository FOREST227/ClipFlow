import XCTest
@testable import ClipFlowApp

final class InspectorCommandTests: XCTestCase {
    func testEveryDetailActionHasATitleOrSymbol() {
        let plain = InspectorCommands.bar(pinned: false, canSaveSnippet: true, showsReveal: false, revealed: true)
        XCTAssertEqual(plain.map(\.id), [.paste, .copy, .pin, .saveSnippet, .more])
        assertVisible(plain)
        XCTAssertEqual(plain.first { $0.id == .copy }?.title, "复制")
        XCTAssertEqual(plain.first { $0.id == .paste }?.title, "粘贴")
        XCTAssertTrue(plain.first { $0.id == .paste }?.isPrimary == true)
        XCTAssertFalse(plain.first { $0.id == .pin }?.symbol.isEmpty ?? true)
        XCTAssertFalse(plain.first { $0.id == .saveSnippet }?.symbol.isEmpty ?? true)
        XCTAssertEqual(plain.first { $0.id == .more }?.symbol, "ellipsis")
        XCTAssertTrue(plain.first { $0.id == .pin }?.title.isEmpty == true)
        XCTAssertTrue(plain.first { $0.id == .more }?.title.isEmpty == true)

        let pinned = InspectorCommands.bar(pinned: true, canSaveSnippet: false, showsReveal: true, revealed: false)
        assertVisible(pinned)
        XCTAssertEqual(pinned.map(\.id), [.paste, .copy, .pin, .reveal, .more])
        XCTAssertEqual(pinned.first { $0.id == .pin }?.symbol, "pin.fill")
        XCTAssertEqual(pinned.first { $0.id == .reveal }?.title, "")
        XCTAssertEqual(pinned.first { $0.id == .reveal }?.symbol, "eye")
        XCTAssertEqual(pinned.first { $0.id == .reveal }?.accessibilityLabel, "显示")
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

        let sensitive = InspectorCommands.actions(
            pinned: false, canSaveSnippet: true, showsReveal: true, revealed: false,
            hasRichText: true, hasOriginalTypes: false, offersExcelInsert: false)
        XCTAssertEqual(sensitive.commands.map(\.id), [
            .paste, .copy, .copyPlain, .pastePlain, .pin, .saveSnippet, .reveal, .more
        ])
        XCTAssertEqual(sensitive.iconClusterCount, 4)
        XCTAssertEqual(sensitive.commands.first { $0.id == .reveal }?.symbol, "eye")

        let table = InspectorCommands.actions(
            pinned: false, canSaveSnippet: true, showsReveal: false, revealed: true,
            hasRichText: false, hasOriginalTypes: true, offersExcelInsert: true)
        XCTAssertEqual(table.commands.map(\.id), [
            .paste, .copy, .copyOriginal, .insertDown, .insertRight, .pin, .saveSnippet, .more
        ])
        XCTAssertEqual(table.iconClusterCount, 3)
        XCTAssertEqual(InspectorCommands.overflowActions(
            canOpenURL: true, canSaveSnippet: true, hasOriginalTypes: true, offersExcelInsert: true
        ).map(\.title), [
            "访问链接", "存为片段", SpreadsheetClipboard.copyOnlyTitle,
            SpreadsheetShift.down.menuTitle, SpreadsheetShift.right.menuTitle, "删除条目"
        ])
        XCTAssertEqual(InspectorCommands.overflowActions(
            canOpenURL: false, canSaveSnippet: true, hasOriginalTypes: false, offersExcelInsert: false
        ).map(\.title), ["存为片段", "删除条目"])
    }

    func testArrangementWrapsInsideNarrowAndWideCards() {
        let widths: [CGFloat] = [72, 64, 168, 156, 36, 36, 36, 36]
        let sizes = widths.map { CGSize(width: $0, height: 32) }
        for contentWidth in [InspectorCardWidth.quickPaste, InspectorCardWidth.libraryNarrow, InspectorCardWidth.libraryWide] {
            let limit = InspectorActionMetrics.actionWidth(contentWidth: contentWidth)
            let arranged = InspectorActionArrangement.arrange(sizes: sizes, containerWidth: limit, iconClusterCount: 4)
            XCTAssertEqual(arranged.size.width, limit, accuracy: 0.5)
            XCTAssertEqual(arranged.items.map(\.index), Array(sizes.indices))
            assertInside(arranged, limit: limit)
            let icons = arranged.items.suffix(4).map(\.frame)
            XCTAssertEqual(icons.map { $0.minY }.max(), icons.map { $0.minY }.min())
        }

        let wide = InspectorActionArrangement.arrange(
            sizes: [CGSize(width: 80, height: 32), CGSize(width: 30, height: 20), CGSize(width: 30, height: 40)],
            containerWidth: 200, iconClusterCount: 0)
        XCTAssertEqual(wide.items.count, 3)
        XCTAssertEqual(wide.items[1].frame.minY, 10, accuracy: 0.1)

        let wrapped = InspectorActionArrangement.arrange(
            sizes: [CGSize(width: 80, height: 32), CGSize(width: 30, height: 32), CGSize(width: 30, height: 32), CGSize(width: 30, height: 32)],
            containerWidth: 150, iconClusterCount: 3)
        XCTAssertEqual(wrapped.items[0].frame.minY, 0, accuracy: 0.1)
        XCTAssertEqual(wrapped.items[1].frame.minY, 40, accuracy: 0.1)
        XCTAssertEqual(wrapped.items[1].frame.minX, 0, accuracy: 0.1)
        XCTAssertEqual(wrapped.items[3].frame.minX, 76, accuracy: 0.1)

        let image = InspectorCommands.actions(
            pinned: false, canSaveSnippet: false, showsReveal: false, revealed: true,
            hasRichText: false, hasOriginalTypes: false, offersExcelInsert: false)
        XCTAssertEqual(image.commands.map(\.id), [.paste, .copy, .pin, .more])
        XCTAssertEqual(image.iconClusterCount, 2)
        let linkOverflow = InspectorCommands.overflowActions(
            canOpenURL: true, canSaveSnippet: true, hasOriginalTypes: false, offersExcelInsert: false)
        XCTAssertEqual(linkOverflow.map(\.title), ["访问链接", "存为片段", "删除条目"])

        let clamped = InspectorActionArrangement.arrange(
            sizes: [CGSize(width: 400, height: 32)], containerWidth: 120)
        XCTAssertEqual(clamped.items[0].frame.width, 120, accuracy: 0.1)
        XCTAssertLessThanOrEqual(clamped.items[0].frame.maxX, 120.1)
    }

    func testMenuAnchorStaysInsideTheCard() {
        let card = CGRect(x: 80, y: 140, width: InspectorCardWidth.quickPaste, height: 460)
        let overlapping = CGRect(x: card.maxX - 4, y: card.minY + 28, width: 36, height: 32)
        let menu = CGSize(width: 168, height: 72)
        let origin = InspectorMenuAnchor.topLeft(menuSize: menu, button: overlapping, card: card)
        let placed = CGRect(x: origin.x, y: origin.y - menu.height, width: menu.width, height: menu.height)
        XCTAssertTrue(card.insetBy(dx: InspectorActionMetrics.menuInset - 0.5, dy: InspectorActionMetrics.menuInset - 0.5).contains(placed))

        let inner = CGRect(x: card.minX + 180, y: card.minY + 36, width: 32, height: 32)
        let wideCard = CGRect(x: 40, y: 80, width: InspectorCardWidth.libraryWide, height: 520)
        let wideOrigin = InspectorMenuAnchor.topLeft(menuSize: menu, button: inner.offsetBy(dx: wideCard.minX - card.minX, dy: 0), card: wideCard)
        XCTAssertEqual(wideOrigin.x + menu.width, inner.maxX + (wideCard.minX - card.minX), accuracy: 0.5)
        let widePlaced = CGRect(x: wideOrigin.x, y: wideOrigin.y - menu.height, width: menu.width, height: menu.height)
        XCTAssertTrue(wideCard.insetBy(dx: 7, dy: 7).contains(widePlaced))
    }

    private func assertInside(_ arranged: InspectorActionArrangement, limit: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        for item in arranged.items {
            XCTAssertGreaterThanOrEqual(item.frame.minX, -0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(item.frame.maxX, limit + 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(item.frame.minY, -0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(item.frame.maxY, arranged.size.height + 0.5, file: file, line: line)
            XCTAssertEqual(item.frame.height, 32, accuracy: 0.5, file: file, line: line)
        }
    }

    private func assertVisible(_ commands: [InspectorCommand], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(commands.isEmpty, file: file, line: line)
        for command in commands {
            XCTAssertTrue(command.hasVisibleFace, "\(command.id) has neither a title nor a symbol", file: file, line: line)
        }
    }
}
