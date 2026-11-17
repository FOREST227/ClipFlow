import AppKit
import SwiftUI

enum InspectorActionMetrics {
    static let spacing: CGFloat = 8
    static let lineSpacing: CGFloat = 8
    /// Footer content is inset from the glass on both sides.
    static let cardInset: CGFloat = 12
    static let menuInset: CGFloat = 8
    static let menuGap: CGFloat = 4

    static func actionWidth(contentWidth: CGFloat) -> CGFloat {
        max(1, contentWidth - cardInset * 2)
    }
}

enum InspectorAnchor {
    static let card = "ClipFlowInspector.drawer"
    static let actions = "ClipFlowInspector.actions"

    static func action(_ id: InspectorCommand.ID) -> String {
        if id == .paste { return "ClipFlowInspector.paste" }
        return "ClipFlowInspector.action.\(id.anchor)"
    }
}

/// Real card widths the detail overlay is given.
enum InspectorCardWidth {
    /// Quick-paste HUD. The panel is 360pt and the card keeps a 12pt gutter.
    static var quickPaste: CGFloat { QuickPastePanelLayout.panelWidth - 12 }
    /// Library window at its minimum content size. The card is the window minus the page gutter.
    static var libraryNarrow: CGFloat { min(620, ClipFlowLayout.libraryWidth - 24) }
    /// Library window at its maximum. The card itself stops at 620.
    static var libraryWide: CGFloat { 620 }
}

struct InspectorActionArrangement: Equatable {
    struct Item: Equatable {
        var index: Int
        var frame: CGRect
    }

    var items: [Item]
    var size: CGSize

    static func arrange(
        sizes: [CGSize],
        containerWidth: CGFloat,
        spacing: CGFloat = InspectorActionMetrics.spacing,
        lineSpacing: CGFloat = InspectorActionMetrics.lineSpacing,
        iconClusterCount: Int = 0
    ) -> InspectorActionArrangement {
        guard !sizes.isEmpty else { return InspectorActionArrangement(items: [], size: .zero) }
        let finite = containerWidth.isFinite && containerWidth < 100_000
        let limit = finite ? max(1, containerWidth) : CGFloat.greatestFiniteMagnitude
        let clusterCount = min(max(0, iconClusterCount), sizes.count)
        let clusterStart = sizes.count - clusterCount
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0

        func itemWidth(_ index: Int) -> CGFloat {
            min(max(0, sizes[index].width), limit)
        }
        func push(_ index: Int) {
            let width = itemWidth(index)
            if rowWidth > 0, rowWidth + spacing + width > limit + 0.5 {
                rows.append([index])
                rowWidth = width
            } else {
                rows[rows.count - 1].append(index)
                rowWidth = rowWidth == 0 ? width : rowWidth + spacing + width
            }
        }

        for index in 0..<clusterStart {
            push(index)
        }
        if clusterCount > 0 {
            let cluster = Array(clusterStart..<sizes.count)
            let clusterWidth = cluster.enumerated().reduce(CGFloat(0)) { partial, entry in
                partial + itemWidth(entry.element) + (entry.offset == 0 ? 0 : spacing)
            }
            if clusterWidth <= limit + 0.5, rowWidth > 0, rowWidth + spacing + clusterWidth > limit + 0.5 {
                rows.append([])
                rowWidth = 0
            }
            for index in cluster {
                push(index)
            }
        }
        rows.removeAll { $0.isEmpty }

        var items: [Item] = []
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = row.map { max(1, sizes[$0].height) }.max() ?? ClipFlowLayout.controlHeight
            var x: CGFloat = 0
            for index in row {
                let width = itemWidth(index)
                let height = max(1, sizes[index].height)
                let frame = CGRect(x: x, y: y + (rowHeight - height) / 2, width: width, height: height)
                items.append(Item(index: index, frame: frame))
                usedWidth = max(usedWidth, frame.maxX)
                x += width + spacing
            }
            y += rowHeight
            if rowIndex < rows.count - 1 {
                y += lineSpacing
            }
        }
        let width = finite ? limit : usedWidth
        return InspectorActionArrangement(items: items, size: CGSize(width: width, height: y))
    }
}

/// Screen-space top-left for an overflow menu. The menu extends down and to the right from that point.
enum InspectorMenuAnchor {
    static func topLeft(
        menuSize: CGSize,
        button: CGRect,
        card: CGRect,
        inset: CGFloat = InspectorActionMetrics.menuInset,
        gap: CGFloat = InspectorActionMetrics.menuGap
    ) -> CGPoint {
        let menuWidth = max(1, menuSize.width)
        let menuHeight = max(1, menuSize.height)
        var x = button.maxX - menuWidth
        let minX = card.minX + inset
        let maxX = card.maxX - inset - menuWidth
        if maxX >= minX {
            x = min(max(x, minX), maxX)
        } else {
            x = minX
        }

        let aboveTop = button.maxY + gap + menuHeight
        let belowTop = button.minY - gap
        func fits(_ top: CGFloat) -> Bool {
            let bottom = top - menuHeight
            return top <= card.maxY - inset + 0.5 && bottom >= card.minY + inset - 0.5
        }
        let preferred = fits(aboveTop) ? aboveTop : (fits(belowTop) ? belowTop : (button.midY < card.midY ? aboveTop : belowTop))
        var top = preferred
        if top > card.maxY - inset {
            top = card.maxY - inset
        }
        if top - menuHeight < card.minY + inset {
            top = card.minY + inset + menuHeight
        }
        if top > card.maxY - inset {
            top = card.maxY - inset
        }
        return CGPoint(x: x, y: top)
    }
}

struct InspectorActionFlow<Content: View>: View {
    let commands: [InspectorCommand]
    var iconClusterCount: Int
    @ViewBuilder var content: (InspectorCommand) -> Content

    var body: some View {
        Group {
            if #available(macOS 13, *) {
                wrapping
            } else {
                VStack(alignment: .leading, spacing: InspectorActionMetrics.lineSpacing) {
                    ForEach(commands, id: \.id) { command in
                        content(command).fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @available(macOS 13, *)
    private var wrapping: some View {
        InspectorWrappingLayout(
            spacing: InspectorActionMetrics.spacing,
            lineSpacing: InspectorActionMetrics.lineSpacing,
            iconClusterCount: iconClusterCount
        ) {
            ForEach(commands, id: \.id, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

@available(macOS 13, *)
struct InspectorWrappingLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var iconClusterCount: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let arranged = InspectorActionArrangement.arrange(
            sizes: ideals,
            containerWidth: proposal.width ?? .greatestFiniteMagnitude,
            spacing: spacing,
            lineSpacing: lineSpacing,
            iconClusterCount: iconClusterCount
        )
        guard let proposed = proposal.width, proposed.isFinite else { return arranged.size }
        return CGSize(width: proposed, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let arranged = InspectorActionArrangement.arrange(
            sizes: ideals,
            containerWidth: bounds.width,
            spacing: spacing,
            lineSpacing: lineSpacing,
            iconClusterCount: iconClusterCount
        )
        for item in arranged.items where subviews.indices.contains(item.index) {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height)
            )
        }
    }
}

@MainActor
enum InspectorViewLocator {
    static func view(named name: String, in window: NSWindow?) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(name)
        if let found = find(identifier, in: window?.contentView) { return found }
        for candidate in NSApp.windows where candidate !== window {
            if let found = find(identifier, in: candidate.contentView) { return found }
        }
        return nil
    }

    static func find(_ identifier: NSUserInterfaceItemIdentifier, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier == identifier { return view }
        for child in view.subviews {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }
}

/// A light popover in the detail card's glass palette. A system menu window captures as a flat grey slab.
@MainActor
enum InspectorOverflowMenu {
    private static var panel: NSPanel?
    private static var monitors: [Any] = []

    static func size(for entries: [InspectorOverflowEntry]) -> CGSize {
        InspectorOverflowMenuView.preferredSize(entries: entries)
    }

    @discardableResult
    static func present(
        entries: [InspectorOverflowEntry],
        in preferredWindow: NSWindow? = nil,
        handler: @escaping (InspectorOverflowAction) -> Void
    ) -> NSPanel? {
        dismiss()
        let host = preferredWindow ?? NSApp.keyWindow
        guard let anchor = InspectorViewLocator.view(named: InspectorAnchor.action(.more), in: host),
              let window = anchor.window else { return nil }
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let cardView = InspectorViewLocator.view(named: InspectorAnchor.card, in: window) ?? anchor
        let card = window.convertToScreen(cardView.convert(cardView.bounds, to: nil))
        let menuSize = size(for: entries)
        let topLeft = InspectorMenuAnchor.topLeft(menuSize: menuSize, button: button, card: card)
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let content = InspectorOverflowMenuView(entries: entries, isDark: dark) { action in
            dismiss()
            handler(action)
        }
        let popover = NSPanel(
            contentRect: NSRect(x: topLeft.x, y: topLeft.y - menuSize.height, width: menuSize.width, height: menuSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        popover.isOpaque = false
        popover.backgroundColor = .clear
        popover.hasShadow = true
        popover.level = .popUpMenu
        popover.collectionBehavior = [.transient, .ignoresCycle]
        popover.appearance = window.effectiveAppearance
        popover.contentView = content
        popover.setFrame(NSRect(x: topLeft.x, y: topLeft.y - menuSize.height, width: menuSize.width, height: menuSize.height), display: true)
        popover.orderFrontRegardless()
        panel = popover
        let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let point = NSEvent.mouseLocation
            if popover.frame.contains(point) { return event }
            dismiss()
            return event
        }
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                dismiss()
                return nil
            }
            return event
        }
        if let mouseMonitor { monitors.append(mouseMonitor) }
        if let keyMonitor { monitors.append(keyMonitor) }
        return popover
    }

    static func dismiss() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }
}

final class InspectorOverflowMenuView: NSView {
    static let rowHeight: CGFloat = 30
    static let separatorHeight: CGFloat = 9
    static let inset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
    static let cornerRadius: CGFloat = 12

    private let entries: [InspectorOverflowEntry]
    private let isDark: Bool
    private let handler: (InspectorOverflowAction) -> Void
    private var hovered: Int?

    init(entries: [InspectorOverflowEntry], isDark: Bool, handler: @escaping (InspectorOverflowAction) -> Void) {
        self.entries = entries
        self.isDark = isDark
        self.handler = handler
        let size = Self.preferredSize(entries: entries)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    static func preferredSize(entries: [InspectorOverflowEntry]) -> CGSize {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let shortcutFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        var titleWidth: CGFloat = 0
        var shortcutWidth: CGFloat = 0
        for entry in entries {
            guard case let .action(action) = entry else { continue }
            titleWidth = max(titleWidth, ceil((action.title as NSString).size(withAttributes: [.font: font]).width))
            if let shortcut = action.shortcut {
                shortcutWidth = max(shortcutWidth, ceil((shortcut as NSString).size(withAttributes: [.font: shortcutFont]).width))
            }
        }
        let shortcutGap: CGFloat = shortcutWidth > 0 ? 16 : 0
        let width = inset.left + 16 + 8 + titleWidth + shortcutGap + shortcutWidth + inset.right + 8
        var height = inset.top + inset.bottom
        for entry in entries {
            height += entry.isSeparator ? separatorHeight : rowHeight
        }
        return CGSize(width: max(188, width), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        let fill = isDark
            ? NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.987, blue: 0.992, alpha: 1)
        fill.setFill()
        shape.fill()
        let border = isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor(srgbRed: 0.65, green: 0.70, blue: 0.78, alpha: 0.55)
        border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        var y = Self.inset.top
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 10, y: y + Self.separatorHeight / 2))
                line.line(to: NSPoint(x: bounds.width - 10, y: Self.separatorHeight / 2 + y))
                (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)).setStroke()
                line.lineWidth = 1
                line.stroke()
                y += Self.separatorHeight
            case let .action(action):
                let row = NSRect(x: 4, y: y + 1, width: bounds.width - 8, height: Self.rowHeight - 2)
                if hovered == index {
                    let wash = action.isDestructive
                        ? NSColor.systemRed.withAlphaComponent(0.12)
                        : NSColor(srgbRed: 0.34, green: 0.58, blue: 0.95, alpha: 0.14)
                    wash.setFill()
                    NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
                }
                let color = action.isDestructive
                    ? NSColor.systemRed
                    : (isDark ? NSColor.white : NSColor.labelColor)
                let symbol = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
                symbol?.draw(in: NSRect(x: Self.inset.left, y: y + (Self.rowHeight - 16) / 2, width: 16, height: 16))
                let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
                let title = NSAttributedString(string: action.title, attributes: [
                    .font: titleFont,
                    .foregroundColor: color
                ])
                title.draw(at: NSPoint(x: Self.inset.left + 24, y: y + (Self.rowHeight - titleFont.boundingRectForFont.height) / 2))
                if let shortcut = action.shortcut {
                    let shortcutFont = NSFont.systemFont(ofSize: 12, weight: .medium)
                    let text = NSAttributedString(string: shortcut, attributes: [
                        .font: shortcutFont,
                        .foregroundColor: isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.secondaryLabelColor
                    ])
                    let size = text.size()
                    text.draw(at: NSPoint(x: bounds.width - Self.inset.right - size.width, y: y + (Self.rowHeight - size.height) / 2))
                }
                y += Self.rowHeight
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point), case let .action(action) = entries[index] else { return }
        handler(action)
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = rowIndex(at: point)
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        var y = Self.inset.top
        for (index, entry) in entries.enumerated() {
            let height = entry.isSeparator ? Self.separatorHeight : Self.rowHeight
            if !entry.isSeparator, point.y >= y, point.y < y + height { return index }
            y += height
        }
        return nil
    }
}

private extension InspectorOverflowEntry {
    var isSeparator: Bool {
        if case .separator = self { return true }
        return false
    }
}
