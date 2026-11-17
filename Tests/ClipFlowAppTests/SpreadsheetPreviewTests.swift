import XCTest
@testable import ClipFlowApp

final class SpreadsheetPreviewTests: XCTestCase {
    func testLabeledExcelTSVChoosesATableAndKeepsDisplayText() {
        let item = item(text: "活动\t曝光\n春季上新\t128430")
        let grid = SpreadsheetPreview.grid(for: item)

        XCTAssertEqual(grid?.rows, [["活动", "曝光"], ["春季上新", "128430"]])
        XCTAssertEqual(grid?.columnCount, 2)
        XCTAssertEqual(grid?.omittedRowCount, 0)
        XCTAssertNil(grid?.overflowCaption)
        XCTAssertTrue(SpreadsheetPreview.presentsAsTable(item))
        XCTAssertEqual(SpreadsheetPreview.typeLabel(for: item), "表格")
        XCTAssertEqual(SpreadsheetPreview.title(for: item), "表格")
        XCTAssertEqual(SpreadsheetPreview.symbolName(for: item), "tablecells")
        XCTAssertTrue(SpreadsheetPreview.usesExpandedListRow(item))
        XCTAssertEqual(LibraryCardLayout.height(for: item), LibraryCardLayout.expandedHeight)
        XCTAssertEqual(QuickPasteCardLayout.height(for: item), QuickPasteCardLayout.expandedHeight)
    }

    func testQuotedNewlinesAndWindowsRowBreaksStayInsideCells() {
        let grid = SpreadsheetPreview.grid(for: item(text: "\"春\n季\"\t128\r\n会员日\t96"))
        XCTAssertEqual(grid?.rows, [["春\n季", "128"], ["会员日", "96"]])
    }

    func testSingleColumnPercentagesStayATable() {
        let grid = SpreadsheetPreview.grid(for: item(text: "-0.79%\r\n0.93%\r\n-0.44%"))
        XCTAssertEqual(grid?.rows, [["-0.79%"], ["0.93%"], ["-0.44%"]])
        XCTAssertTrue(SpreadsheetPreview.usesExpandedListRow(item(text: "-0.79%\r\n0.93%\r\n-0.44%")))
    }

    func testTSVDisplayTextWinsWhenHTMLHasTheSameShape() {
        let html = "<table><tr><td>原始甲</td><td>12.5</td></tr><tr><td>原始乙</td><td>3</td></tr></table>"
        let grid = SpreadsheetPreview.grid(for: item(text: "显示甲\t12.50\n显示乙\t3.00", html: html))
        XCTAssertEqual(grid?.rows, [["显示甲", "12.50"], ["显示乙", "3.00"]])
    }

    func testHTMLRestoresColumnsWhenPlainTextCollapsed() {
        let html = """
        <table>
        <tr><td>A</td><td></td><td>C</td></tr>
        <tr><td>D</td><td>E</td><td>F</td></tr>
        </table>
        """
        let grid = SpreadsheetPreview.grid(for: item(
            text: "折叠成一段",
            labels: ["备忘录", "便签"],
            html: html
        ))
        XCTAssertEqual(grid?.rows, [["A", "", "C"], ["D", "E", "F"]])
        XCTAssertEqual(SpreadsheetPreview.typeLabel(for: item(text: "折叠成一段", labels: ["备忘录", "便签"], html: html)), "表格")
    }

    func testXMLSpreadsheetIsUsedWhenTextAndHTMLAreMissing() throws {
        let xml = """
        <?xml version="1.0"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
        <Worksheet ss:Name="Sheet1"><Table>
        <Row>
        <Cell><Data ss:Type="String">名称</Data></Cell>
        <Cell><Data ss:Type="Number">42</Data></Cell>
        </Row>
        <Row>
        <Cell><Data ss:Type="String">春季</Data></Cell>
        <Cell><Data ss:Type="Number">7</Data></Cell>
        </Row>
        </Table></Worksheet></Workbook>
        """
        let stored = item(
            text: " ",
            labels: ["Microsoft Excel"],
            extra: [ClipboardPasteboardType(type: "XML Spreadsheet", data: Data(xml.utf8))]
        )
        let grid = try XCTUnwrap(SpreadsheetPreview.grid(for: stored))
        XCTAssertEqual(grid.rows, [["名称", "42"], ["春季", "7"]])
    }

    func testOrdinaryPlainTextIsNotATable() {
        let prose = item(text: "今天把使用说明改完。", labels: ["备忘录", "便签"])
        let tabbed = item(text: "请查收\t附件", labels: ["备忘录", "便签"])
        let paragraph = item(text: "第一行还是说明\n第二行也不是表格", labels: ["备忘录", "长文本"])

        for sample in [prose, tabbed, paragraph] {
            XCTAssertNil(SpreadsheetPreview.grid(for: sample), sample.fullText)
            XCTAssertFalse(SpreadsheetPreview.presentsAsTable(sample))
            XCTAssertEqual(SpreadsheetPreview.typeLabel(for: sample), "文本")
            XCTAssertEqual(SpreadsheetPreview.title(for: sample), "文本")
            XCTAssertEqual(LibraryCardLayout.height(for: sample), LibraryCardLayout.compactHeight)
        }
    }

    func testSingleCellKeepsTheTableLabelWithoutGrowingTheListRow() {
        let cell = item(text: "42.00", labels: ["Microsoft Excel", "便签", "表格"])
        XCTAssertEqual(SpreadsheetPreview.grid(for: cell)?.rows, [["42.00"]])
        XCTAssertEqual(SpreadsheetPreview.typeLabel(for: cell), "表格")
        XCTAssertEqual(SpreadsheetPreview.title(for: cell), "表格")
        XCTAssertFalse(SpreadsheetPreview.usesExpandedListRow(cell))
        XCTAssertEqual(LibraryCardLayout.height(for: cell), LibraryCardLayout.height(for: .text))
    }

    func testImageFollowUpStaysAnImage() {
        var image = ClipboardClassifier.makeImageItem(
            imageFilename: "preview.png",
            imageSignature: "sig",
            imageSize: CGSize(width: 80, height: 20),
            sourceApp: "Microsoft Excel",
            sourceBundleID: "com.microsoft.Excel",
            existingItem: nil
        )
        image.labels.append("表格")
        image.fullText = "活动\t曝光"
        XCTAssertNil(SpreadsheetPreview.grid(for: image))
        XCTAssertEqual(SpreadsheetPreview.typeLabel(for: image), "图片")
        XCTAssertEqual(LibraryCardLayout.height(for: image), LibraryCardLayout.height(for: .image))
    }

    func testHugeSheetsCapThePreviewAndSayWhatWasLeftOut() throws {
        let rows = (0..<130).map { "名称\($0)\t\($0)" }.joined(separator: "\n")
        let tall = try XCTUnwrap(SpreadsheetPreview.grid(for: item(text: rows)))
        XCTAssertEqual(tall.rows.count, SpreadsheetPreview.maxRows)
        XCTAssertEqual(tall.omittedRowCount, 10)
        XCTAssertEqual(tall.rows.first, ["名称0", "0"])
        XCTAssertEqual(tall.overflowCaption, "还有 10 行未显示")

        let wide = (0..<40).map(String.init).joined(separator: "\t")
        let sheet = SpreadsheetPreview.grid(for: item(text: wide))
        XCTAssertEqual(sheet?.columnCount, SpreadsheetPreview.maxColumns)
        XCTAssertEqual(sheet?.omittedColumnCount, 8)
        XCTAssertEqual(sheet?.overflowCaption, "还有 8 列未显示")
    }

    func testTableRowsKeepTheirPlaceAheadOfATextRow() {
        let table = item(text: "A\tB\nC\tD")
        let text = item(text: "一条普通备注", labels: ["备忘录", "便签"])
        let frames = HistoryRowGeometry.place(items: [table, text], width: 420).frames
        XCTAssertEqual(frames[0].height, LibraryCardLayout.expandedHeight)
        XCTAssertEqual(frames[1].minY, LibraryCardLayout.expandedHeight + LibraryCardLayout.spacing)
        XCTAssertEqual(frames[1].height, LibraryCardLayout.compactHeight)
    }

    func testPreviewLeavesPasteAndInsertFormatsUntouched() throws {
        let tsv = "00123\t2026-11-16\t09:30\t42"
        let html = """
        <html><head><style>
        td { mso-number-format:General; }
        .xl65 { mso-number-format:"\\@"; }
        .xl66 { mso-number-format:"yyyy\\\\-mm\\\\-dd"; }
        .xl67 { mso-number-format:"hh\\:mm"; }
        .xl68 { mso-number-format:"0.00"; }
        </style></head><body><table><tr>
        <td class=xl65>00123</td>
        <td class=xl66>2026-11-16</td>
        <td class=xl67>09:30</td>
        <td class=xl68>42</td>
        </tr></table></body></html>
        """
        let entries = [
            ClipboardPasteboardType(type: "public.utf8-plain-text", data: Data(tsv.utf8)),
            ClipboardPasteboardType(type: "public.html", data: Data(html.utf8)),
            ClipboardPasteboardType(type: "public.tiff", data: Data([0x4D, 0x4D, 0x00, 0x2A])),
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: Data([0xD0, 0xCF, 0x11, 0xE0])),
            ClipboardPasteboardType(type: "XML Spreadsheet", data: Data(xmlFixture.utf8)),
            ClipboardPasteboardType(type: "Biff8", data: Data("biff".utf8))
        ]
        let stored = item(text: tsv, html: html, extra: entries)
        let before = SpreadsheetReplay.pasteRecords(from: entries).map(\.type)
        let grid = try XCTUnwrap(SpreadsheetPreview.grid(for: stored))
        XCTAssertEqual(grid.rows, [["00123", "2026-11-16", "09:30", "42"]])
        XCTAssertEqual(stored.fullText, tsv)
        XCTAssertEqual(stored.htmlData, Data(html.utf8))
        XCTAssertEqual(stored.extraTypes, entries)
        XCTAssertEqual(stored.kind, .text)

        let after = SpreadsheetReplay.pasteRecords(from: stored.extraTypes ?? []).map(\.type)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after, ["XML Spreadsheet", "Biff8", "public.html", "public.utf8-plain-text"])

        let range = try XCTUnwrap(SpreadsheetInsertRange.measure(tsv: stored.fullText))
        XCTAssertEqual(range, SpreadsheetInsertRange(rows: 1, columns: 4))
        let insert = try XCTUnwrap(ExcelCellInserter.script(rows: range.rows, columns: range.columns, shift: .down))
        XCTAssertTrue(insert.contains("row size 1"))
        XCTAssertTrue(insert.contains("column size 4"))
        XCTAssertTrue(insert.contains("shift down"))

        let formats = SpreadsheetReplay.cells(in: entries)
        let script = try XCTUnwrap(SpreadsheetReplay.formatScript(for: formats))
        XCTAssertTrue(script.contains("number format of targetCell to \"@\""))
        XCTAssertTrue(script.contains("set value of targetCell to \"00123\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"yyyy-mm-dd\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"hh:mm\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"0.00\""))
        XCTAssertFalse(script.contains("set value of targetCell to \"2026-11-16\""))
    }

    private let xmlFixture = """
    <?xml version="1.0"?>
    <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
    <Styles>
    <Style ss:ID="sText"><NumberFormat ss:Format="@"/></Style>
    <Style ss:ID="sDate"><NumberFormat ss:Format="yyyy-mm-dd"/></Style>
    <Style ss:ID="sTime"><NumberFormat ss:Format="hh:mm"/></Style>
    <Style ss:ID="sNum"><NumberFormat ss:Format="0.00"/></Style>
    </Styles>
    <Worksheet ss:Name="Sheet1"><Table>
    <Row>
    <Cell ss:StyleID="sText"><Data ss:Type="String">00123</Data></Cell>
    <Cell ss:StyleID="sDate"><Data ss:Type="DateTime">2026-11-16T00:00:00.000</Data></Cell>
    <Cell ss:StyleID="sTime"><Data ss:Type="DateTime">1899-12-31T09:30:00.000</Data></Cell>
    <Cell ss:StyleID="sNum"><Data ss:Type="Number">42</Data></Cell>
    </Row>
    </Table></Worksheet></Workbook>
    """

    private func item(
        text: String,
        labels: [String] = ["Microsoft Excel", "长文本", "表格"],
        html: String? = nil,
        extra: [ClipboardPasteboardType] = []
    ) -> ClipboardItem {
        var stored = ClipboardClassifier.makeItem(
            text: text,
            sourceApp: "Microsoft Excel",
            sourceBundleID: "com.microsoft.Excel",
            autoProtectSecrets: false,
            existingItem: nil
        )
        stored.labels = labels
        stored.htmlData = html.map { Data($0.utf8) }
        stored.extraTypes = extra.isEmpty ? nil : extra
        stored.kind = .text
        stored.title = ClipboardKind.text.label
        return stored
    }
}
