import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipFlowApp

@MainActor
final class CapturePriorityTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults)
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
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

    private func rtfData(_ text: String) throws -> Data {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
    }

    private func write(_ pasteboard: NSPasteboard, _ fill: (NSPasteboardItem) -> Void) {
        let item = NSPasteboardItem()
        fill(item)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    private func assertText(
        _ expected: String,
        on pasteboard: NSPasteboard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .text(let text) = ClipboardCapture.choose(from: pasteboard) else {
            return XCTFail("expected text, got \(String(describing: ClipboardCapture.choose(from: pasteboard)))", file: file, line: line)
        }
        XCTAssertEqual(text, expected, file: file, line: line)
    }

    private func assertImage(
        on pasteboard: NSPasteboard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .image = ClipboardCapture.choose(from: pasteboard) else {
            return XCTFail("expected an image, got \(String(describing: ClipboardCapture.choose(from: pasteboard)))", file: file, line: line)
        }
    }

    func testPlainTextWinsOverPreviewImage() throws {
        let pasteboard = pasteboard()
        let png = try pngData(width: 12, height: 8)
        write(pasteboard) { item in
            XCTAssertTrue(item.setString("  hello from the web\n", forType: .string))
            XCTAssertTrue(item.setString("<p>hello from the web</p>", forType: .html))
            XCTAssertTrue(item.setData(png, forType: .png))
            XCTAssertTrue(item.setData(png, forType: .tiff))
        }
        assertText("  hello from the web\n", on: pasteboard)
    }

    func testRTFWinsWhenPlainStringIsMissing() throws {
        let pasteboard = pasteboard()
        let png = try pngData(width: 4, height: 4)
        let rtf = try rtfData("from rtf")
        write(pasteboard) { item in
            XCTAssertTrue(item.setData(rtf, forType: .rtf))
            XCTAssertTrue(item.setString("<p>from html</p>", forType: .html))
            XCTAssertTrue(item.setData(png, forType: .tiff))
        }
        assertText("from rtf", on: pasteboard)
    }

    func testHTMLTextWinsWhenStringAndRTFAreMissing() throws {
        let pasteboard = pasteboard()
        let png = try pngData(width: 4, height: 4)
        write(pasteboard) { item in
            XCTAssertTrue(item.setString("<p>Tom &amp; Jerry</p><img alt=\"logo\" src=\"https://example.com/a.png\">", forType: .html))
            XCTAssertTrue(item.setData(png, forType: .png))
        }
        assertText("Tom & Jerry", on: pasteboard)
    }

    func testWhitespaceStringFallsThroughToHTML() throws {
        let pasteboard = pasteboard()
        write(pasteboard) { item in
            XCTAssertTrue(item.setString(" \n\t", forType: .string))
            XCTAssertTrue(item.setString("<div>from html</div>", forType: .html))
        }
        assertText("from html", on: pasteboard)
    }

    func testCopiedImageURLStaysTextWhenHTMLHasTheURL() throws {
        let pasteboard = pasteboard()
        let png = try pngData(width: 6, height: 6)
        let url = "https://example.com/cat.png"
        write(pasteboard) { item in
            XCTAssertTrue(item.setString(url, forType: .string))
            XCTAssertTrue(item.setString("<p>\(url)</p>", forType: .html))
            XCTAssertTrue(item.setData(png, forType: .png))
        }
        assertText(url, on: pasteboard)
    }

    func testImageOnlyHTMLIsAnImageEvenWhenTheStringIsTheSourceURL() throws {
        let pasteboard = pasteboard()
        let png = try pngData(width: 6, height: 6)
        let html = """
        <html><body><!--StartFragment--><img src="https://example.com/cat.png" alt="cat"><!--EndFragment--></body></html>
        """
        write(pasteboard) { item in
            XCTAssertTrue(item.setString("https://example.com/cat.png", forType: .string))
            XCTAssertTrue(item.setString(html, forType: .html))
            XCTAssertTrue(item.setData(png, forType: .png))
        }
        assertImage(on: pasteboard)
    }

    func testScreenshotWithoutTextIsAnImage() throws {
        let pasteboard = pasteboard()
        let png = try pngData(width: 8, height: 6)
        write(pasteboard) { item in
            XCTAssertTrue(item.setData(png, forType: .png))
        }
        guard case .image(.data(let data)) = ClipboardCapture.choose(from: pasteboard) else {
            return XCTFail("expected png bytes")
        }
        XCTAssertEqual(data, png)
    }

    func testImageFileWinsOverPathAndCaptionText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("shot.png")
        try pngData(width: 5, height: 3).write(to: fileURL)

        let pasteboard = pasteboard()
        let caption = "notes about \(fileURL.path)"
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL, caption as NSString]))
        XCTAssertEqual(pasteboard.string(forType: .string), caption)

        guard case .image(.file(let chosen)) = ClipboardCapture.choose(from: pasteboard) else {
            return XCTFail("expected the image file, got \(String(describing: ClipboardCapture.choose(from: pasteboard)))")
        }
        XCTAssertEqual(chosen, fileURL)
        let encoded = try XCTUnwrap(ClipboardImageEncoder.encode(.file(fileURL)))
        XCTAssertEqual(encoded.size, CGSize(width: 5, height: 3))
    }

    func testEmptyPasteboardIsIgnored() {
        let pasteboard = pasteboard()
        pasteboard.clearContents()
        XCTAssertNil(ClipboardCapture.choose(from: pasteboard))
    }

    func testEncoderAppliesOrientationAndHashesPNGBytes() throws {
        let wide = try pngData(width: 2, height: 1)
        guard let source = CGImageSourceCreateWithData(wide as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("could not read the fixture image")
        }

        let rotated = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(rotated, UTType.png.identifier as CFString, 1, nil) else {
            return XCTFail("could not create a png destination")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let encoded = ClipboardImageEncoder.encode(.data(rotated as Data))
        let payload = try XCTUnwrap(encoded)
        XCTAssertEqual(payload.size, CGSize(width: 1, height: 2))
        XCTAssertEqual(payload.signature, ClipboardImageEncoder.signature(for: payload.pngData))
        XCTAssertEqual(payload.signature.count, 64)
    }

    func testMonitorStoresTextInsteadOfThePreviewImage() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let pasteboard = pasteboard()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let png = try pngData(width: 10, height: 10)
        write(pasteboard) { item in
            XCTAssertTrue(item.setString("copied paragraph", forType: .string))
            XCTAssertTrue(item.setString("<p>copied paragraph</p>", forType: .html))
            XCTAssertTrue(item.setData(png, forType: .png))
        }

        monitor.poll(sourceApplication: nil)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.fullText, "copied paragraph")
        XCTAssertFalse(item.isImage)
        XCTAssertEqual(store.items.count, 1)
    }

    func testMonitorPublishesScreenshotAfterBackgroundEncode() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let pasteboard = pasteboard()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let png = try pngData(width: 8, height: 6)
        write(pasteboard) { item in
            XCTAssertTrue(item.setData(png, forType: .png))
        }

        monitor.poll(sourceApplication: nil)
        XCTAssertTrue(store.items.isEmpty)

        let item = try await waitForImage(in: store)
        XCTAssertEqual(item.imageWidth, 8)
        XCTAssertEqual(item.imageHeight, 6)
        XCTAssertEqual(store.items.count, 1)
        let stored = try XCTUnwrap(store.imageData(for: item))
        XCTAssertEqual(ClipboardImageEncoder.signature(for: stored), item.imageSignature)
    }

    func testStaleImageIsDroppedWhenThePasteboardChanges() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let pasteboard = pasteboard()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let gate = CaptureGate()
        defer { gate.release() }
        monitor.encodeImage = { source in
            gate.markStarted()
            gate.waitUntilReleased()
            return ClipboardImageEncoder.encode(source)
        }

        let png = try pngData(width: 4, height: 4)
        write(pasteboard) { item in
            XCTAssertTrue(item.setData(png, forType: .png))
        }
        monitor.poll(sourceApplication: nil)
        monitor.poll(sourceApplication: nil)
        let started = await gate.waitUntilStarted()
        XCTAssertTrue(started)
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertTrue(store.items.isEmpty)

        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("later text", forType: .string))
        gate.release()

        try await waitForText("later text", in: store)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.items.map(\.fullText), ["later text"])
        XCTAssertFalse(store.items.contains(where: \.isImage))
    }

    func testUnchangedPollDoesNotPurgeUntilTheInterval() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("private note", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let item = try XCTUnwrap(store.items.first)
        let capturedAt = try XCTUnwrap(item.capturedAt)

        let pasteboard = pasteboard()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let clock = TestClock(capturedAt)
        monitor.now = { clock.date }
        monitor.lastPurgeAt = clock.date

        monitor.poll(sourceApplication: nil)
        XCTAssertEqual(store.items.count, 1)

        clock.date = capturedAt.addingTimeInterval(301)
        monitor.lastPurgeAt = clock.date
        monitor.poll(sourceApplication: nil)
        XCTAssertEqual(store.items.count, 1)

        monitor.lastPurgeAt = clock.date.addingTimeInterval(-ClipFlowMotion.clipboardPurgeInterval)
        monitor.poll(sourceApplication: nil)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPasteboardChangePurgesWithoutWaitingForTheInterval() async throws {
        let (directory, defaults) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("private note", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let capturedAt = try XCTUnwrap(store.items.first?.capturedAt)

        let pasteboard = pasteboard()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let clock = TestClock(capturedAt.addingTimeInterval(301))
        monitor.now = { clock.date }
        monitor.lastPurgeAt = clock.date
        store.capturePaused = true
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("ignored while paused", forType: .string))

        monitor.poll(sourceApplication: nil)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.items.contains { $0.fullText == "ignored while paused" })
    }

    private func waitForImage(in store: ClipFlowStore) async throws -> ClipboardItem {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let item = store.items.first, item.isImage { return item }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for an image capture")
        throw WaitError.timedOut
    }

    private func waitForText(_ text: String, in store: ClipFlowStore) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if store.items.contains(where: { $0.fullText == text }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(text)")
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}

private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func markStarted() {
        lock.lock()
        calls += 1
        started = true
        lock.unlock()
    }

    func hasStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func waitUntilReleased() {
        while true {
            lock.lock()
            let done = released
            lock.unlock()
            if done { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func waitUntilStarted() async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if hasStarted() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
