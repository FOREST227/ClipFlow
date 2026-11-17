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

@MainActor
enum InspectorOverflowMenu {
    private static let target = Target()

    static func makeMenu(
        actions: [InspectorOverflowAction],
        handler: @escaping (InspectorOverflowAction) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        target.actions = actions
        target.handler = handler
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(Target.invoke(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            if action.isDestructive {
                item.attributedTitle = NSAttributedString(string: action.title, attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.menuFont(ofSize: 0)
                ])
            }
            menu.addItem(item)
        }
        return menu
    }

    static func size(of menu: NSMenu) -> CGSize {
        let measured = menu.size
        if measured.width > 1, measured.height > 1 {
            return measured
        }
        return estimatedSize(titles: menu.items.map(\.title))
    }

    static func estimatedSize(titles: [String]) -> CGSize {
        let font = NSFont.menuFont(ofSize: 0)
        var textWidth: CGFloat = 0
        for title in titles {
            textWidth = max(textWidth, ceil((title as NSString).size(withAttributes: [.font: font]).width))
        }
        let width = textWidth + 88
        let height = CGFloat(max(titles.count, 1)) * 28 + 16
        return CGSize(width: width, height: height)
    }

    static func popUp(
        actions: [InspectorOverflowAction],
        willPresent: ((NSMenu) -> Void)? = nil,
        handler: @escaping (InspectorOverflowAction) -> Void
    ) {
        let menu = makeMenu(actions: actions, handler: handler)
        defer { target.handler = nil }
        guard let anchor = InspectorViewLocator.view(named: InspectorAnchor.action(.more), in: NSApp.keyWindow) else { return }
        guard let window = anchor.window else { return }
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let cardView = InspectorViewLocator.view(named: InspectorAnchor.card, in: window) ?? anchor
        let card = window.convertToScreen(cardView.convert(cardView.bounds, to: nil))
        let origin = InspectorMenuAnchor.topLeft(menuSize: size(of: menu), button: button, card: card)
        willPresent?(menu)
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    private final class Target: NSObject {
        var actions: [InspectorOverflowAction] = []
        var handler: ((InspectorOverflowAction) -> Void)?

        @objc func invoke(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            handler?(actions[sender.tag])
        }
    }
}
