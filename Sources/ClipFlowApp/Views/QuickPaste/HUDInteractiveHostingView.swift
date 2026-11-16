import AppKit
import SwiftUI

final class HUDInteractiveHostingView: ClipboardRowHitView {
    private(set) var contentRevision = 0
    var representedItemID: UUID? { itemID }
    private let selectionHostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private static weak var lastClickedRow: HUDInteractiveHostingView?
    private var previousClick: NSEvent?
    private var itemID: UUID?
    private var onSelect: () -> Void = {}
    private var onPaste: () -> Void = {}
    private var onPastePlain: () -> Void = {}
    private var onInspect: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

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
        itemID: UUID? = nil,
        rootView: AnyView,
        selectionView: AnyView? = nil,
        onSelect: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onPastePlain: @escaping () -> Void = {},
        onInspect: @escaping () -> Void,
        menuProvider: (() -> [ClipboardRowMenuEntry])? = nil
    ) {
        if self.itemID != itemID {
            resetClickSequence()
            self.itemID = itemID
        }
        contentRevision += 1
        hostingView.rootView = rootView
        if let selectionView { selectionHostingView.rootView = selectionView }
        self.onSelect = onSelect
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onInspect = onInspect
        self.menuProvider = menuProvider ?? { [] }
    }

    /// Opens the detail drawer from this row (middle click, menu, keyboard).
    override func openDetails() {
        guard interactionEnabled else { return }
        resetClickSequence()
        onInspect()
    }

    override func mouseDown(with event: NSEvent) {
        if redirectLeftClickIfNeeded(event) {
            resetClickSequence()
            return
        }
        // AppKit's click count belongs to the event sequence, not this item.
        // Require a preceding click on this same row before allowing paste.
        let isDoubleClick = Self.lastClickedRow === self && previousClick.map {
            event.clickCount > 1 && event.clickCount == $0.clickCount + 1
                && event.timestamp >= $0.timestamp
                && event.timestamp - $0.timestamp <= NSEvent.doubleClickInterval
                && event.windowNumber == $0.windowNumber
                && hypot(event.locationInWindow.x - $0.locationInWindow.x,
                         event.locationInWindow.y - $0.locationInWindow.y) <= 4
        } == true
        if isDoubleClick {
            resetClickSequence()
            if PlainTextPaste.isPlainTextClick(event.modifierFlags) {
                onPastePlain()
            } else {
                onPaste()
            }
        } else {
            Self.lastClickedRow = self
            previousClick = event
            onSelect()
        }
    }

    override func rowInteractionWasDisabled() { resetClickSequence() }

    private func resetClickSequence() {
        previousClick = nil
        if Self.lastClickedRow === self { Self.lastClickedRow = nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetClickSequence()
    }

    override func scrollWheel(with event: NSEvent) {
        resetClickSequence()
        super.scrollWheel(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        resetClickSequence()
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionEnabled else { return nil }
        resetClickSequence()
        return contextMenu()
    }
}
