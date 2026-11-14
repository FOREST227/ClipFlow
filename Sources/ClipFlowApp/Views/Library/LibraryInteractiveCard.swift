import AppKit
import SwiftUI

struct LibraryInteractiveCard: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let item: ClipboardItem
    let store: ClipFlowStore
    let displayedSnippet: String
    let palette: ClipFlowPalette
    var onInspectFrom: ((InspectorSourceAnchor) -> Void)? = nil
    let onSelect: () -> Void
    let onInspect: () -> Void

    func makeNSView(context: Context) -> LibraryInteractiveHostingView {
        let view = LibraryInteractiveHostingView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: LibraryInteractiveHostingView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: LibraryInteractiveHostingView) {
        let id = item.id
        view.interactionEnabled = isEnabled
        view.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        let inspect = InspectorSourceAnchor.callback(for: view, fallback: onInspect, anchored: onInspectFrom)
        let summary = ClipboardCardSummary.plainFirstLine(of: store.displayFullText(for: item))
        let spoken = summary.isEmpty ? displayedSnippet : summary
        view.accessibilitySummary = "\(item.sourceApp)，\(item.kind.label)，\(spoken)，\(item.timeLabel)"
        view.pinActionTitle = item.pinned ? "取消置顶" : "置顶"
        view.update(
            rootView: AnyView(
                ClipboardCard(
                    item: item,
                    displayedSnippet: displayedSnippet,
                    palette: palette,
                    store: store,
                    hover: view.hover
                )
            ),
            selectionView: AnyView(LibrarySelectionChrome(itemID: id,
                selection: store.historySelection, tint: item.kind.tint, palette: palette)),
            onSelect: onSelect,
            onInspect: inspect,
            onAction: { [weak store] action in
                guard let store, let current = store.item(withID: id) else { return }
                switch action {
                case .copy: ClipFlowRuntime.shared.copyToClipboard(current)
                case .pin: store.togglePin(id)
                case .delete: store.delete(id)
                }
            },
            menuProvider: { [weak store] in
                guard let store, let current = store.item(withID: id) else { return [] }
                return ClipboardRowMenu.entries(for: current, store: store, leading: [
                    .action(title: "查看详情", symbol: "arrow.up.left.and.arrow.down.right", handler: inspect),
                    .action(title: "粘贴", symbol: "arrow.down.doc") { [weak store] in
                        guard let latest = store?.item(withID: id) else { return }
                        ClipFlowRuntime.shared.paste(latest)
                    }
                ])
            }
        )
    }
}

final class LibraryInteractiveHostingView: ClipboardRowHitView {
    private(set) var contentRevision = 0
    var accessibilitySummary = ""
    var pinActionTitle = "置顶"
    let hover = RowHoverState()
    private let selectionHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var onSelect: () -> Void = {}
    private var onInspect: () -> Void = {}
    private var onAction: ((LibraryCardAction) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private static weak var lastClickedRow: LibraryInteractiveHostingView?
    private static var lastClickedIdentifier: NSUserInterfaceItemIdentifier?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        selectionHostingView.translatesAutoresizingMaskIntoConstraints = false
        selectionHostingView.wantsLayer = true
        selectionHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(selectionHostingView)
        NSLayoutConstraint.activate([
            selectionHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionHostingView.topAnchor.constraint(equalTo: topAnchor),
            selectionHostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: AnyView,
        selectionView: AnyView? = nil,
        onSelect: @escaping () -> Void,
        onInspect: @escaping () -> Void,
        onAction: ((LibraryCardAction) -> Void)? = nil,
        menuProvider: (() -> [ClipboardRowMenuEntry])? = nil
    ) {
        contentRevision += 1
        hostingView.rootView = rootView
        if let selectionView { selectionHostingView.rootView = selectionView }
        self.onSelect = onSelect
        self.onInspect = onInspect
        self.onAction = onAction
        self.menuProvider = menuProvider ?? { [] }
        if onAction == nil { setHovered(false) }
        refreshAccessibilityActions()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { accessibilitySummary }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        interactionEnabled ? rowAccessibilityActions : nil
    }

    private var rowAccessibilityActions: [NSAccessibilityCustomAction] = []

    private func refreshAccessibilityActions() {
        guard onAction != nil else {
            rowAccessibilityActions = []
            return
        }
        rowAccessibilityActions = [
            NSAccessibilityCustomAction(name: "复制") { [weak self] in
                self?.onAction?(.copy)
                return true
            },
            NSAccessibilityCustomAction(name: pinActionTitle) { [weak self] in
                self?.onAction?(.pin)
                return true
            },
            NSAccessibilityCustomAction(name: "删除") { [weak self] in
                self?.onAction?(.delete)
                return true
            }
        ]
    }

    /// Opens the detail drawer from this row (double click, middle click, menu, keyboard).
    override func openDetails() {
        guard interactionEnabled else { return }
        onInspect()
    }

    override func mouseDown(with event: NSEvent) {
        guard !redirectLeftClickIfNeeded(event) else { return }
        if let action = hoverAction(for: event) {
            Self.lastClickedRow = nil
            if action == .copy { hover.confirm(action) }
            // Pinning and deleting move rows under a resting pointer.
            else { setHovered(false) }
            onAction?(action)
            return
        }
        // AppKit's click count belongs to the event sequence, not this item:
        // both clicks must land on the same row showing the same item.
        let isDoubleClick = event.clickCount == 2 && Self.lastClickedRow === self
            && Self.lastClickedIdentifier == identifier
        Self.lastClickedRow = isDoubleClick ? nil : self
        Self.lastClickedIdentifier = identifier
        onSelect()
        if isDoubleClick { openDetails() }
    }

    private func hoverAction(for event: NSEvent) -> LibraryCardAction? {
        guard interactionEnabled, onAction != nil, hover.isHovered,
              let window, event.windowNumber == window.windowNumber else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return LibraryCardActionLayout.action(
            at: CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y),
            rowWidth: bounds.width)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        Self.lastClickedRow = nil
        guard let menu = contextMenu() else { return }
        onSelect()
        Self.presentContextMenu(menu, event, self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        if event.buttonNumber == 2 {
            openDetails()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseMoved(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func rowInteractionWasDisabled() { setHovered(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    // Tracking areas do not follow content scrolled under a resting pointer.
    override func scrollWheel(with event: NSEvent) {
        setHovered(false)
        super.scrollWheel(with: event)
    }

    private func setHovered(_ hovered: Bool) {
        let next = hovered && interactionEnabled && onAction != nil
        if hover.isHovered != next { hover.isHovered = next }
    }
}

