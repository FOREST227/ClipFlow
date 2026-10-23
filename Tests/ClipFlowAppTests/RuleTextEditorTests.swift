import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class RuleTextEditorTests: XCTestCase {
    func testEditorUsesFloatingScrollerAndPlainText() throws {
        _ = NSApplication.shared
        let scroll = RuleTextEditor.makeScrollView()
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertTrue(scroll.autohidesScrollers)
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertFalse(editor.isRichText)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
    }
    func testEditingPreservesMultilineDraft() throws {
        var draft = "com.example.one"
        let coordinator = RuleTextEditor.Coordinator(text: Binding(get: { draft }, set: { draft = $0 }))
        let editor = try XCTUnwrap(RuleTextEditor.makeScrollView().documentView as? NSTextView)
        editor.string = "com.example.one\ncom.example.two\n"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(draft, editor.string)
    }
}
