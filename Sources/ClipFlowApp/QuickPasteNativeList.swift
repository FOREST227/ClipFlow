import AppKit
import SwiftUI

/// One native owner for viewport, row geometry, and UUID/action mapping.
struct QuickPasteNativeList: NSViewRepresentable {
    let items: [ClipboardItem]
    let store: ClipFlowStore
    let selection: HistorySelection
    let isBlocked: () -> Bool
    let onSelect: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onInspect: (ClipboardItem) -> Void
    let onInspectFrom: (ClipboardItem, InspectorSourceAnchor) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> QuickPasteListView { QuickPasteListView() }
    func updateNSView(_ view: QuickPasteListView, context: Context) {
        view.update(items: items, store: store, selection: selection, enabled: enabled,
            scheme: scheme, locale: locale, isBlocked: isBlocked, onSelect: onSelect, onPaste: onPaste,
            onInspect: onInspect, onInspectFrom: onInspectFrom)
    }
}

@MainActor
final class QuickPasteListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, ClipboardRowEventOwner {
    private let table = NSTableView()
    private var items: [ClipboardItem] = []
    private var store: ClipFlowStore?
    private var selection: HistorySelection?
    private var inputEnabled = true
    private var blocksInput: () -> Bool = { false }
    private var scheme: ColorScheme = .light
    private var locale = Locale(identifier: "zh-Hans")
    private var selectItem: (ClipboardItem) -> Void = { _ in }
    private var pasteItem: (ClipboardItem) -> Void = { _ in }
    private var inspectItem: (ClipboardItem) -> Void = { _ in }
    private var inspectFrom: (ClipboardItem, InspectorSourceAnchor) -> Void = { _, _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Clipboard"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        documentView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? QuickPastePanel)?.clipboardList = self
    }

    func update(items next: [ClipboardItem], store: ClipFlowStore, selection: HistorySelection,
        enabled: Bool, scheme: ColorScheme, locale: Locale, isBlocked: @escaping () -> Bool,
        onSelect: @escaping (ClipboardItem) -> Void, onPaste: @escaping (ClipboardItem) -> Void,
        onInspect: @escaping (ClipboardItem) -> Void,
        onInspectFrom: @escaping (ClipboardItem, InspectorSourceAnchor) -> Void) {
        let changed = items != next
        let appearanceChanged = self.scheme != scheme || self.locale != locale || self.selection !== selection
        // Anchor an unchanged visible item, not the row whose pin/order just changed.
        let oldOffset = contentView.bounds.origin
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        var anchor: (UUID, CGFloat)?
        if changed {
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for index in visible.location..<min(items.count, NSMaxRange(visible)) {
                    let old = items[index]
                    if let current = nextByID[old.id], current == old {
                        anchor = (old.id, table.rect(ofRow: index).minY - oldOffset.y)
                        break
                    }
                }
            }
        }
        self.store = store; self.selection = selection
        self.inputEnabled = enabled; self.scheme = scheme; self.locale = locale
        self.blocksInput = isBlocked
        selectItem = onSelect; pasteItem = onPaste; inspectItem = onInspect; inspectFrom = onInspectFrom
        self.items = next
        if changed || appearanceChanged {
            table.reloadData()
            tile()
            let desired: CGFloat
            if let anchor, let index = next.firstIndex(where: { $0.id == anchor.0 }) {
                desired = table.rect(ofRow: index).minY - anchor.1
            } else { desired = oldOffset.y }
            let offset = min(max(0, desired), max(0, table.bounds.height - contentView.bounds.height))
            contentView.scroll(to: CGPoint(x: 0, y: offset))
            reflectScrolledClipView(contentView)
        }
        for cell in visibleCells {
            cell.row.interactionEnabled = enabled
        }
    }

    private var visibleCells: [QuickPasteTableCell] {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return (range.location..<min(items.count, NSMaxRange(range))).compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? QuickPasteTableCell
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        QuickPasteCardLayout.height(for: items[row].kind) + (row + 1 < items.count ? QuickPasteCardLayout.spacing : 0)
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClearRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard items.indices.contains(index), store != nil, selection != nil else { return nil }
        let item = items[index]
        let reuseID = NSUserInterfaceItemIdentifier("QuickPasteRow")
        let cell = table.makeView(withIdentifier: reuseID, owner: nil) as? QuickPasteTableCell ?? QuickPasteTableCell()
        cell.identifier = reuseID
        configure(cell, item: item)
        return cell
    }
    private func configure(_ cell: QuickPasteTableCell, item: ClipboardItem) {
        guard let store, let selection else { return }
        let identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        cell.cardHeight = QuickPasteCardLayout.height(for: item.kind)
        cell.row.identifier = identifier
        cell.row.interactionEnabled = inputEnabled
        cell.row.update(itemID: item.id,
            rootView: AnyView(HUDRow(item: item, store: store)
                .environment(\.colorScheme, scheme).environment(\.locale, locale)),
            selectionView: AnyView(HUDSelectionChrome(itemID: item.id, selection: selection, tint: item.kind.tint)
                .environment(\.colorScheme, scheme).environment(\.locale, locale)),
            onSelect: { [weak self] in self?.perform(item.id, action: .select) },
            onPaste: { [weak self] in self?.perform(item.id, action: .paste) },
            onInspect: InspectorSourceAnchor.callback(for: cell.row,
                fallback: { [weak self] in self?.perform(item.id, action: .inspect) },
                anchored: { [weak self] source in
                    guard let self, let current = self.currentItem(item.id) else { return }
                    self.inspectFrom(current, source)
                }))
        cell.layoutSubtreeIfNeeded()
    }
    private enum Action { case select, paste, inspect }
    private var canInteract: Bool {
        inputEnabled && !blocksInput() && window?.isVisible == true
            && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor && alphaValue > 0
    }
    private func currentItem(_ id: UUID) -> ClipboardItem? {
        guard canInteract, items.contains(where: { $0.id == id }) else { return nil }
        return store?.item(withID: id)
    }
    private func perform(_ id: UUID, action: Action) {
        guard let item = currentItem(id) else { return }
        switch action {
        case .select: selectItem(item)
        case .paste: pasteItem(item)
        case .inspect: inspectItem(item)
        }
    }

    /// Called before AppKit can reuse a prior multi-click recipient. No hosting-tree hit-test.
    func routeMouseDown(_ event: NSEvent) -> Bool {
        guard canInteract, window?.windowNumber == event.windowNumber else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil)) else { return false }
        if let root = window?.contentView,
           ClipboardRowHitView.isCoveredByForegroundSibling(above: self, in: root, event: event) { return false }
        if isOnScroller(event) { return false }
        if let row = clipboardRow(for: event) { row.mouseDown(with: event) }
        return true // A spacing gap is consumed, never redirected to the previous row.
    }
    private func isOnScroller(_ event: NSEvent) -> Bool {
        guard let scroller = verticalScroller, !scroller.isHidden else { return false }
        return scroller.frame.contains(convert(event.locationInWindow, from: nil))
    }
    func clipboardRow(for event: NSEvent) -> ClipboardRowHitView? {
        guard canInteract, !isOnScroller(event), let window, event.windowNumber == window.windowNumber,
              contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil)) else { return nil }
        let index = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard items.indices.contains(index),
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? QuickPasteTableCell,
              cell.row.representedItemID == items[index].id,
              cell.row.interactionEnabled, !cell.row.isHiddenOrHasHiddenAncestor else { return nil }
        let point = cell.row.convert(event.locationInWindow, from: nil)
        guard cell.row.bounds.contains(point), cell.row.visibleRect.contains(point) else { return nil }
        if let root = window.contentView, cell.row.isCoveredByForegroundSibling(in: root, event: event) { return nil }
        return cell.row
    }
}

private final class QuickPasteTableCell: NSTableCellView {
    let row = HUDInteractiveHostingView()
    var cardHeight: CGFloat = 64
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(row) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        row.frame = CGRect(x: 0, y: 0, width: bounds.width, height: cardHeight)
    }
}
private final class ClearRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}
