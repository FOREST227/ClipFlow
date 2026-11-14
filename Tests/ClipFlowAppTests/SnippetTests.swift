import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class SnippetStoreTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, MemorySensitivePayloadRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowSnippetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults, MemorySensitivePayloadRepository())
    }

    private func makeStore() throws -> ClipFlowStore {
        let (directory, defaults, payloads) = try fixture()
        return ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
    }

    func testCreateEditDeleteAndPersist() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        let created = try XCTUnwrap(store.createSnippet(title: "  公司地址  ", body: "上海市徐汇区\n3 楼", category: " 地址 "))
        XCTAssertEqual(created.title, "公司地址")
        XCTAssertEqual(created.category, "地址")
        XCTAssertEqual(created.body, "上海市徐汇区\n3 楼")
        XCTAssertFalse(created.localOnly)
        XCTAssertTrue(store.updateSnippet(id: created.id, title: "", body: "上海市徐汇区\n5 楼", category: ""))
        let edited = try XCTUnwrap(store.snippet(withID: created.id))
        XCTAssertEqual(edited.title, "上海市徐汇区")
        XCTAssertNil(edited.category)
        XCTAssertEqual(edited.body, "上海市徐汇区\n5 楼")
        XCTAssertGreaterThan(edited.updatedAt, created.updatedAt)
        XCTAssertFalse(store.updateSnippet(id: created.id, title: "空", body: "   \n", category: nil))
        store.deleteSnippet(created.id)
        XCTAssertNil(store.snippet(withID: created.id))
        XCTAssertNotNil(store.snippetTombstones[created.id])

        store.flushPendingPersistenceForTests()
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        XCTAssertTrue(reloaded.snippets.isEmpty)
        XCTAssertNotNil(reloaded.snippetTombstones[created.id])
    }

    func testSnippetsSurviveHistoryTrimmingAndExpiry() throws {
        let store = try makeStore()
        let signature = try XCTUnwrap(store.createSnippet(title: "签名", body: "淇铖\nClipFlow", category: "签名"))
        store.ingestCopiedText("keep me", sourceApp: "Editor", sourceBundleID: nil)
        let pinnedID = try XCTUnwrap(store.items.first?.id)
        store.togglePin(pinnedID)
        for index in 0..<90 {
            store.ingestCopiedText("note \(index)", sourceApp: "Editor", sourceBundleID: nil)
        }
        XCTAssertEqual(store.items.count, store.maxItems)
        XCTAssertEqual(store.snippets.map(\.id), [signature.id])
        XCTAssertEqual(store.snippet(withID: signature.id)?.body, "淇铖\nClipFlow")

        store.sensitiveAutoExpireEnabled = true
        store.ingestCopiedText("clip-secret-expire", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let secret = try XCTUnwrap(store.items.first { $0.isSensitive })
        XCTAssertEqual(store.saveSnippet(from: secret, confirmingSensitive: false), .needsSensitiveConfirmation)
        XCTAssertEqual(store.snippets.count, 1)
        guard case .saved(let saved) = store.saveSnippet(from: secret, confirmingSensitive: true) else {
            return XCTFail("确认后应保存片段")
        }
        XCTAssertTrue(saved.localOnly)
        XCTAssertEqual(saved.body, secret.fullText)
        store.purgeExpired(at: Date().addingTimeInterval(600))
        XCTAssertNil(store.item(withID: secret.id))
        XCTAssertNotNil(store.snippet(withID: saved.id))
        XCTAssertNotNil(store.snippet(withID: signature.id))
    }

    func testSaveFromHistoryPreservesTheHistoryItem() throws {
        let store = try makeStore()
        store.ingestCopiedText("  hello\nworld  ", sourceApp: "备忘录", sourceBundleID: nil)
        let item = try XCTUnwrap(store.items.first)
        guard case .saved(let snippet) = store.saveSnippet(from: item, confirmingSensitive: false) else {
            return XCTFail("普通历史应直接存为片段")
        }
        XCTAssertEqual(snippet.body, "  hello\nworld  ")
        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertEqual(store.item(withID: item.id)?.fullText, item.fullText)
        XCTAssertEqual(store.lastCaptureStatus, SnippetLibrary.savedStatus)

        let image = ClipboardClassifier.makeImageItem(
            imageFilename: "missing.png", imageSignature: "sig", imageSize: CGSize(width: 10, height: 10),
            sourceApp: "预览", sourceBundleID: nil, existingItem: nil)
        XCTAssertFalse(SnippetLibrary.canSave(image))
        XCTAssertEqual(store.saveSnippet(from: image, confirmingSensitive: true), .unavailable)
        XCTAssertEqual(store.snippets.count, 1)
    }

    func testSensitiveSaveRequiresConfirmationAndStaysLocal() throws {
        let store = try makeStore()
        store.ingestCopiedText("clip-secret-snippet", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.isSensitive)
        store.requestSaveSnippet(fromItemID: item.id)
        XCTAssertEqual(store.sensitiveSnippetPrompt?.itemID, item.id)
        XCTAssertTrue(store.snippets.isEmpty)
        store.confirmSensitiveSnippetSave()
        XCTAssertNil(store.sensitiveSnippetPrompt)
        let snippet = try XCTUnwrap(store.snippets.first)
        XCTAssertEqual(snippet.body, "clip-secret-snippet")
        XCTAssertTrue(snippet.localOnly)
        XCTAssertEqual(store.lastCaptureStatus, SnippetLibrary.savedSensitiveStatus)
        store.cancelSensitiveSnippetSave()
        XCTAssertEqual(store.snippets.count, 1)
    }

    func testSearchMatchesTitleBodyAndCategoryOnly() throws {
        let store = try makeStore()
        _ = store.createSnippet(title: "公司地址", body: "徐汇区漕溪北路", category: "地址")
        _ = store.createSnippet(title: "问候", body: "你好，我是淇铖", category: "签名")
        _ = store.createSnippet(title: "发布说明", body: "swift test", category: nil)
        XCTAssertEqual(store.snippets(matching: "  ").count, 3)
        XCTAssertEqual(store.snippets(matching: "徐汇").map(\.title), ["公司地址"])
        XCTAssertEqual(store.snippets(matching: "签名").map(\.title), ["问候"])
        XCTAssertEqual(store.snippets(matching: "SWIFT").map(\.title), ["发布说明"])
        XCTAssertTrue(store.snippets(matching: "不存在").isEmpty)
    }

    func testReorderKeepsExplicitOrder() throws {
        let store = try makeStore()
        let first = try XCTUnwrap(store.createSnippet(title: "甲", body: "一", category: nil))
        let second = try XCTUnwrap(store.createSnippet(title: "乙", body: "二", category: nil))
        let third = try XCTUnwrap(store.createSnippet(title: "丙", body: "三", category: nil))
        XCTAssertEqual(store.snippets(matching: "").map(\.id), [third.id, second.id, first.id])
        store.moveSnippet(id: third.id, by: 1)
        XCTAssertEqual(store.snippets(matching: "").map(\.title), ["乙", "丙", "甲"])
        store.moveSnippets(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.snippets(matching: "").map(\.title), ["甲", "乙", "丙"])
    }

    func testHistoryMenuOffersSaveForTextOnly() throws {
        let store = try makeStore()
        store.ingestCopiedText("可以保存", sourceApp: "备忘录", sourceBundleID: nil)
        let text = try XCTUnwrap(store.items.first)
        let titles = menuTitles(for: text, store: store)
        XCTAssertTrue(titles.contains("存为片段"))
        let image = ClipboardClassifier.makeImageItem(
            imageFilename: "shot.png", imageSignature: "sig", imageSize: CGSize(width: 4, height: 4),
            sourceApp: "预览", sourceBundleID: nil, existingItem: nil)
        XCTAssertFalse(menuTitles(for: image, store: store).contains("存为片段"))
    }

    func testSnippetPasteWritesPlainText() throws {
        let (directory, defaults, payloads) = try fixture()
        let store = ClipFlowStore(
            storageDirectory: directory, defaults: defaults, payloadRepository: payloads,
            accessibility: AccessibilityTrust { _ in true })
        let snippet = try XCTUnwrap(store.createSnippet(title: "签名", body: "淇铖\nClipFlow", category: nil))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var commits = 0
        let service = PasteService(store: store, pasteboard: pasteboard, commitPaste: { _ in commits += 1 })
        service.pastePlainText(snippet.body, preferredTarget: nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "淇铖\nClipFlow")
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(pasteboard))
        XCTAssertTrue(store.lastCaptureStatus.hasPrefix("已粘贴到 "))
        XCTAssertEqual(commits, 1)
        service.pastePlainText(snippet.body, preferredTarget: nil, announcingPlain: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "淇铖\nClipFlow")
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(pasteboard))
        XCTAssertTrue(store.lastCaptureStatus.hasPrefix("已粘贴纯文本"))
        XCTAssertEqual(commits, 2)
        XCTAssertTrue(service.copyPlainText("  另一段  "))
        XCTAssertEqual(pasteboard.string(forType: .string), "  另一段  ")
        XCTAssertTrue(PlainTextPaste.containsOnlyPlainString(pasteboard))
    }

    func testQuickPasteKeysSwitchScopeAndPasteSnippets() throws {
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 124, modifiers: [.control, .function, .numericPad],
            isEditingText: true, isComposing: false, queryIsEmpty: false), .showSnippets)
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 123, modifiers: .control,
            isEditingText: false, isComposing: false, queryIsEmpty: true), .showHistory)
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 126, modifiers: [.option, .function],
            isEditingText: false, isComposing: false, queryIsEmpty: true), .reorder(-1))
        XCTAssertNil(ListKeyCommand.resolve(keyCode: 125, modifiers: .option,
            isEditingText: true, isComposing: false, queryIsEmpty: false),
            "Option-arrows still move by word inside a text field")
        XCTAssertNil(ListKeyCommand.resolve(keyCode: 124, modifiers: .control,
            isEditingText: true, isComposing: true, queryIsEmpty: true))
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 36, modifiers: .shift,
            isEditingText: true, isComposing: false, queryIsEmpty: false), .pastePlain,
            "⇧↩ on a snippet row is the same plain-text paste command as history")
    }

    func testExportSnippetScreenshots() throws {
        guard let destination = ProcessInfo.processInfo.environment["CLIPFLOW_SNIPPET_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_SNIPPET_SCREENSHOT_DIR to export snippet screenshots")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (directory, defaults, payloads) = try fixture()
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, payloadRepository: payloads)
        let address = try XCTUnwrap(store.createSnippet(
            title: "公司地址", body: "上海市徐汇区漕溪北路 18 号\n3 楼前台", category: "地址"))
        let signature = try XCTUnwrap(store.createSnippet(
            title: "邮件签名", body: "淇铖\nClipFlow 剪流\n复制过的内容，随时找回。", category: "签名"))
        _ = store.createSnippet(title: "常用回复", body: "收到，我看完后回复你。", category: "回复")
        _ = store.createSnippet(
            title: "Swift 模板",
            body: "func greeting(_ name: String) -> String {\n    \"你好，\\(name)\"\n}",
            category: "代码")
        _ = address
        _ = signature

        func bitmap(of view: NSView) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        func save(_ view: NSView, name: String) throws {
            try XCTUnwrap(try bitmap(of: view).representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func saveEditor(_ window: NSWindow, name: String) throws {
            let frameView = try XCTUnwrap(window.contentView?.superview)
            let base = try bitmap(of: frameView)
            let deadline = Date().addingTimeInterval(2)
            var sheet = window.sheets.first ?? window.attachedSheet
            while sheet == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                sheet = window.sheets.first ?? window.attachedSheet
            }
            let sheetWindow = try XCTUnwrap(sheet, "片段编辑器没有出现")
            let sheetView = try XCTUnwrap(sheetWindow.contentView)
            let sheetImage = try bitmap(of: sheetView)
            let canvas = NSImage(size: base.size)
            canvas.lockFocus()
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let origin = NSPoint(
                x: sheetWindow.frame.minX - window.frame.minX,
                y: sheetWindow.frame.minY - window.frame.minY)
            sheetImage.draw(in: NSRect(origin: origin, size: sheetWindow.frame.size))
            canvas.unlockFocus()
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.tiffRepresentation)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        func appear(_ name: NSAppearance.Name) {
            NSApp.appearance = NSAppearance(named: name)
        }

        let list = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let listWindow = try XCTUnwrap(list.window)
        listWindow.setContentSize(NSSize(width: 880, height: 640))
        appear(.aqua)
        listWindow.appearance = NSAppearance(named: .aqua)
        list.show(page: .snippets)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        try save(try XCTUnwrap(listWindow.contentView?.superview), name: "snippets-section-light")
        appear(.darkAqua)
        listWindow.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        try save(try XCTUnwrap(listWindow.contentView?.superview), name: "snippets-section-dark")
        listWindow.close()

        func exportEditor(_ appearance: NSAppearance.Name, name: String) throws {
            appear(appearance)
            let editor = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
            editor.navigation.initialSnippetEditor = .editing(signature)
            let editorWindow = try XCTUnwrap(editor.window)
            editorWindow.setContentSize(NSSize(width: 880, height: 720))
            editorWindow.appearance = NSAppearance(named: appearance)
            editor.show(page: .snippets)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            try saveEditor(editorWindow, name: name)
            editorWindow.close()
        }
        try exportEditor(.aqua, name: "snippet-editor-light")
        try exportEditor(.darkAqua, name: "snippet-editor-dark")

        func exportPanel(_ appearance: NSAppearance.Name, name: String) throws {
            appear(appearance)
            let host = NSHostingController(rootView: QuickPastePanelView(
                store: store, preferredTargetName: "备忘录", onPaste: { _ in }, onOpenLibrary: {}, onClose: {},
                initialScope: .snippets)
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.styleMask = [.borderless]
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(host.view.fittingSize)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            try save(host.view, name: name)
        }
        try exportPanel(.aqua, name: "quick-paste-snippets-light")
        try exportPanel(.darkAqua, name: "quick-paste-snippets-dark")
        appear(.aqua)
    }

    private func menuTitles(for item: ClipboardItem, store: ClipFlowStore) -> [String] {
        ClipboardRowMenu.entries(for: item, store: store, leading: []).compactMap { entry in
            if case .action(let title, _, _) = entry { return title }
            return nil
        }
    }
}

final class SnippetSyncTests: XCTestCase {
    func testMergeKeepsEverySnippetAndPrefersTheNewerEdit() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)
        let kept = sample("甲", body: "一", at: older, order: 0)
        var edited = kept
        edited.body = "改过"
        edited.updatedAt = newer
        let extra = sample("乙", body: "二", at: older, order: 1)
        let merged = ClipFlowSnippetMerge.merge(
            localSnippets: [edited],
            remoteSnippets: [kept, extra],
            localTombstones: [:],
            remoteTombstones: [:],
            now: newer
        )
        XCTAssertEqual(merged.snippets.map(\.id), [kept.id, extra.id])
        XCTAssertEqual(merged.snippets.first?.body, "改过")
    }

    func testMergeDoesNotApplyTheHistoryCap() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snippets = (0..<120).map { sample("片段\($0)", body: "正文\($0)", at: now, order: $0) }
        let merged = ClipFlowSnippetMerge.merge(
            localSnippets: snippets,
            remoteSnippets: [],
            localTombstones: [:],
            remoteTombstones: [:],
            now: now
        )
        XCTAssertEqual(merged.snippets.count, 120)
    }

    func testTombstoneRemovesUntilANewerEdit() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let deleted = created.addingTimeInterval(10)
        let revived = deleted.addingTimeInterval(10)
        let snippet = sample("甲", body: "一", at: created, order: 0)
        let removed = ClipFlowSnippetMerge.merge(
            localSnippets: [snippet],
            remoteSnippets: [],
            localTombstones: [snippet.id: deleted],
            remoteTombstones: [:],
            now: deleted
        )
        XCTAssertTrue(removed.snippets.isEmpty)
        var edited = snippet
        edited.updatedAt = revived
        edited.body = "又写了"
        let back = ClipFlowSnippetMerge.merge(
            localSnippets: [edited],
            remoteSnippets: [],
            localTombstones: [snippet.id: deleted],
            remoteTombstones: [:],
            now: revived
        )
        XCTAssertEqual(back.snippets.map(\.body), ["又写了"])
    }

    func testLocalOnlySnippetsNeverReachTheSyncedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appendingPathComponent("localImages")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: images, documentsDirectoryURL: directory)
        let now = Date()
        let shared = sample("地址", body: "徐汇区", at: now, order: 0)
        var secret = sample("密码", body: "clip-secret-snippet", at: now, order: 1)
        secret.localOnly = true
        let result = try coordinator.synchronizeSnippets(localSnippets: [shared, secret], tombstones: [:])
        XCTAssertEqual(result.snippets.map(\.title), ["地址"])
        let file = directory.appendingPathComponent("ClipFlow/snippets.json")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("徐汇区"))
        XCTAssertFalse(raw.contains("clip-secret-snippet"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ClipFlow/history.json").path))

        let again = try coordinator.synchronizeSnippets(localSnippets: [], tombstones: [shared.id: now.addingTimeInterval(5)])
        XCTAssertTrue(again.snippets.isEmpty)
        let afterDelete = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(afterDelete.contains("徐汇区"))
    }

    private func sample(_ title: String, body: String, at date: Date, order: Int) -> SavedSnippet {
        SavedSnippet(
            id: UUID(), title: title, body: body, category: nil,
            createdAt: date, updatedAt: date, order: order, localOnly: false
        )
    }
}
