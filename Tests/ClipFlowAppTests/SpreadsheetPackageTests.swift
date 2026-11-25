import Compression
import XCTest
@testable import ClipFlowApp

final class SpreadsheetPackageTests: XCTestCase {
    func testMultiRowTextBlockKeepsDatesAndFivePlaceDecimals() throws {
        let html = """
        <html><body><table>
        <tr><td>2025-11-01</td><td>5026.70505</td></tr>
        <tr><td>2025-11-01</td><td>0.14472</td></tr>
        <tr><td>00123</td><td>61174480</td></tr>
        </table></body></html>
        """
        let package = olePackage(files: [
            ("xl/styles.xml", stylesXML),
            ("xl/sharedStrings.xml", "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>00123</t></si></sst>"),
            ("xl/worksheets/sheet1.xml", textSheetXML)
        ])
        let entries = [
            ClipboardPasteboardType(type: "public.html", data: Data(html.utf8)),
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: package),
            ClipboardPasteboardType(type: "public.utf8-plain-text", data: Data("2025-11-01\t5026.70505".utf8))
        ]
        let cells = SpreadsheetReplay.cells(in: entries, rows: 3, columns: 2)
        XCTAssertEqual(cells.map(\.row), [0, 0, 1, 1, 2, 2])
        XCTAssertEqual(cells.map(\.column), [0, 1, 0, 1, 0, 1])
        XCTAssertEqual(cells.map(\.kind), [.text, .text, .text, .text, .text, .text])
        XCTAssertEqual(cells.map(\.numberFormat), ["General", "General", "General", "General", "@", "General"])
        XCTAssertEqual(cells.map(\.text), [
            "2025-11-01", "5026.70505",
            "2025-11-01", "0.14472",
            "00123", "61174480"
        ])

        let script = try XCTUnwrap(SpreadsheetReplay.formatScript(for: cells))
        let textDate = """
            set number format of targetCell to "@"
            set value of targetCell to "2025-11-01"
            set number format of targetCell to "General"
        """
        XCTAssertTrue(script.contains(textDate))
        XCTAssertTrue(script.contains("set value of targetCell to \"5026.70505\""))
        XCTAssertTrue(script.contains("set value of targetCell to \"0.14472\""))
        XCTAssertTrue(script.contains("set value of targetCell to \"61174480\""))
        let leadingZeros = script.range(of: "set value of targetCell to \"00123\"")
        XCTAssertNotNil(leadingZeros)
        if let leadingZeros {
            let after = script[leadingZeros.upperBound...].drop { $0 == "\n" || $0 == " " }
            XCTAssertFalse(after.hasPrefix("set number format of targetCell to \"General\""))
        }
        XCTAssertFalse(script.contains("ignore me"))
        XCTAssertFalse(script.contains("outside"))
        XCTAssertFalse(script.contains("phonetic"))

        let pasted = SpreadsheetReplay.pasteRecords(from: entries).map(\.type)
        XCTAssertEqual(pasted, ["public.html", "public.utf8-plain-text"])
        XCTAssertTrue(SpreadsheetReplay.isExcluded("com.microsoft.Embed-Source"))
    }

    func testMixedPackageKeepsNumberFormatsAndDoesNotRewriteValues() throws {
        let package = olePackage(files: [
            ("xl/styles.xml", stylesXML),
            ("xl/sharedStrings.xml", "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>00123</t></si></sst>"),
            ("xl/worksheets/sheet1.xml", mixedSheetXML)
        ])
        let entries = [
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: package)
        ]
        let cells = SpreadsheetReplay.cells(in: entries, rows: 1, columns: 4)
        XCTAssertEqual(cells.map(\.kind), [.text, .date, .time, .number])
        XCTAssertEqual(cells.map(\.numberFormat), ["@", "yyyy-mm-dd", "hh:mm", "0.00"])
        XCTAssertEqual(cells.map(\.text), ["00123", "45962", "0.3958333333", "42"])
        XCTAssertEqual(cells.map(\.column), [0, 1, 2, 3])

        let script = try XCTUnwrap(SpreadsheetReplay.formatScript(for: cells))
        XCTAssertTrue(script.contains("set value of targetCell to \"00123\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"yyyy-mm-dd\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"hh:mm\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"0.00\""))
        XCTAssertFalse(script.contains("set value of targetCell to \"45962\""))
        XCTAssertFalse(script.contains("set value of targetCell to \"0.3958333333\""))
        XCTAssertFalse(script.contains("set value of targetCell to \"42\""))
    }

    func testDeflatedPackageMatchesStoredPackage() throws {
        let files = [
            ("xl/styles.xml", stylesXML),
            ("xl/sharedStrings.xml", "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>00123</t></si></sst>"),
            ("xl/worksheets/sheet1.xml", mixedSheetXML)
        ]
        let stored = SpreadsheetReplay.cells(in: [
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: olePackage(files: files, method: 0))
        ], rows: 1, columns: 4)
        let deflated = SpreadsheetReplay.cells(in: [
            ClipboardPasteboardType(type: "Embed Source", data: olePackage(files: files, method: 8))
        ], rows: 1, columns: 4)
        XCTAssertEqual(deflated, stored)
        XCTAssertEqual(deflated.map(\.kind), [.text, .date, .time, .number])
    }

    func testPackageDoesNotApplyWhenSelectionSizeDiffersFromTheCopy() {
        let html = """
        <html><head><style>
        td { mso-number-format:General; }
        .xl65 { mso-number-format:"\\@"; }
        .xl68 { mso-number-format:"0.00"; }
        </style></head><body><table><tr>
        <td class=xl65>00123</td><td class=xl68>42</td>
        </tr></table></body></html>
        """
        let package = olePackage(files: [
            ("xl/styles.xml", stylesXML),
            ("xl/worksheets/sheet1.xml", textSheetXML)
        ])
        let entries = [
            ClipboardPasteboardType(type: "public.html", data: Data(html.utf8)),
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: package)
        ]
        let cells = SpreadsheetReplay.cells(in: entries, rows: 1, columns: 2)
        XCTAssertEqual(cells.map(\.kind), [.text, .number])
        XCTAssertEqual(cells.map(\.numberFormat), ["@", "0.00"])
        XCTAssertEqual(cells.map(\.text), ["00123", "42"])
    }

    func testXMLSpreadsheetStillWinsOverEmbeddedPackage() {
        let xml = """
        <?xml version="1.0"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
        <Styles><Style ss:ID="sDate"><NumberFormat ss:Format="yyyy-mm-dd"/></Style></Styles>
        <Worksheet ss:Name="Sheet1"><Table><Row>
        <Cell ss:StyleID="sDate"><Data ss:Type="DateTime">2026-11-16T00:00:00.000</Data></Cell>
        </Row></Table></Worksheet></Workbook>
        """
        let package = olePackage(files: [
            ("xl/styles.xml", stylesXML),
            ("xl/worksheets/sheet1.xml", textSheetXML)
        ])
        let entries = [
            ClipboardPasteboardType(type: "XML Spreadsheet", data: Data(xml.utf8)),
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: package)
        ]
        let cells = SpreadsheetReplay.cells(in: entries, rows: 3, columns: 2)
        XCTAssertEqual(cells.map(\.kind), [.date])
        XCTAssertEqual(cells.map(\.text), ["2026-11-16"])
        XCTAssertEqual(cells.map(\.numberFormat), ["yyyy-mm-dd"])
    }

    private let stylesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <numFmts count="2">
    <numFmt numFmtId="176" formatCode="yyyy\\-mm\\-dd"/>
    <numFmt numFmtId="177" formatCode="hh:mm"/>
    </numFmts>
    <cellXfs count="5">
    <xf numFmtId="0"/>
    <xf numFmtId="49"/>
    <xf numFmtId="176"/>
    <xf numFmtId="177"/>
    <xf numFmtId="2"/>
    </cellXfs>
    </styleSheet>
    """

    /// Selection F2:G4 is the copy. A1 and F5 sit outside it. One decimal is split across rich-text runs,
    /// and a phonetic run must not become part of the cell text. The last text cell is a shared string.
    private let textSheetXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <sheetViews><sheetView tabSelected="1"><selection activeCell="F2" sqref="F2:G4"/></sheetView></sheetViews>
    <sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>ignore me</t></is></c></row>
    <row r="2">
    <c r="F2" s="0" t="inlineStr"><is><t>2025-11-01</t></is></c>
    <c r="G2" s="0" t="inlineStr"><is><r><t>5026.</t></r><r><t>70505</t></r></is></c>
    </row>
    <row r="3">
    <c r="F3" s="0" t="inlineStr"><is><t>2025-11-01</t></is></c>
    <c r="G3" s="0" t="inlineStr"><is><t>0.14472</t><rPh sb="0" eb="1"><t>phonetic</t></rPh></is></c>
    </row>
    <row r="4">
    <c r="F4" s="1" t="s"><v>0</v></c>
    <c r="G4" s="0" t="inlineStr"><is><t>61174480</t></is></c>
    </row>
    <row r="5"><c r="F5" t="inlineStr"><is><t>outside</t></is></c></row>
    </sheetData>
    </worksheet>
    """

    private let mixedSheetXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <dimension ref="A1:K124"/>
    <sheetViews><sheetView tabSelected="1"><selection sqref="Sheet1!A1:D1"/></sheetView></sheetViews>
    <sheetData>
    <row r="1">
    <c r="A1" s="1" t="s"><v>0</v></c>
    <c r="B1" s="2"><v>45962</v></c>
    <c r="C1" s="3"><v>0.3958333333</v></c>
    <c r="D1" s="4"><v>42</v></c>
    </row>
    <row r="2"><c r="A2" t="inlineStr"><is><t>not in the copy</t></is></c></row>
    </sheetData>
    </worksheet>
    """

    private func olePackage(files: [(String, String)], method: UInt16 = 0) -> Data {
        var prefix = Data([0xD0, 0xCF, 0x11, 0xE0])
        prefix.append(storedZip(files, method: method))
        return prefix
    }

    private func storedZip(_ files: [(String, String)], method: UInt16) -> Data {
        var archive = Data()
        for (name, text) in files {
            let nameData = Data(name.utf8)
            let payload = Data(text.utf8)
            let body: Data
            let sizesMatch: UInt32
            if method == 8 {
                body = try! XCTUnwrap(rawDeflate(payload), "deflate \(name)")
                sizesMatch = UInt32(payload.count)
            } else {
                body = payload
                sizesMatch = UInt32(payload.count)
            }
            var header = Data()
            header.appendU32(0x04034b50)
            header.appendU16(20)
            header.appendU16(0)
            header.appendU16(method)
            header.appendU16(0)
            header.appendU16(0)
            header.appendU32(0)
            header.appendU32(UInt32(body.count))
            header.appendU32(sizesMatch)
            header.appendU16(UInt16(nameData.count))
            header.appendU16(0)
            archive.append(header)
            archive.append(nameData)
            archive.append(body)
        }
        return archive
    }

    private func rawDeflate(_ data: Data) -> Data? {
        let capacity = data.count + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendU32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
