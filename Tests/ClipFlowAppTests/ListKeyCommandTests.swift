import AppKit
import Combine
import XCTest
@testable import ClipFlowApp

@MainActor
final class ListKeyCommandTests: XCTestCase {
    private func resolve(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                         editing: Bool = false, composing: Bool = false, emptyQuery: Bool = true) -> ListKeyCommand? {
        ListKeyCommand.resolve(keyCode: keyCode, modifiers: modifiers, isEditingText: editing,
            isComposing: composing, queryIsEmpty: emptyQuery)
    }

    func testArrowsReturnAndSpaceMapToListCommands() {
        // Arrow keys always carry the function and numeric-pad flags.
        XCTAssertEqual(resolve(126, [.function, .numericPad]), .moveUp)
        XCTAssertEqual(resolve(125, [.function, .numericPad]), .moveDown)
        XCTAssertEqual(resolve(36), .activate)
        XCTAssertEqual(resolve(76), .activate)
        XCTAssertEqual(resolve(49), .toggleDetails)
        XCTAssertNil(resolve(0))
        XCTAssertNil(resolve(125, .shift), "Modified arrows stay with the text field")
        XCTAssertNil(resolve(36, .command))
    }

    func testCommandDigitsPasteByPosition() {
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, keyCode) in digits.enumerated() {
            XCTAssertEqual(resolve(keyCode, .command, editing: true, emptyQuery: false), .pasteIndex(index))
        }
        XCTAssertNil(resolve(29, .command), "⌘0 is not a row")
        XCTAssertNil(resolve(18), "A bare digit is search text")
        XCTAssertNil(resolve(18, [.command, .shift]))
    }

    func testSpaceBelongsToANonEmptySearchField() {
        XCTAssertEqual(resolve(49, editing: true, emptyQuery: true), .toggleDetails)
        XCTAssertNil(resolve(49, editing: true, emptyQuery: false))
        XCTAssertEqual(resolve(49, editing: false, emptyQuery: false), .toggleDetails)
    }

    func testInputMethodCompositionKeepsEveryKey() {
        for keyCode: UInt16 in [125, 126, 36, 76, 49] {
            XCTAssertNil(resolve(keyCode, editing: true, composing: true))
        }
        XCTAssertNil(resolve(18, .command, editing: true, composing: true))
    }

    func testSelectionMovesClampsAndRequestsReveal() {
        let selection = HistorySelection()
        let ids = [UUID(), UUID(), UUID()]
        var revealed: [UUID] = []
        let observation = selection.revealRequests.sink { revealed.append($0) }
        XCTAssertEqual(selection.move(by: 1, in: ids), ids[0], "Without a selection, down starts at the top")
        XCTAssertEqual(selection.move(by: 1, in: ids), ids[1])
        XCTAssertEqual(selection.move(by: 1, in: ids), ids[2])
        XCTAssertEqual(selection.move(by: 1, in: ids), ids[2], "The last row does not wrap")
        XCTAssertEqual(selection.move(by: -1, in: ids), ids[1])
        selection.itemID = nil
        XCTAssertEqual(selection.move(by: -1, in: ids), ids[2], "Without a selection, up starts at the bottom")
        selection.itemID = UUID()
        XCTAssertEqual(selection.move(by: 1, in: ids), ids[0], "A filtered-out selection restarts at the top")
        XCTAssertNil(selection.move(by: 1, in: []))
        XCTAssertEqual(revealed, [ids[0], ids[1], ids[2], ids[2], ids[1], ids[2], ids[0]])

        selection.select(ids[1], reveal: false)
        XCTAssertEqual(selection.itemID, ids[1])
        XCTAssertEqual(revealed.count, 7, "Pointer selection must not scroll the list")
        withExtendedLifetime(observation) {}
    }

    func testFiltersMatchTheirKindAndPinnedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipFlowFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("周五发布清单，记得更新截图。", sourceApp: "备忘录", sourceBundleID: nil)
        store.ingestCopiedText("https://github.com/FOREST227/ClipFlow", sourceApp: "Safari", sourceBundleID: nil)
        store.ingestCopiedText("func greeting() -> String {\n    return \"hi\"\n}", sourceApp: "Xcode", sourceBundleID: nil)
        XCTAssertEqual(ClipCategory.allCases, [.all, .pinned, .text, .code, .links, .images, .protected])
        XCTAssertEqual(store.count(for: .all), store.items.count)
        for (category, kind) in [(ClipCategory.text, ClipboardKind.text), (.code, .code), (.links, .link), (.images, .image)] {
            XCTAssertEqual(store.count(for: category), store.items.filter { $0.kind == kind }.count)
        }
        XCTAssertEqual(store.count(for: .pinned), 0, "Recent items are not pinned items")
        let link = try XCTUnwrap(store.items.first { $0.kind == .link })
        store.togglePin(link.id)
        store.selectedCategory = .pinned
        XCTAssertEqual(store.filteredItems.map(\.id), [link.id])
        XCTAssertEqual(store.count(for: .protected), store.items.filter(\.isSensitive).count)
    }
}

@MainActor
final class ListKeyboardFlowTests: XCTestCase {
    private func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 10,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode))
    }

    func testQuickPasteKeyboardSelectsPastesAndOpensDetails() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<4 { _ = try context.text("Keyboard fixture \(n)") }
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        let keys = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, ListKeyCommandView.self).first)
        let items = context.store.hudItems(matching: "")
        fixture.window.makeFirstResponder(nil)

        XCTAssertTrue(keys.handle(try key(125, in: fixture.window)))
        XCTAssertTrue(keys.handle(try key(36, in: fixture.window)))
        XCTAssertEqual(fixture.probe.pasted, [items[1].id], "Return pastes the keyboard selection")
        XCTAssertEqual(fixture.probe.closes, 1)
        XCTAssertTrue(keys.handle(try key(20, .command, in: fixture.window)))
        XCTAssertEqual(fixture.probe.pasted.last, items[2].id, "⌘3 pastes the third row")
        XCTAssertFalse(keys.handle(try key(25, .command, in: fixture.window)), "There is no ninth row")
        XCTAssertEqual(fixture.probe.pasted.count, 2)

        XCTAssertTrue(keys.handle(try key(49, in: fixture.window)))
        fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.itemID, items[2].id)
        XCTAssertFalse(keys.handle(try key(36, in: fixture.window)), "Rows behind the details ignore the keyboard")
        XCTAssertEqual(fixture.probe.pasted.count, 2)
    }

    func testHistoryKeyboardMovesSelectionAndOpensDetails() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<4 { _ = try context.text("History keyboard fixture \(n)") }
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        let keys = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, ListKeyCommandView.self).first)
        let items = context.store.filteredItems
        context.store.select(items[0])
        fixture.window.makeFirstResponder(nil)

        XCTAssertTrue(keys.handle(try key(125, in: fixture.window)))
        XCTAssertEqual(context.store.selectedItemID, items[1].id)
        XCTAssertTrue(keys.handle(try key(126, in: fixture.window)))
        XCTAssertTrue(keys.handle(try key(126, in: fixture.window)))
        XCTAssertEqual(context.store.selectedItemID, items[0].id, "The first row does not wrap")
        XCTAssertTrue(keys.handle(try key(18, .command, in: fixture.window)), "⌘1 pastes the first visible history row")
        XCTAssertEqual(context.store.selectedItemID, items[0].id)

        // The harness hosts the page the way the main window does: the report is drawn outside it.
        context.store.startupPermissionReport = ClipFlowPermissionReport(title: "权限", message: "", items: [])
        XCTAssertFalse(keys.handle(try key(125, in: fixture.window)))
        XCTAssertFalse(keys.handle(try key(36, in: fixture.window)), "Keys must not act behind the permission report")
        XCTAssertEqual(context.store.selectedItemID, items[0].id)
        XCTAssertNil(fixture.inspector.snapshot.itemID)
        context.store.startupPermissionReport = nil

        XCTAssertTrue(keys.handle(try key(125, in: fixture.window)))
        XCTAssertTrue(keys.handle(try key(49, in: fixture.window)))
        fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.itemID, items[1].id)
        XCTAssertFalse(keys.handle(try key(125, in: fixture.window)), "Rows behind the details ignore the keyboard")
        XCTAssertEqual(context.store.selectedItemID, items[1].id)
    }
}
