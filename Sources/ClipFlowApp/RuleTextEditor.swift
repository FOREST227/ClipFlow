import AppKit
import SwiftUI

/// Own the native scroll view so the exclusion list can show a stable scrollbar.
struct RuleTextEditor: NSViewRepresentable {
    /// Enough rows to scan the list; the rest stay under a visible scroller.
    static let visibleLines = 12

    static func viewportHeight(font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular),
        lines: Int = visibleLines) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        // textContainerInset is 4 points on the top and bottom.
        return ceil(lineHeight * CGFloat(lines) + 8)
    }
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
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let count = (text as NSString).length
            let location = min(selection.location, count)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
            editor.undoManager?.removeAllActions()
        }
        (scroll as? ExclusionListScrollView)?.refreshPosition()
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = ExclusionListScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // The system scroller hides itself. The list draws its own track instead.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false

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
        editor.textContainerInset = NSSize(width: 8, height: 4)
        editor.setAccessibilityLabel("排除应用 Bundle ID")
        editor.setAccessibilityHelp("可上下滚动，查看其余 Bundle ID。")
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

/// A track and knob that stay on screen whenever the exclusion list overflows.
final class ExclusionListScrollView: NSScrollView {
    let position = ExclusionScrollPosition()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        position.translatesAutoresizingMaskIntoConstraints = true
        addSubview(position)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPosition),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        refreshPosition()
    }

    @objc func refreshPosition() {
        let viewport = contentView.bounds.height
        let content = documentView?.bounds.height ?? 0
        let overflows = content > viewport + 1 && viewport > 0
        position.isHidden = !overflows
        guard overflows else { return }
        let width: CGFloat = 5
        position.frame = NSRect(x: bounds.width - width - 5, y: 6, width: width, height: max(0, bounds.height - 12))
        let knobHeight = max(28, min(position.bounds.height, position.bounds.height * viewport / content))
        let travel = max(0, position.bounds.height - knobHeight)
        let span = max(1, content - viewport)
        let progress = min(1, max(0, contentView.bounds.minY / span))
        position.knob = NSRect(x: 0, y: travel * (1 - progress), width: width, height: knobHeight)
        position.needsDisplay = true
    }
}

final class ExclusionScrollPosition: NSView {
    var knob = NSRect.zero
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }
}
