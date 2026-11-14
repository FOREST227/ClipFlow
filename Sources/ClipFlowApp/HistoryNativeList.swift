import AppKit
import Combine
import SwiftUI

/// Document positions for the history list. Row heights are fixed, so a later
/// layout pass cannot invent a new frame for an item that is already on screen.
enum HistoryRowGeometry {
    static func place(items: [ClipboardItem], width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            let height = LibraryCardLayout.height(for: item.kind)
            frames.append(CGRect(x: 0, y: y, width: max(1, width), height: height))
            y += height
            if index + 1 < items.count { y += LibraryCardLayout.spacing }
        }
        return (frames, y)
    }
}

/// One hosting view per item. `LazyVStack` on Xcode 26.3 allocates a new
/// `LibraryInteractiveHostingView` when the inspector lays out, even for a row
/// that already intersects the clip. This list creates a view only the first
/// time that row intersects the clip, then keeps that same view.
struct HistoryNativeList: NSViewRepresentable {
    let items: [ClipboardItem]
    let revealedItemIDs: Set<UUID>
    let store: ClipFlowStore
    let palette: ClipFlowPalette
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)?
    let onInspectItem: (ClipboardItem) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> HistoryRowScrollView { HistoryRowScrollView() }

    func updateNSView(_ view: HistoryRowScrollView, context: Context) {
        view.apply(items: items, revealedItemIDs: revealedItemIDs, store: store, palette: palette,
            enabled: isEnabled, colorScheme: colorScheme, onInspectFrom: onInspectFrom,
            onInspectItem: onInspectItem)
    }
}

@MainActor
final class HistoryRowScrollView: NSScrollView {
    private let document = HistoryRowDocument()
    private var revealObservation: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.document.materialize() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(items: [ClipboardItem], revealedItemIDs: Set<UUID>, store: ClipFlowStore,
        palette: ClipFlowPalette, enabled: Bool, colorScheme: ColorScheme,
        onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)?,
        onInspectItem: @escaping (ClipboardItem) -> Void) {
        if revealObservation == nil {
            revealObservation = store.historySelection.revealRequests.sink { [weak self] id in
                self?.reveal(id)
            }
        }
        document.apply(items: items, revealedItemIDs: revealedItemIDs, store: store, palette: palette,
            enabled: enabled, colorScheme: colorScheme, onInspectFrom: onInspectFrom,
            onInspectItem: onInspectItem)
    }

    private func reveal(_ id: UUID) {
        let clip = contentView.bounds
        let placed = HistoryRowGeometry.place(items: document.items, width: clip.width)
        guard let index = document.items.firstIndex(where: { $0.id == id }),
              placed.frames.indices.contains(index) else { return }
        let frame = placed.frames[index]
        let target: CGFloat
        if frame.minY < clip.minY {
            target = frame.minY
        } else if frame.maxY > clip.maxY {
            target = frame.maxY - clip.height
        } else {
            return
        }
        let y = min(max(0, target), max(0, placed.height - clip.height))
        let origin = contentView.bounds.origin
        guard abs(origin.y - y) > 0.5 else { return }
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        document.materialize()
    }
}

@MainActor
final class HistoryRowDocument: NSView {
    private(set) var items: [ClipboardItem] = []
    private var revealedItemIDs: Set<UUID> = []
    private var store: ClipFlowStore?
    private var palette = ClipFlowPalette.resolve(for: .light)
    private var enabled = true
    private var colorScheme: ColorScheme = .light
    private var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)?
    private var onInspectItem: (ClipboardItem) -> Void = { _ in }
    private var rows: [UUID: LibraryInteractiveHostingView] = [:]
    private var rendered: [UUID: ClipboardItem] = [:]
    private var renderedReveal: [UUID: Bool] = [:]
    private var materializing = false

    override var isFlipped: Bool { true }

    func apply(items: [ClipboardItem], revealedItemIDs: Set<UUID>, store: ClipFlowStore,
        palette: ClipFlowPalette, enabled: Bool, colorScheme: ColorScheme,
        onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)?,
        onInspectItem: @escaping (ClipboardItem) -> Void) {
        self.items = items
        self.revealedItemIDs = revealedItemIDs
        self.store = store
        self.palette = palette
        self.enabled = enabled
        self.colorScheme = colorScheme
        self.onInspectFrom = onInspectFrom
        self.onInspectItem = onInspectItem
        let live = Set(items.map(\.id))
        for id in Array(rows.keys) where !live.contains(id) {
            rows[id]?.removeFromSuperview()
            rows[id] = nil
            rendered[id] = nil
            renderedReveal[id] = nil
        }
        for row in rows.values { row.interactionEnabled = enabled }
        materialize()
    }

    override func layout() {
        super.layout()
        materialize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        materialize()
    }

    func materialize() {
        guard !materializing, let store, let scroll = enclosingScrollView else { return }
        materializing = true
        defer { materializing = false }
        let origin = scroll.contentView.bounds.origin
        let clip = scroll.contentView.bounds
        let width = max(clip.width, bounds.width, 1)
        let placed = HistoryRowGeometry.place(items: items, width: width)
        let height = max(placed.height, clip.height)
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
        if scroll.contentView.bounds.origin != origin {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let visible = scroll.contentView.bounds
        for (item, rowFrame) in zip(items, placed.frames) {
            let revealed = store.isRevealed(item)
            if let row = rows[item.id] {
                if row.frame != rowFrame { row.frame = rowFrame }
                bind(row, item: item, revealed: revealed, store: store)
            } else if rowFrame.intersects(visible) {
                let row = LibraryInteractiveHostingView()
                row.frame = rowFrame
                rows[item.id] = row
                addSubview(row)
                bind(row, item: item, revealed: revealed, store: store)
            }
        }
    }

    private func bind(_ row: LibraryInteractiveHostingView, item: ClipboardItem, revealed: Bool,
        store: ClipFlowStore) {
        row.interactionEnabled = enabled
        guard rendered[item.id] != item || renderedReveal[item.id] != revealed else { return }
        rendered[item.id] = item
        renderedReveal[item.id] = revealed
        let id = item.id
        row.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        row.lockedHeight = LibraryCardLayout.height(for: item.kind)
        row.pinActionTitle = item.pinned ? "取消置顶" : "置顶"
        let snippet = store.displaySnippet(for: item)
        let summary = ClipboardCardSummary.plainFirstLine(of: store.displayFullText(for: item))
        let spoken = summary.isEmpty ? snippet : summary
        row.accessibilitySummary = "\(item.sourceApp)，\(item.kind.label)，\(spoken)，\(item.timeLabel)"
        let inspect = InspectorSourceAnchor.callback(for: row,
            fallback: { [weak self] in self?.inspect(id) },
            anchored: { [weak self] source in self?.inspect(id, source: source) })
        row.update(
            rootView: AnyView(ClipboardCard(item: item, displayedSnippet: snippet, palette: palette,
                store: store, hover: row.hover).environment(\.colorScheme, colorScheme)),
            selectionView: AnyView(LibrarySelectionChrome(itemID: id, selection: store.historySelection,
                tint: item.kind.tint, palette: palette).environment(\.colorScheme, colorScheme)),
            onSelect: { [weak self] in self?.select(id) },
            onInspect: inspect,
            onAction: { [weak self] action in self?.perform(action, id: id) },
            menuProvider: { [weak self] in self?.menu(for: id, inspect: inspect) ?? [] }
        )
    }

    private func select(_ id: UUID) {
        guard let store, let item = store.item(withID: id) else { return }
        store.select(item)
    }

    private func inspect(_ id: UUID, source: InspectorSourceAnchor? = nil) {
        guard let item = items.first(where: { $0.id == id }) ?? store?.item(withID: id) else { return }
        if let source, let onInspectFrom { onInspectFrom(item, source) }
        else { onInspectItem(item) }
    }

    private func perform(_ action: LibraryCardAction, id: UUID) {
        guard let store, let item = store.item(withID: id) else { return }
        switch action {
        case .copy: ClipFlowRuntime.shared.copyToClipboard(item)
        case .pin: store.togglePin(id)
        case .delete: store.delete(id)
        }
    }

    private func menu(for id: UUID, inspect: @escaping () -> Void) -> [ClipboardRowMenuEntry] {
        guard let store, let item = store.item(withID: id) else { return [] }
        return ClipboardRowMenu.entries(for: item, store: store, leading: [
            .action(title: "查看详情", symbol: "arrow.up.left.and.arrow.down.right", handler: inspect),
            .action(title: "粘贴", symbol: "arrow.down.doc") { [weak store] in
                guard let latest = store?.item(withID: id) else { return }
                ClipFlowRuntime.shared.paste(latest)
            }
        ])
    }
}
