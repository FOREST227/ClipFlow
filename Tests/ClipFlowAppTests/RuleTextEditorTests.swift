import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class RuleTextEditorTests: XCTestCase {
    func testEditorKeepsAVisibleScrollerAndPlainText() throws {
        _ = NSApplication.shared
        let scroll = RuleTextEditor.makeScrollView()
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertFalse(scroll.hasVerticalScroller, "The system scroller hides, so the list draws its own track")
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        let list = try XCTUnwrap(scroll as? ExclusionListScrollView)
        XCTAssertGreaterThan(RuleTextEditor.viewportHeight(), 160)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        XCTAssertGreaterThanOrEqual(RuleTextEditor.viewportHeight(), lineHeight * CGFloat(RuleTextEditor.visibleLines))
        editor.string = PasswordManagerApps.bundleIDs.joined(separator: "\n")
        editor.frame.size.width = 360
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let used = editor.layoutManager?.usedRect(for: editor.textContainer!).height ?? 0
        XCTAssertGreaterThan(used, RuleTextEditor.viewportHeight(),
            "The default exclusion list must extend past the visible rows")
        list.frame = NSRect(x: 0, y: 0, width: 360, height: RuleTextEditor.viewportHeight())
        list.layoutSubtreeIfNeeded()
        XCTAssertFalse(list.position.isHidden)
        XCTAssertLessThan(list.position.knob.height, list.position.bounds.height - 1)
        XCTAssertEqual(editor.accessibilityLabel(), "排除应用 Bundle ID")
        XCTAssertEqual(editor.accessibilityHelp(), "可上下滚动，查看其余 Bundle ID。")
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
