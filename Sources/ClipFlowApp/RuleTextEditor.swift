import AppKit
import SwiftUI

/// Own the native scroll view so SwiftUI does not restore a legacy scrollbar gutter.
struct RuleTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        let editor = scroll.documentView as! NSTextView
        editor.string = text
        editor.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        let selection = editor.selectedRange()
        editor.string = text
        let count = (text as NSString).length
        let location = min(selection.location, count)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        editor.undoManager?.removeAllActions()
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.setAccessibilityLabel("排除应用 Bundle ID")
        scroll.documentView = editor
        return scroll
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
