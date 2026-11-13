import AppKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class RichPasteboardTests: XCTestCase {
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

    private func makeStore(
        in directory: URL,
        defaults: UserDefaults,
        payloads: MemorySensitivePayloadRepository
    ) -> ClipFlowStore {
        ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func boldRTF(plain: String, boldWord: String) throws -> Data {
        let text = NSMutableAttributedString(string: plain)
        let regular = NSFont.systemFont(ofSize: 14)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        text.addAttribute(.font, value: regular, range: NSRange(location: 0, length: (plain as NSString).length))
        text.addAttribute(.font, value: bold, range: (plain as NSString).range(of: boldWord))
        return try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
    }

    private func assertBoldFormatting(on pasteboard: NSPasteboard, plain: String, boldWord: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(pasteboard.data(forType: .rtf), "restored pasteboard has no RTF", file: file, line: line)
        let restored = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil), file: file, line: line)
        XCTAssertEqual(restored.string, plain, file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), plain, file: file, line: line)

        let boldRange = (plain as NSString).range(of: boldWord)
        let boldFont = try XCTUnwrap(restored.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont, file: file, line: line)
        let prefixFont = try XCTUnwrap(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, file: file, line: line)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), file: file, line: line)
        XCTAssertFalse(NSFontManager.shared.traits(of: prefixFont).contains(.boldFontMask), file: file, line: line)
    }

    func testRTFRoundTripPreservesFormatting() throws {
        let (directory, defaults, payloads) = try fixture()
        let plain = "Hello bold"
        let rtf = try boldRTF(plain: plain, boldWord: "bold")
        let source = pasteboard()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let monitor = ClipboardMonitor(store: store, pasteboard: source)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(rtf, forType: .rtf))
        source.clearContents()
        XCTAssertTrue(source.writeObjects([item]))
        monitor.poll(sourceApplication: nil)

        let (restoredItem, destination) = try reload(store, directory: directory, defaults: defaults, payloads: payloads)
        XCTAssertEqual(restoredItem.fullText, plain)
        XCTAssertEqual(restoredItem.rtfData, rtf)
        XCTAssertNil(restoredItem.htmlData)
        XCTAssertNil(restoredItem.fileURLs)
        try assertBoldFormatting(on: destination, plain: plain, boldWord: "bold")
    }

    func testHTMLRoundTripPreservesMarkup() throws {
        let (directory, defaults, payloads) = try fixture()
        let html = "<p><em>kept</em> formatting</p>"
        let source = pasteboard()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let monitor = ClipboardMonitor(store: store, pasteboard: source)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(html, forType: .html))
        source.clearContents()
        XCTAssertTrue(source.writeObjects([item]))
        monitor.poll(sourceApplication: nil)

        let (restoredItem, destination) = try reload(store, directory: directory, defaults: defaults, payloads: payloads)
        XCTAssertEqual(restoredItem.fullText, "kept formatting")
        XCTAssertEqual(restoredItem.htmlData, Data(html.utf8))
        XCTAssertNil(restoredItem.rtfData)
        XCTAssertEqual(destination.string(forType: .html), html)
        XCTAssertEqual(destination.string(forType: .string), "kept formatting")
    }

    func testMultipleFileURLsRoundTrip() throws {
        let (directory, defaults, payloads) = try fixture()
        let folder = directory.appendingPathComponent("copied-files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("notes.txt")
        let second = folder.appendingPathComponent("picture-list.txt")
        try Data("notes".utf8).write(to: first)
        try Data("pictures".utf8).write(to: second)

        let source = pasteboard()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let monitor = ClipboardMonitor(store: store, pasteboard: source)
        source.clearContents()
        XCTAssertTrue(source.writeObjects([first as NSURL, second as NSURL]))
        monitor.poll(sourceApplication: nil)

        let (restoredItem, destination) = try reload(store, directory: directory, defaults: defaults, payloads: payloads)
        let expected = [first, second].map(canonicalPath)
        let stored = try XCTUnwrap(restoredItem.fileURLs).compactMap(URL.init(string:)).map(canonicalPath)
        XCTAssertEqual(stored, expected)

        let readBack = (destination.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []).map(canonicalPath)
        XCTAssertEqual(readBack, expected)

        let names = try XCTUnwrap(
            destination.propertyList(forType: ClipboardRepresentations.filenamesType) as? [String]
        )
        XCTAssertEqual(names.map { canonicalPath(URL(fileURLWithPath: $0)) }, expected)
        XCTAssertFalse(destination.string(forType: .string)?.isEmpty ?? true)
    }

    func testLegacyHistoryDecodesWithoutRichRepresentations() throws {
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
        let removedKeys = [
            "rtfData", "htmlData", "fileURLs",
            "pinnedAt", "secretPayloadRef", "secretPayloadUnavailable", "capturedAt"
        ]
        for index in objects.indices {
            for key in removedKeys {
                objects[index].removeValue(forKey: key)
            }
        }
        let legacy = try JSONSerialization.data(withJSONObject: objects)
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: legacy)
        XCTAssertEqual(decoded.first?.fullText, "hello legacy")
        XCTAssertNil(decoded.first?.rtfData)
        XCTAssertNil(decoded.first?.htmlData)
        XCTAssertNil(decoded.first?.fileURLs)
        XCTAssertNil(decoded.first?.secretPayloadRef)

        try legacy.write(to: directory.appendingPathComponent("history.json"))
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let loaded = try XCTUnwrap(store.items.first)
        XCTAssertEqual(loaded.fullText, "hello legacy")
        XCTAssertNil(loaded.rtfData)
        XCTAssertNil(loaded.htmlData)
        XCTAssertNil(loaded.fileURLs)
        XCTAssertNil(store.historyLoadError)

        let destination = pasteboard()
        XCTAssertTrue(PasteService(store: store).restore(loaded, to: destination))
        XCTAssertEqual(destination.string(forType: .string), "hello legacy")
        XCTAssertNil(destination.data(forType: .rtf))
        XCTAssertNil(destination.string(forType: .html))
        XCTAssertNil(destination.propertyList(forType: ClipboardRepresentations.filenamesType))
    }

    func testSensitiveFormattingStaysOutOfHistoryAndRestoresFromKeychain() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let secret = "clip-secret-rtf-77aa"
        let rtf = try boldRTF(plain: "note \(secret)", boldWord: secret)
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
        store.sensitiveAutoExpireEnabled = false
        store.ingestCopiedText(
            "note \(secret)",
            sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords",
            richContent: ClipboardRepresentations.Snapshot(rtfData: rtf, htmlData: nil, fileURLs: [])
        )
        store.flushPendingPersistenceForTests()

        let historyURL = directory.appendingPathComponent("history.json")
        let raw = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(secret), raw)
        let persisted = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL))
        let storedSecret = try XCTUnwrap(persisted.first { $0.secretPayloadRef != nil })
        XCTAssertEqual(storedSecret.fullText, "")
        XCTAssertNil(storedSecret.rtfData)
        XCTAssertNil(storedSecret.htmlData)
        XCTAssertNil(storedSecret.fileURLs)

        let reloaded = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let restoredItem = try XCTUnwrap(reloaded.items.first { $0.privacy == .vault })
        XCTAssertEqual(restoredItem.fullText, "note \(secret)")
        XCTAssertEqual(restoredItem.rtfData, rtf)
        XCTAssertEqual(restoredItem.secretPayloadRef, storedSecret.secretPayloadRef)

        let destination = pasteboard()
        XCTAssertTrue(PasteService(store: reloaded).restore(restoredItem, to: destination))
        try assertBoldFormatting(on: destination, plain: "note \(secret)", boldWord: secret)
    }

    func testImageRestoreStillWritesThePicture() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = makeStore(in: directory, defaults: defaults, payloads: payloads)
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
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        store.ingestCopiedImage(png, size: CGSize(width: 4, height: 3), sourceApp: "Editor", sourceBundleID: nil)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.isImage)

        let destination = pasteboard()
        XCTAssertTrue(PasteService(store: store).restore(item, to: destination))
        XCTAssertNotNil(NSImage(pasteboard: destination))
        XCTAssertNil(destination.string(forType: .string))
    }

    private func reload(
        _ store: ClipFlowStore,
        directory: URL,
        defaults: UserDefaults,
        payloads: MemorySensitivePayloadRepository
    ) throws -> (ClipboardItem, NSPasteboard) {
        let captured = try XCTUnwrap(store.items.first)
        store.flushPendingPersistenceForTests()
        let reloaded = makeStore(in: directory, defaults: defaults, payloads: payloads)
        let item = try XCTUnwrap(reloaded.items.first { $0.id == captured.id })
        let destination = pasteboard()
        XCTAssertTrue(PasteService(store: reloaded).restore(item, to: destination))
        return (item, destination)
    }
}
