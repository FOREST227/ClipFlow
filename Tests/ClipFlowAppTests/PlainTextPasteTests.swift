import AppKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class PlainTextPasteTests: XCTestCase {
    private let original = """
    会议纪要
        先对齐范围
            再改文案

    保留空行与缩进
    """

    private func fixture() throws -> (URL, UserDefaults, MemorySensitivePayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PlainTextPaste.\(UUID().uuidString)"
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

    private func richData() throws -> (Data, Data) {
        let text = NSMutableAttributedString(string: original)
        let regular = NSFont.systemFont(ofSize: 14)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        text.addAttribute(.font, value: regular, range: NSRange(location: 0, length: text.length))
        let word = (original as NSString).range(of: "范围")
        text.addAttribute(.font, value: bold, range: word)
        let rtf = try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let html = Data("<p>会议纪要<br>　　先对齐范围</p>".utf8)
        return (rtf, html)
    }

    private func titles(for item: ClipboardItem, store: ClipFlowStore) -> [String] {
        ClipboardRowMenu.entries(for: item, store: store, leading: [
            .action(title: "粘贴", symbol: "arrow.down.doc") {}
        ]).compactMap { entry in
            if case let .action(title, _, _) = entry { return title }
            return nil
        }
    }

    func testPlainPasteWritesOnlyTheOriginalString() throws {
        let (directory, defaults, payloads) = try fixture()
        let (rtf, html) = try richData()
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads,
            accessibility: RecordingAccessibilityTrust(trusted: true))
        store.ingestCopiedText(
            original,
            sourceApp: "备忘录",
            sourceBundleID: nil,
            richContent: ClipboardRepresentations.Snapshot(
                rtfData: rtf,
                htmlData: html,
                fileURLs: [file.absoluteString]
            )
        )
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.fullText, original)
        XCTAssertEqual(item.rtfData, rtf)
        XCTAssertTrue(PlainTextPaste.hasRichText(item))

        let destination = pasteboard()
        var committed = 0
        let service = PasteService(store: store, pasteboard: destination, commitPaste: { _ in committed += 1 })
        service.paste(item, preferredTarget: nil, plainText: true)

        XCTAssertEqual(committed, 1)
        XCTAssertEqual(NSPasteboard.PasteboardType.string.rawValue, "public.utf8-plain-text")
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(destination))
        XCTAssertEqual(
            destination.string(forType: NSPasteboard.PasteboardType(PlainTextPaste.legacyStringTypeName)),
            original
        )
        XCTAssertEqual(destination.string(forType: .string), original)
        XCTAssertNil(destination.data(forType: .rtf))
        XCTAssertNil(destination.string(forType: .html))
        XCTAssertNil(destination.data(forType: .html))
        XCTAssertNil(destination.string(forType: .fileURL))
        XCTAssertNil(destination.propertyList(forType: ClipboardRepresentations.filenamesType))
        let files = destination.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(files ?? [], [])

        let kept = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(kept.fullText, original)
        XCTAssertEqual(kept.rtfData, rtf)
        XCTAssertEqual(kept.htmlData, html)
        XCTAssertEqual(kept.fileURLs, [file.absoluteString])
        XCTAssertTrue(store.lastCaptureStatus.hasPrefix("已粘贴纯文本"))

        let richBoard = pasteboard()
        XCTAssertTrue(service.restore(kept, to: richBoard))
        XCTAssertNotNil(richBoard.data(forType: .rtf))
        XCTAssertEqual(richBoard.string(forType: .html), String(data: html, encoding: .utf8))
        XCTAssertEqual(richBoard.string(forType: .string), original)

        let copyBoard = pasteboard()
        let copying = PasteService(store: store, pasteboard: copyBoard)
        XCTAssertTrue(copying.copyToClipboard(kept, plainText: true))
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(copyBoard))
        XCTAssertEqual(copyBoard.string(forType: .string), original)
        XCTAssertNil(copyBoard.data(forType: .rtf))
        XCTAssertTrue(store.lastCaptureStatus.contains("纯文本"))
    }

    func testUntrustedPlainPasteKeepsTheStringAndSkipsTheKeystroke() throws {
        let (directory, defaults, _) = try fixture()
        let trust = RecordingAccessibilityTrust(trusted: false)
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, accessibility: trust)
        let (rtf, _) = try richData()
        store.ingestCopiedText(original, sourceApp: "备忘录", sourceBundleID: nil,
            richContent: ClipboardRepresentations.Snapshot(rtfData: rtf, htmlData: nil, fileURLs: []))
        let item = try XCTUnwrap(store.items.first)
        let destination = pasteboard()
        var committed = 0
        let service = PasteService(store: store, pasteboard: destination, commitPaste: { _ in committed += 1 })

        service.paste(item, preferredTarget: nil, plainText: true)

        XCTAssertEqual(committed, 0)
        XCTAssertEqual(trust.prompts, [true])
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(destination))
        XCTAssertEqual(destination.string(forType: .string), original)
        XCTAssertNil(destination.data(forType: .rtf))
        XCTAssertTrue(store.lastCaptureStatus.contains("辅助功能"))
        XCTAssertTrue(store.lastCaptureStatus.contains("剪贴板"))
        XCTAssertEqual(store.startupPermissionReport?.title, "自动粘贴需要辅助功能")
    }

    func testMaskedSecretPastesTheRealTextAndStaysHidden() throws {
        let (directory, defaults, payloads) = try fixture()
        defaults.set(false, forKey: "sensitiveAutoExpireEnabled")
        let secret = "    clip-secret-rtf-77aa\n        下一行仍缩进"
        let text = NSMutableAttributedString(string: secret)
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: text.length))
        let rtf = try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        store.sensitiveAutoExpireEnabled = false
        store.ingestCopiedText(secret, sourceApp: "密码", sourceBundleID: "com.apple.Passwords",
            richContent: ClipboardRepresentations.Snapshot(rtfData: rtf, htmlData: nil, fileURLs: []))
        let item = try XCTUnwrap(store.items.first)
        XCTAssertNotEqual(item.privacy, .standard)
        XCTAssertFalse(store.isRevealed(item))
        XCTAssertNotEqual(store.displayFullText(for: item), secret)
        XCTAssertTrue(PlainTextPaste.hasRichText(item))

        let destination = pasteboard()
        let service = PasteService(store: store, pasteboard: destination, commitPaste: { _ in })
        service.paste(item, preferredTarget: nil, plainText: true)

        XCTAssertEqual(destination.string(forType: .string), secret)
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(destination))
        XCTAssertNil(destination.data(forType: .rtf))
        let kept = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(kept.fullText, secret)
        XCTAssertEqual(kept.rtfData, rtf)
        XCTAssertFalse(store.isRevealed(kept))
        XCTAssertNotEqual(store.displayFullText(for: kept), secret)
    }

    func testPlainAndImageItemsOmitThePlainTextActions() throws {
        let (directory, defaults, _) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let (rtf, html) = try richData()
        let rich = ClipboardClassifier.makeItem(text: original, sourceApp: "备忘录", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil,
            richContent: ClipboardRepresentations.Snapshot(rtfData: rtf, htmlData: html, fileURLs: []))
        let htmlOnly = ClipboardClassifier.makeItem(text: "kept formatting", sourceApp: "Safari", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil,
            richContent: ClipboardRepresentations.Snapshot(rtfData: nil, htmlData: html, fileURLs: []))
        let filesOnly = ClipboardClassifier.makeItem(text: "/tmp/a\n/tmp/b", sourceApp: "访达", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil,
            richContent: ClipboardRepresentations.Snapshot(rtfData: nil, htmlData: nil, fileURLs: ["file:///tmp/a"]))
        let plain = ClipboardClassifier.makeItem(text: "已经是纯文本", sourceApp: "备忘录", sourceBundleID: nil,
            autoProtectSecrets: false, existingItem: nil)
        let image = ClipboardClassifier.makeImageItem(imageFilename: "shot.png", imageSignature: "sig",
            imageSize: CGSize(width: 4, height: 3), sourceApp: "预览", sourceBundleID: nil, existingItem: nil)

        XCTAssertEqual(titles(for: rich, store: store), ["粘贴", "复制", "粘贴为纯文本", "复制为纯文本", "置顶", "存为片段", "删除条目"])
        XCTAssertEqual(titles(for: htmlOnly, store: store), ["粘贴", "复制", "粘贴为纯文本", "复制为纯文本", "置顶", "存为片段", "删除条目"])
        XCTAssertEqual(titles(for: filesOnly, store: store), ["粘贴", "复制", "置顶", "存为片段", "删除条目"])
        XCTAssertEqual(titles(for: plain, store: store), ["粘贴", "复制", "置顶", "存为片段", "删除条目"])
        XCTAssertFalse(titles(for: image, store: store).contains("存为片段"))
        XCTAssertFalse(titles(for: image, store: store).contains(PlainTextPaste.pasteTitle))
        XCTAssertFalse(titles(for: image, store: store).contains(PlainTextPaste.copyTitle))
        XCTAssertFalse(PlainTextPaste.hasRichText(image))
        XCTAssertFalse(PlainTextPaste.canPasteAsPlainText(image))

        let destination = pasteboard()
        destination.setString("leave-this", forType: .string)
        store.ingestCopiedImage(Data([0x89, 0x50, 0x4E, 0x47]), size: CGSize(width: 1, height: 1),
            sourceApp: "预览", sourceBundleID: nil)
        let storedImage = try XCTUnwrap(store.items.first(where: \.isImage))
        var committed = 0
        let service = PasteService(store: store, pasteboard: destination, commitPaste: { _ in committed += 1 })
        service.paste(storedImage, preferredTarget: nil, plainText: true)
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(destination.string(forType: .string), "leave-this")
        XCTAssertEqual(store.lastCaptureStatus, "这项内容不能粘贴为纯文本")
    }

    func testPlainPasteShortcutUsesSeparateGlyphRuns() {
        let shortcut = PlainTextPaste.quickPasteShortcut
        XCTAssertEqual(shortcut.displayName, "⇧↩")
        XCTAssertEqual(ShortcutGlyphLayout.plainText(for: shortcut), "⇧↩")
        let runs = ShortcutGlyphLayout.runs(for: shortcut, font: NSFont.systemFont(ofSize: 9, weight: .semibold))
        XCTAssertEqual(runs.map(\.text), ["⇧", "↩"])
        XCTAssertEqual(runs.last?.baselineOffset, 0)
        XCTAssertTrue(PlainTextPaste.isPlainTextClick(.shift))
        XCTAssertFalse(PlainTextPaste.isPlainTextClick([.shift, .command]))
        XCTAssertFalse(PlainTextPaste.isPlainTextClick([]))
    }
}
