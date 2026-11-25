import AppKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class SpreadsheetPasteTests: XCTestCase {
    private let tsv = "A1\tB1\nA2\tB2"
    private let tableHTML = "<html><body><table><tr><td>A1</td><td>B1</td></tr><tr><td>A2</td><td>B2</td></tr></table></body></html>"
    private let imageHTML = "<html><body><!--StartFragment--><img src=\"https://example.com/cat.png\" alt=\"cat\"><!--EndFragment--></body></html>"

    private func fixture() throws -> (URL, UserDefaults, MemorySensitivePayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let payloads = MemorySensitivePayloadRepository()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults, payloads)
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func store(in directory: URL, defaults: UserDefaults, payloads: MemorySensitivePayloadRepository) -> ClipFlowStore {
        ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
    }

    private func tiffData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 3,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
    }

    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func write(_ pasteboard: NSPasteboard, _ records: [ClipboardPasteboardType]) {
        let types = records.map { NSPasteboard.PasteboardType($0.type) }
        XCTAssertNotEqual(pasteboard.declareTypes(types, owner: nil), 0)
        for record in records {
            XCTAssertTrue(
                pasteboard.setData(record.data, forType: NSPasteboard.PasteboardType(record.type)),
                record.type
            )
        }
    }

    private func excelRecords(tiff: Data) -> [ClipboardPasteboardType] {
        [
            ClipboardPasteboardType(type: "public.utf8-plain-text", data: Data(tsv.utf8)),
            ClipboardPasteboardType(type: "public.html", data: Data(tableHTML.utf8)),
            ClipboardPasteboardType(type: "public.rtf", data: Data("{\\rtf1 A1}".utf8)),
            ClipboardPasteboardType(type: "public.utf16-tab-separated-text", data: Data(tsv.data(using: .utf16)!)),
            ClipboardPasteboardType(type: "com.microsoft.Excel.XML", data: Data("<worksheet>cells</worksheet>".utf8)),
            ClipboardPasteboardType(type: "com.microsoft.Excel.Biff8", data: Data([0xD0, 0xCF, 0x11, 0xE0, 0x01])),
            ClipboardPasteboardType(type: "com.microsoft.Excel.Biff12", data: Data([0x50, 0x4B, 0x03, 0x04, 0x02])),
            ClipboardPasteboardType(type: "XML Spreadsheet", data: Data("<Workbook/>".utf8)),
            ClipboardPasteboardType(type: "Biff8", data: Data("biff8-payload".utf8)),
            ClipboardPasteboardType(type: "Embed Source", data: Data("embed-source".utf8)),
            ClipboardPasteboardType(type: "ObjectLink", data: Data("object-link".utf8)),
            ClipboardPasteboardType(type: "Link Source", data: Data("link-source".utf8)),
            ClipboardPasteboardType(type: "CSV", data: Data("A1,B1\nA2,B2".utf8)),
            ClipboardPasteboardType(type: "com.adobe.pdf", data: Data("%PDF-1.4 fake".utf8)),
            ClipboardPasteboardType(type: "public.tiff", data: tiff)
        ]
    }

    private func titles(for item: ClipboardItem, store: ClipFlowStore, excelBundleIDs: [String?]? = nil) -> [String] {
        ClipboardRowMenu.entries(for: item, store: store, leading: [
            .action(title: "粘贴", symbol: "arrow.down.doc") {}
        ], excelBundleIDs: excelBundleIDs).compactMap { entry in
            if case let .action(title, _, _) = entry { return title }
            return nil
        }
    }

    func testTypeMapPrefersSpreadsheetTextOverThePreview() throws {
        let tiff = try tiffData()
        let types = Dictionary(uniqueKeysWithValues: excelRecords(tiff: tiff).map { ($0.type, $0.data) })
        guard case .text(let text) = ClipboardCapture.choose(types: types) else {
            return XCTFail("expected text, got \(String(describing: ClipboardCapture.choose(types: types)))")
        }
        XCTAssertEqual(text, tsv)
    }

    func testImageWrapperWithTSVIsText() throws {
        let types: [String: Data] = [
            "public.utf8-plain-text": Data(tsv.utf8),
            "public.html": Data(imageHTML.utf8),
            "public.tiff": try tiffData()
        ]
        guard case .text(let text) = ClipboardCapture.choose(types: types) else {
            return XCTFail("expected TSV text")
        }
        XCTAssertEqual(text, tsv)
    }

    func testImageOnlyHTMLWhoseStringIsTheSourceURLStaysAnImage() throws {
        let png = try pngData()
        let types: [String: Data] = [
            "public.utf8-plain-text": Data("https://example.com/cat.png".utf8),
            "public.html": Data(imageHTML.utf8),
            "public.png": png
        ]
        guard case .image(.data(let data)) = ClipboardCapture.choose(types: types) else {
            return XCTFail("expected the web image")
        }
        XCTAssertEqual(data, png)

        let filenameOnly = types.merging(["public.utf8-plain-text": Data("cat.png".utf8)]) { _, new in new }
        guard case .image = ClipboardCapture.choose(types: filenameOnly) else {
            return XCTFail("expected the image when the string is only the file name")
        }
    }

    func testFinderImageFileStaysAnImageAndSpreadsheetFileDoesNot() throws {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        var types: [String: Data] = [
            "public.file-url": Data(url.absoluteString.utf8),
            "public.utf8-plain-text": Data("notes about the picture".utf8)
        ]
        guard case .image(.file(let chosen)) = ClipboardCapture.choose(types: types) else {
            return XCTFail("expected the image file")
        }
        XCTAssertEqual(chosen.path, url.path)

        types["com.microsoft.Excel.Biff8"] = Data("biff".utf8)
        types["public.utf8-plain-text"] = Data(tsv.utf8)
        guard case .text(let text) = ClipboardCapture.choose(types: types) else {
            return XCTFail("expected spreadsheet text ahead of the image file")
        }
        XCTAssertEqual(text, tsv)
    }

    func testBudgetDropsPreviewImagesBeforeNativeTypesAndKeepsOrder() throws {
        let native = ClipboardPasteboardType(type: "com.microsoft.Excel.Biff12", data: Data(repeating: 0x11, count: 20))
        let png = ClipboardPasteboardType(type: "public.png", data: Data(repeating: 0x22, count: 5))
        let tiff = ClipboardPasteboardType(type: "public.tiff", data: Data(repeating: 0x33, count: 30))
        let kept = ClipboardPasteboardBudget.selecting([native, png, tiff], limit: 26)
        XCTAssertEqual(kept.map(\.type), ["com.microsoft.Excel.Biff12", "public.png"])
        XCTAssertEqual(kept.first?.data, native.data)

        let oversizeNative = ClipboardPasteboardType(type: "Biff8", data: Data(repeating: 0x44, count: 80))
        let preview = ClipboardPasteboardType(type: "public.tiff", data: Data(repeating: 0x55, count: 40))
        let nativesStay = ClipboardPasteboardBudget.selecting([oversizeNative, preview], limit: 50)
        XCTAssertEqual(nativesStay, [oversizeNative])

        let empty = ClipboardPasteboardType(type: "CSV", data: Data())
        XCTAssertEqual(ClipboardPasteboardBudget.selecting([empty, native]), [native])
        XCTAssertGreaterThanOrEqual(ClipboardPasteboardBudget.totalByteLimit, 8 * 1024 * 1024)

        let severalMB = Data(repeating: 0x7A, count: 6 * 1024 * 1024)
        let large = ClipboardPasteboardBudget.selecting([
            ClipboardPasteboardType(type: "com.microsoft.Excel.XML", data: severalMB),
            ClipboardPasteboardType(type: "public.tiff", data: Data(repeating: 0x01, count: 1024))
        ])
        XCTAssertEqual(large.map(\.type), ["com.microsoft.Excel.XML", "public.tiff"])
        XCTAssertEqual(large[0].data, severalMB)
    }

    func testSpreadsheetGridAndInsertScript() {
        XCTAssertEqual(SpreadsheetInsertRange.measure(tsv: tsv), SpreadsheetInsertRange(rows: 2, columns: 2))
        XCTAssertEqual(SpreadsheetInsertRange.measure(tsv: tsv + "\n"), SpreadsheetInsertRange(rows: 2, columns: 2))
        XCTAssertEqual(SpreadsheetInsertRange.measure(tsv: "\"A\n1\"\tB\r\nC\tD"), SpreadsheetInsertRange(rows: 2, columns: 2))
        XCTAssertEqual(SpreadsheetInsertRange.measure(tsv: "only"), SpreadsheetInsertRange(rows: 1, columns: 1))
        XCTAssertNil(SpreadsheetInsertRange.measure(tsv: " \n\t"))
        XCTAssertNil(SpreadsheetInsertRange.measure(tsv: ""))

        let down = ExcelCellInserter.script(rows: 2, columns: 3, shift: .down)
        XCTAssertEqual(down, """
        tell application "Microsoft Excel"
            if (count of workbooks) is 0 then error "ClipFlow: no workbook"
            set anchorCell to active cell
            set destRange to get resize anchorCell row size 2 column size 3
            insert into range destRange shift shift down
            select anchorCell
        end tell
        """)
        XCTAssertTrue(ExcelCellInserter.script(rows: 1, columns: 4, shift: .right)?.contains("shift to right") == true)
        XCTAssertNil(ExcelCellInserter.script(rows: 0, columns: 1, shift: .down))
        XCTAssertNil(ExcelCellInserter.script(rows: SpreadsheetInsertRange.maxRows + 1, columns: 1, shift: .right))
        XCTAssertTrue(ExcelCellInserter.isPermissionDenial(number: -1743, message: nil))
        XCTAssertFalse(ExcelCellInserter.isPermissionDenial(number: -600, message: "Connection is invalid."))

        var source = ""
        let outcome = ExcelCellInserter.insert(rows: 2, columns: 3, shift: .down) { script in
            source = script
            return .notPermitted
        }
        XCTAssertEqual(outcome, .notPermitted)
        XCTAssertTrue(source.contains("row size 2"))
        XCTAssertTrue(source.contains("column size 3"))
    }

    func testRoundTripPreservesEveryTypeByteAndOrder() async throws {
        let (directory, defaults, payloads) = try fixture()
        let source = pasteboard()
        let records = excelRecords(tiff: try tiffData())
        let clipStore = ClipFlowStore(
            storageDirectory: directory,
            defaults: defaults,
            payloadRepository: payloads,
            accessibility: RecordingAccessibilityTrust(trusted: true)
        )
        let monitor = ClipboardMonitor(store: clipStore, pasteboard: source)
        write(source, records)
        monitor.poll(sourceApplication: nil)

        let item = try XCTUnwrap(clipStore.items.first)
        XCTAssertEqual(item.kind, .text)
        XCTAssertFalse(item.isImage)
        XCTAssertEqual(item.fullText, tsv)
        XCTAssertTrue(item.labels.contains("表格"))
        let stored = try XCTUnwrap(item.extraTypes)
        let intended = records.map(\.type)
        XCTAssertEqual(stored.map(\.type).filter { intended.contains($0) }, intended)
        for record in records {
            XCTAssertEqual(stored.first { $0.type == record.type }?.data, record.data, record.type)
        }

        clipStore.flushPendingPersistenceForTests()
        let reloaded = store(in: directory, defaults: defaults, payloads: payloads)
        let saved = try XCTUnwrap(reloaded.items.first { $0.id == item.id })
        XCTAssertEqual(saved.extraTypes, stored)
        XCTAssertEqual(saved.kind, .text)

        let destination = pasteboard()
        XCTAssertTrue(PasteService(store: reloaded, pasteboard: destination).restore(saved, to: destination))
        let replayed = SpreadsheetReplay.pasteRecords(from: stored).filter { !$0.type.hasPrefix("dyn.") }
        for record in replayed {
            let type = NSPasteboard.PasteboardType(record.type)
            XCTAssertEqual(destination.data(forType: type), record.data, record.type)
        }
        for dropped in ["public.tiff", "Embed Source", "ObjectLink", "Link Source", "com.adobe.pdf", "Apple PDF pasteboard type"] {
            XCTAssertNil(destination.data(forType: NSPasteboard.PasteboardType(dropped)), dropped)
        }
        XCTAssertEqual(destination.string(forType: .string), tsv)
        XCTAssertEqual(destination.string(forType: .html), tableHTML)

        let capturedAt = item.capturedAt
        var polledDuringPaste = false
        let pasting = PasteService(store: clipStore, pasteboard: source, commitPaste: { _ in
            monitor.poll(sourceApplication: nil)
            polledDuringPaste = true
        })
        pasting.monitor = monitor
        pasting.paste(item, preferredTarget: nil)
        XCTAssertTrue(polledDuringPaste)
        XCTAssertEqual(clipStore.items.map(\.id), [item.id])
        XCTAssertEqual(clipStore.items.first?.capturedAt, capturedAt)
        XCTAssertEqual(clipStore.items.first?.extraTypes, stored)
        for record in SpreadsheetReplay.pasteRecords(from: stored) where !record.type.hasPrefix("dyn.") {
            XCTAssertEqual(source.data(forType: NSPasteboard.PasteboardType(record.type)), record.data, record.type)
        }
        XCTAssertNil(source.data(forType: NSPasteboard.PasteboardType("public.tiff")))
        XCTAssertNil(source.data(forType: NSPasteboard.PasteboardType("Embed Source")))

        XCTAssertTrue(pasting.copyOriginalToClipboard(item))
        XCTAssertEqual(clipStore.items.first?.capturedAt, capturedAt)
        XCTAssertTrue(clipStore.lastCaptureStatus.contains("未粘贴"))
        monitor.poll(sourceApplication: nil)
        XCTAssertEqual(clipStore.items.map(\.id), [item.id])
        XCTAssertEqual(clipStore.items.first?.extraTypes, stored)
    }

    func testImageWrapperPasteboardIsStoredAsText() throws {
        let (directory, defaults, payloads) = try fixture()
        let source = pasteboard()
        let clipStore = store(in: directory, defaults: defaults, payloads: payloads)
        let monitor = ClipboardMonitor(store: clipStore, pasteboard: source)
        write(source, [
            ClipboardPasteboardType(type: "public.utf8-plain-text", data: Data(tsv.utf8)),
            ClipboardPasteboardType(type: "public.html", data: Data(imageHTML.utf8)),
            ClipboardPasteboardType(type: "public.tiff", data: try tiffData())
        ])
        monitor.poll(sourceApplication: nil)
        let item = try XCTUnwrap(clipStore.items.first)
        XCTAssertEqual(item.kind, .text)
        XCTAssertFalse(item.isImage)
        XCTAssertEqual(item.fullText, tsv)
        XCTAssertNil(item.imageFilename)
    }

    func testLegacyHistoryDecodesWithoutExtraTypes() throws {
        let (directory, defaults, payloads) = try fixture()
        let item = ClipboardClassifier.makeItem(
            text: "hello legacy",
            sourceApp: "Notes",
            sourceBundleID: nil,
            autoProtectSecrets: true,
            existingItem: nil
        )
        let encoded = try JSONEncoder().encode([item])
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in objects.indices {
            objects[index].removeValue(forKey: "extraTypes")
            objects[index].removeValue(forKey: "rtfData")
            objects[index].removeValue(forKey: "htmlData")
            objects[index].removeValue(forKey: "fileURLs")
        }
        let legacy = try JSONSerialization.data(withJSONObject: objects)
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: legacy)
        XCTAssertEqual(decoded.first?.fullText, "hello legacy")
        XCTAssertNil(decoded.first?.extraTypes)

        try legacy.write(to: directory.appendingPathComponent("history.json"))
        let clipStore = store(in: directory, defaults: defaults, payloads: payloads)
        let loaded = try XCTUnwrap(clipStore.items.first)
        XCTAssertEqual(loaded.fullText, "hello legacy")
        XCTAssertNil(loaded.extraTypes)
        XCTAssertNil(clipStore.historyLoadError)
    }

    func testMenuOffersClipboardRestoreAndExcelInsertOnlyForExcel() throws {
        let (directory, defaults, payloads) = try fixture()
        let source = pasteboard()
        let clipStore = store(in: directory, defaults: defaults, payloads: payloads)
        let monitor = ClipboardMonitor(store: clipStore, pasteboard: source)
        write(source, excelRecords(tiff: try tiffData()))
        monitor.poll(sourceApplication: nil)
        let item = try XCTUnwrap(clipStore.items.first)

        let excelTitles = titles(for: item, store: clipStore, excelBundleIDs: ["com.apple.dt.Xcode", SpreadsheetClipboard.excelBundleID])
        XCTAssertTrue(excelTitles.contains(SpreadsheetClipboard.copyOnlyTitle))
        XCTAssertTrue(excelTitles.contains(SpreadsheetShift.down.menuTitle))
        XCTAssertTrue(excelTitles.contains(SpreadsheetShift.right.menuTitle))

        let otherTitles = titles(for: item, store: clipStore, excelBundleIDs: ["com.apple.TextEdit"])
        XCTAssertTrue(otherTitles.contains(SpreadsheetClipboard.copyOnlyTitle))
        XCTAssertFalse(otherTitles.contains(SpreadsheetShift.down.menuTitle))
        XCTAssertFalse(otherTitles.contains(SpreadsheetShift.right.menuTitle))

        XCTAssertTrue(ExcelInsertOffer.shouldOffer(item: item, bundleIDs: [nil, SpreadsheetClipboard.excelBundleID]))
        XCTAssertFalse(ExcelInsertOffer.shouldOffer(item: item, bundleIDs: [nil, "com.apple.Notes"]))

        let plain = ClipboardClassifier.makeItem(
            text: "已经是纯文本",
            sourceApp: "备忘录",
            sourceBundleID: nil,
            autoProtectSecrets: false,
            existingItem: nil
        )
        XCTAssertFalse(ExcelInsertOffer.shouldOffer(item: plain, bundleIDs: [SpreadsheetClipboard.excelBundleID]))
        XCTAssertFalse(titles(for: plain, store: clipStore, excelBundleIDs: [SpreadsheetClipboard.excelBundleID]).contains("插入到 Excel（下移单元格）"))
    }

    func testInsertFallsBackToPasteWhenExcelRefusesOrIsMissing() throws {
        let (directory, defaults, payloads) = try fixture()
        let clipStore = store(in: directory, defaults: defaults, payloads: payloads)
        let source = pasteboard()
        let monitor = ClipboardMonitor(store: clipStore, pasteboard: source)
        write(source, excelRecords(tiff: try tiffData()))
        monitor.poll(sourceApplication: nil)
        let item = try XCTUnwrap(clipStore.items.first)
        let destination = pasteboard()
        let service = PasteService(store: clipStore, pasteboard: destination, commitPaste: { _ in })

        let wasRunning = ExcelAvailability.isRunning
        let wasApplication = ExcelAvailability.application
        defer {
            ExcelAvailability.isRunning = wasRunning
            ExcelAvailability.application = wasApplication
        }

        ExcelAvailability.isRunning = { false }
        service.insertIntoExcel(item, shift: .down) { _ in .inserted }
        XCTAssertEqual(clipStore.lastCaptureStatus, "Excel 没有在运行，已改为普通粘贴。")
        XCTAssertEqual(destination.string(forType: .string), tsv)
        XCTAssertEqual(destination.data(forType: NSPasteboard.PasteboardType("com.microsoft.Excel.Biff8")), Data([0xD0, 0xCF, 0x11, 0xE0, 0x01]))

        ExcelAvailability.isRunning = { true }
        ExcelAvailability.application = { nil }
        service.insertIntoExcel(item, shift: .right) { _ in .notPermitted }
        XCTAssertEqual(clipStore.lastCaptureStatus, "未获得控制 Excel 的权限，已改为普通粘贴。")
        XCTAssertEqual(destination.data(forType: NSPasteboard.PasteboardType("com.microsoft.Excel.XML")), Data("<worksheet>cells</worksheet>".utf8))

        service.insertIntoExcel(item, shift: .down) { _ in .failed }
        XCTAssertEqual(clipStore.lastCaptureStatus, "无法在当前工作表插入单元格，已改为普通粘贴。")

        service.insertIntoExcel(item, shift: .down) { script in
            XCTAssertTrue(script.contains("row size 2"))
            XCTAssertTrue(script.contains("column size 2"))
            XCTAssertTrue(script.contains("shift down"))
            return .inserted
        }
        XCTAssertEqual(clipStore.lastCaptureStatus, "已在 Excel 中插入 2×2 个单元格（下移）并粘贴")
    }

    func testSensitiveSpreadsheetTypesStayOutOfHistory() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let clipStore = store(in: directory, defaults: defaults, payloads: payloads)
        clipStore.sensitiveAutoExpireEnabled = false
        let secret = "A1\tclip-secret-excel-77aa"
        let extra = [ClipboardPasteboardType(type: "com.microsoft.Excel.XML", data: Data("<c>\(secret)</c>".utf8))]
        clipStore.ingestCopiedText(
            secret,
            sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords",
            richContent: ClipboardRepresentations.Snapshot(rtfData: nil, htmlData: nil, fileURLs: [], extraTypes: extra)
        )
        clipStore.flushPendingPersistenceForTests()
        let raw = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("clip-secret-excel-77aa"), raw)
        XCTAssertFalse(raw.contains("com.microsoft.Excel.XML"), raw)

        let reloaded = store(in: directory, defaults: defaults, payloads: payloads)
        let restored = try XCTUnwrap(reloaded.items.first { $0.privacy == .vault })
        XCTAssertEqual(restored.fullText, secret)
        XCTAssertEqual(restored.extraTypes, extra)
    }

    func testReplayOrderPrefersXMLAndHTMLAndDropsPictureAndOLE() throws {
        let html = """
        <html><head><style>
        td { mso-number-format:General; }
        .xl65 { mso-number-format:"\\@"; }
        .xl66 { mso-number-format:"yyyy\\\\-mm\\\\-dd"; }
        .xl67 { mso-number-format:"hh\\:mm"; }
        .xl68 { mso-number-format:"0.00"; }
        </style></head><body><table>
        <tr>
        <td class=xl65>00123</td>
        <td class=xl66>2026-11-16</td>
        <td class=xl67>09:30</td>
        <td class=xl68>42</td>
        </tr></table></body></html>
        """
        let xml = """
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
        let entries = [
            ClipboardPasteboardType(type: "public.utf8-plain-text", data: Data("00123\t2026-11-16\t09:30\t42".utf8)),
            ClipboardPasteboardType(type: "public.html", data: Data(html.utf8)),
            ClipboardPasteboardType(type: "public.tiff", data: Data([0x4D, 0x4D, 0x00, 0x2A])),
            ClipboardPasteboardType(type: "com.microsoft.Embed-Source", data: Data([0xD0, 0xCF, 0x11, 0xE0])),
            ClipboardPasteboardType(type: "com.microsoft.DataObject", data: Data(repeating: 0x11, count: 16)),
            ClipboardPasteboardType(type: "com.microsoft.Link", data: Data("Excel./tmp/book.xlsx".utf8)),
            ClipboardPasteboardType(type: "com.microsoft.ole.source.1.0x1", data: Data([0x01])),
            ClipboardPasteboardType(type: "XML Spreadsheet", data: Data(xml.utf8)),
            ClipboardPasteboardType(type: "Biff8", data: Data("biff".utf8))
        ]
        let replayed = SpreadsheetReplay.pasteRecords(from: entries).map(\.type)
        XCTAssertEqual(replayed, [
            "XML Spreadsheet",
            "Biff8",
            "public.html",
            "public.utf8-plain-text"
        ])
        XCTAssertTrue(SpreadsheetReplay.isExcluded("com.microsoft.Embed-Source"))
        XCTAssertTrue(SpreadsheetReplay.isExcluded("com.microsoft.DataObject"))
        XCTAssertTrue(SpreadsheetReplay.isExcluded("public.tiff"))
        XCTAssertTrue(ClipboardPasteboardKinds.isSpreadsheetNative("com.microsoft.Embed-Source"))
        XCTAssertTrue(ClipboardPasteboardKinds.isSpreadsheetNative("com.microsoft.ole.source.1.0x1"))

        let fromXML = SpreadsheetReplay.cells(in: entries)
        XCTAssertEqual(fromXML.map(\.kind), [.text, .date, .time, .number])
        XCTAssertEqual(fromXML.map(\.numberFormat), ["@", "yyyy-mm-dd", "hh:mm", "0.00"])
        XCTAssertEqual(fromXML.map(\.text), ["00123", "2026-11-16", "09:30", "42"])
        XCTAssertEqual(fromXML.map(\.column), [0, 1, 2, 3])

        let htmlOnly = entries.filter { $0.type != "XML Spreadsheet" }
        let fromHTML = SpreadsheetReplay.cells(in: htmlOnly)
        XCTAssertEqual(fromHTML.map(\.kind), [.text, .date, .time, .number])
        XCTAssertEqual(fromHTML.map(\.numberFormat), ["@", "yyyy-mm-dd", "hh:mm", "0.00"])
        XCTAssertEqual(fromHTML.map(\.text), ["00123", "2026-11-16", "09:30", "42"])

        let script = try XCTUnwrap(SpreadsheetReplay.formatScript(for: fromHTML))
        XCTAssertTrue(script.contains("number format of targetCell to \"@\""))
        XCTAssertTrue(script.contains("set value of targetCell to \"00123\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"yyyy-mm-dd\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"hh:mm\""))
        XCTAssertTrue(script.contains("number format of targetCell to \"0.00\""))
        XCTAssertFalse(script.contains("set value of targetCell to \"2026-11-16\""))
        XCTAssertEqual(SpreadsheetFormatParser.normalizedFormat("Fixed"), "0.00")
    }

    func testExcelImageFollowUpIsIgnoredAndANewCopyIsNot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let preview = Data("preview-tiff".utf8)
        func context(
            bundle: String = "com.microsoft.Excel",
            hasText: Bool = false,
            images: [Data] = [Data("other-render".utf8)],
            previousBundle: String? = "com.microsoft.Excel",
            age: TimeInterval = 30,
            previews: [Data] = [preview],
            suppressing: Bool = false
        ) -> SpreadsheetImageFollowUp.Context {
            SpreadsheetImageFollowUp.Context(
                sourceBundleID: bundle,
                hasMeaningfulText: hasText,
                imagePayloads: images,
                previousBundleID: previousBundle,
                previousIsSpreadsheetText: previousBundle != nil,
                previousCapturedAt: now.addingTimeInterval(-age),
                previousPreviewPayloads: previews,
                now: now,
                suppressingOwnRewrite: suppressing
            )
        }

        XCTAssertTrue(SpreadsheetImageFollowUp.shouldIgnore(context()))
        XCTAssertTrue(SpreadsheetImageFollowUp.shouldIgnore(context(images: [preview], previews: [preview])))
        XCTAssertFalse(SpreadsheetImageFollowUp.shouldIgnore(context(hasText: true, images: [preview])))
        XCTAssertFalse(SpreadsheetImageFollowUp.shouldIgnore(context(age: SpreadsheetImageFollowUp.recentInterval + 5)))
        XCTAssertTrue(SpreadsheetImageFollowUp.shouldIgnore(context(age: 10_000, suppressing: true)))
        XCTAssertFalse(SpreadsheetImageFollowUp.shouldIgnore(context(bundle: "com.apple.Preview")))
        XCTAssertFalse(SpreadsheetImageFollowUp.shouldIgnore(context(previousBundle: "com.apple.Notes")))
        XCTAssertTrue(SpreadsheetImageFollowUp.shouldIgnore(context(
            bundle: "com.apple.iWork.Numbers",
            previousBundle: "com.apple.iWork.Numbers"
        )))
        XCTAssertTrue(SpreadsheetImageFollowUp.shouldIgnore(context(
            bundle: "com.kingsoft.wpsoffice.mac",
            previousBundle: "com.kingsoft.wpsoffice.mac",
            age: 90
        )))
    }
}
