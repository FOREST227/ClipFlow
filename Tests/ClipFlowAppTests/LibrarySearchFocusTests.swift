import AppKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class LibrarySearchFocusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    func testEscapeClearsOnlyAFocusedCommittedQuery() {
        XCTAssertTrue(LibrarySearchFocus.escapeClearsQuery(query: "会议", fieldFocused: true, isComposing: false))
        XCTAssertTrue(LibrarySearchFocus.escapeClearsQuery(query: " ", fieldFocused: true, isComposing: false))
        XCTAssertFalse(LibrarySearchFocus.escapeClearsQuery(query: "", fieldFocused: true, isComposing: false))
        XCTAssertFalse(LibrarySearchFocus.escapeClearsQuery(query: "会议", fieldFocused: false, isComposing: false))
        XCTAssertFalse(LibrarySearchFocus.escapeClearsQuery(query: "会议", fieldFocused: true, isComposing: true))
    }

    func testFindShortcutStaysWithTheEditMenu() {
        XCTAssertNil(ListKeyCommand.resolve(keyCode: 3, modifiers: .command, isEditingText: true,
            isComposing: false, queryIsEmpty: false), "⌘F is Find, not a list command")
        XCTAssertNil(ListKeyCommand.resolve(keyCode: 53, modifiers: [], isEditingText: true,
            isComposing: false, queryIsEmpty: false), "Escape is not a list command")
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 125, modifiers: [.function, .numericPad],
            isEditingText: true, isComposing: false, queryIsEmpty: false), .moveDown)
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 36, modifiers: [], isEditingText: true,
            isComposing: false, queryIsEmpty: false), .activate)
        XCTAssertEqual(ListKeyCommand.resolve(keyCode: 49, modifiers: [], isEditingText: true,
            isComposing: false, queryIsEmpty: true), .toggleDetails)
        XCTAssertNil(ListKeyCommand.resolve(keyCode: 49, modifiers: [], isEditingText: true,
            isComposing: false, queryIsEmpty: false))
        XCTAssertNil(ListKeyCommand.resolve(keyCode: 125, modifiers: [.function, .numericPad],
            isEditingText: true, isComposing: true, queryIsEmpty: true))
    }

    func testInactiveFocusModelIgnoresRequests() {
        let inactive = LibrarySearchFocusModel.inactive
        inactive.request()
        XCTAssertEqual(inactive.requestID, 0)
        let model = LibrarySearchFocusModel()
        model.request()
        model.request()
        XCTAssertEqual(model.requestID, 2)
    }

    func testNearestTextFieldStaysOnTheSearchRow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        window.contentView?.addSubview(root)
        let search = NSTextField(frame: NSRect(x: 40, y: 180, width: 200, height: 24))
        let other = NSTextField(frame: NSRect(x: 40, y: 24, width: 200, height: 24))
        let anchor = NSView(frame: search.frame)
        root.addSubview(search)
        root.addSubview(other)
        root.addSubview(anchor)
        XCTAssertTrue(LibrarySearchFocus.nearestTextField(from: anchor) === search)
        let unplaced = NSView(frame: .zero)
        root.addSubview(unplaced)
        XCTAssertNil(LibrarySearchFocus.nearestTextField(from: unplaced))
    }

    func testEditMenuFindItemUsesCommandF() throws {
        let store = try makeStore()
        let delegate = ClipFlowAppDelegate(store: store)
        let previousMenu = NSApp.mainMenu
        let previousServices = NSApp.servicesMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.servicesMenu = previousServices
        }
        delegate.configureMainMenu()
        let edit = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "编辑")?.submenu)
        let find = try XCTUnwrap(edit.item(withTitle: "查找"))
        XCTAssertEqual(find.keyEquivalent, "f")
        XCTAssertEqual(find.keyEquivalentModifierMask, .command)
        XCTAssertTrue(find.target === delegate)
        XCTAssertEqual(find.action, #selector(ClipFlowAppDelegate.focusLibrarySearchFromMenu(_:)))
        let titles = edit.items.map(\.title)
        let selectAll = try XCTUnwrap(titles.firstIndex(of: "全选"))
        let findIndex = try XCTUnwrap(titles.firstIndex(of: "查找"))
        XCTAssertGreaterThan(findIndex, selectAll)
    }

    func testOpeningHistoryFocusesSearchAndEscapeClearsBeforeDismissing() throws {
        let store = try makeStore()
        store.ingestCopiedText("alpha notes", sourceApp: "备忘录", sourceBundleID: nil)
        store.ingestCopiedText("beta notes", sourceApp: "备忘录", sourceBundleID: nil)
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"), initialPage: .settings)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show(page: .settings)
        waitUntil { window.isVisible }
        XCTAssertFalse(LibrarySearchFocus.searchFieldIsFirstResponder(in: window), "Settings must not take the search field")
        controller.navigation.select(.history)
        waitUntil { !anchors(in: window).isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(LibrarySearchFocus.searchFieldIsFirstResponder(in: window),
            "Choosing history in the sidebar must not steal focus")

        controller.show(page: .history)
        assertSearchIsFocused(in: window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("会议", replacementRange: NSRange(location: 0, length: 0))
        waitUntil { store.searchText.contains("会议") }
        XCTAssertTrue(store.searchText.contains("会议"), "Typed text belongs to the library search field, got \(store.searchText)")

        let keys = try XCTUnwrap(descendants(window.contentView, ListKeyCommandView.self).first)
        let escape = try XCTUnwrap(descendants(window.contentView, InspectorEscapeView.self).first)
        XCTAssertTrue(escape.handleEscape(try key(53, characters: "\u{1b}", in: window)))
        XCTAssertEqual(store.searchText, "", "Escape clears the query while the search field is focused")
        XCTAssertFalse(escape.handleEscape(try key(53, characters: "\u{1b}", in: window)),
            "The next Escape is left alone when the query is empty and details are closed")

        waitUntil { keys.queryIsEmpty }
        let items = store.filteredItems
        store.select(items[0])
        XCTAssertTrue(keys.handle(try key(125, in: window)), "Down arrow still moves the list while search is focused")
        XCTAssertEqual(store.selectedItemID, items[1].id)
        XCTAssertTrue(keys.handle(try key(126, in: window)))
        XCTAssertEqual(store.selectedItemID, items[0].id)
        XCTAssertTrue(keys.handle(try key(49, in: window)), "Space still opens the preview from an empty search field")
        XCTAssertTrue(escape.handleEscape(try key(53, characters: "\u{1b}", in: window)),
            "Escape still dismisses the preview when the query is empty")

        store.searchText = "beta"
        waitUntil { !keys.queryIsEmpty }
        XCTAssertTrue(LibrarySearchFocus.searchFieldIsFirstResponder(in: window))
        XCTAssertFalse(keys.handle(try key(49, in: window)), "Space in a non-empty query belongs to the field")
        XCTAssertTrue(keys.handle(try key(36, in: window)), "Return still opens the selected row")
        focusSearchField(in: window)
        XCTAssertTrue(escape.handleEscape(try key(53, characters: "\u{1b}", in: window)))
        XCTAssertEqual(store.searchText, "", "The first Escape clears the query and leaves the preview up")
        XCTAssertTrue(escape.handleEscape(try key(53, characters: "\u{1b}", in: window)),
            "The next Escape dismisses the preview")

        focusSearchField(in: window)
        let composer = try XCTUnwrap(window.firstResponder as? NSTextView)
        let selected = store.selectedItemID
        composer.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: composer.selectedRange())
        XCTAssertTrue(composer.hasMarkedText())
        XCTAssertTrue(LibrarySearchFocus.isComposing(in: window))
        XCTAssertFalse(keys.handle(try key(125, in: window)), "Arrow keys stay with the input method")
        XCTAssertEqual(store.selectedItemID, selected)
        store.searchText = "beta"
        XCTAssertFalse(escape.handleEscape(try key(53, characters: "\u{1b}", in: window)),
            "Escape cancels composition before it clears the query")
        XCTAssertEqual(store.searchText, "beta")
        composer.unmarkText()

        window.makeFirstResponder(nil)
        XCTAssertFalse(LibrarySearchFocus.searchFieldIsFirstResponder(in: window))
        controller.show(page: .history)
        assertSearchIsFocused(in: window)
    }

    private func focusSearchField(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let field = LibrarySearchFocus.markedSearchField(in: window)
        if let field {
            window.makeFirstResponder(field)
        }
        XCTAssertTrue(LibrarySearchFocus.searchFieldIsFirstResponder(in: window),
            "Expected to put the search field back in focus", file: file, line: line)
    }

    private func assertSearchIsFocused(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil { LibrarySearchFocus.searchFieldIsFirstResponder(in: window) }
        if !LibrarySearchFocus.searchFieldIsFirstResponder(in: window) {
            print("SEARCH_FOCUS responder=\(String(describing: window.firstResponder)) key=\(window.isKeyWindow) visible=\(window.isVisible)")
            if let content = window.contentView { describe(content) }
        }
        XCTAssertTrue(LibrarySearchFocus.searchFieldIsFirstResponder(in: window),
            "Library search should be first responder", file: file, line: line)
        XCTAssertEqual(LibrarySearchFocus.markedSearchField(in: window)?.identifier?.rawValue,
            LibrarySearchFocus.fieldIdentifier, file: file, line: line)
    }

    private func describe(_ view: NSView, depth: Int = 0) {
        if depth > 8 { return }
        let indent = String(repeating: " ", count: depth * 2)
        if view is NSTextField || view is LibrarySearchFieldAnchorView {
            print("SEARCH_FOCUS \(indent)\(type(of: view)) id=\((view as? NSTextField)?.identifier?.rawValue ?? "-") frame=\(view.frame)")
        }
        for subview in view.subviews { describe(subview, depth: depth + 1) }
    }

    private func anchors(in window: NSWindow) -> [LibrarySearchFieldAnchorView] {
        descendants(window.contentView, LibrarySearchFieldAnchorView.self)
    }

    private func descendants<T: NSView>(_ view: NSView?, _ type: T.Type) -> [T] {
        guard let view else { return [] }
        return (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants($0, type) }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func key(_ keyCode: UInt16, characters: String = "", in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func makeStore() throws -> ClipFlowStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipFlowSearchFocus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return ClipFlowStore(storageDirectory: directory, defaults: defaults)
    }
}

