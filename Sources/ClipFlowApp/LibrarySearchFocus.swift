import AppKit
import SwiftUI

/// Library search focus shared by the Edit menu, the history field, and Escape.
@MainActor
enum LibrarySearchFocus {
    static let fieldIdentifier = "clipflow.library-search"
    static let menuTitle = "查找"
    static let menuKeyEquivalent = "f"

    /// Escape clears a committed query before the inspector or the field editor sees it.
    /// Marked text still belongs to the input method.
    static func escapeClearsQuery(query: String, fieldFocused: Bool, isComposing: Bool) -> Bool {
        fieldFocused && !isComposing && !query.isEmpty
    }

    static func menuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: menuTitle, action: action, keyEquivalent: menuKeyEquivalent)
        item.keyEquivalentModifierMask = .command
        item.target = target
        return item
    }

    static func mark(_ field: NSTextField) {
        let identifier = NSUserInterfaceItemIdentifier(fieldIdentifier)
        if field.identifier != identifier { field.identifier = identifier }
    }

    /// The text field nearest the search row. Walking the whole window would also see Settings.
    static func nearestTextField(from anchor: NSView) -> NSTextField? {
        guard anchor.window != nil, anchor.bounds.width > 1, anchor.bounds.height > 1 else { return nil }
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        var node = anchor.superview
        var depth = 0
        var closest: (field: NSTextField, distance: CGFloat)?
        while let current = node, depth < 8 {
            for field in textFields(in: current) {
                let frame = field.convert(field.bounds, to: nil)
                guard frame.width > 1, frame.height > 1 else { continue }
                let distance = hypot(frame.midX - anchorFrame.midX, frame.midY - anchorFrame.midY)
                if closest == nil || distance < closest!.distance {
                    closest = (field, distance)
                }
            }
            if let closest, closest.distance <= max(anchorFrame.height, 24) + 8 {
                return closest.field
            }
            node = current.superview
            depth += 1
        }
        guard let closest, closest.distance < 120 else { return nil }
        return closest.field
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField { fields.append(field) }
        for subview in view.subviews { fields.append(contentsOf: textFields(in: subview)) }
        return fields
    }

    static func markedSearchField(in window: NSWindow?) -> NSTextField? {
        guard let content = window?.contentView else { return nil }
        return textFields(in: content).first { $0.identifier?.rawValue == fieldIdentifier }
    }

    static func searchFieldIsFirstResponder(in window: NSWindow?) -> Bool {
        guard let window, let field = markedSearchField(in: window) else { return false }
        if window.firstResponder === field { return true }
        if let editor = field.currentEditor(), window.firstResponder === editor { return true }
        return false
    }

    static func isComposing(in window: NSWindow?) -> Bool {
        let editor = (window?.firstResponder as? NSTextView)
            ?? (markedSearchField(in: window)?.currentEditor() as? NSTextView)
        return editor?.hasMarkedText() == true
    }
}

/// Increment `requestID` to move first responder to the library search field.
@MainActor
final class LibrarySearchFocusModel: ObservableObject {
    @Published private(set) var requestID = 0
    private let acceptsRequests: Bool

    init(acceptsRequests: Bool = true) {
        self.acceptsRequests = acceptsRequests
    }

    /// Views outside the library window observe this and never take focus.
    static let inactive = LibrarySearchFocusModel(acceptsRequests: false)

    func request() {
        guard acceptsRequests else { return }
        requestID &+= 1
    }
}

private enum LibrarySearchFocusKey: EnvironmentKey {
    static let defaultValue: LibrarySearchFocusModel? = nil
}

extension EnvironmentValues {
    var librarySearchFocus: LibrarySearchFocusModel? {
        get { self[LibrarySearchFocusKey.self] }
        set { self[LibrarySearchFocusKey.self] = newValue }
    }
}

/// Tags the search field and claims focus after the window is key.
struct LibrarySearchFieldAnchor: NSViewRepresentable {
    var requestID: Int
    var canClaim: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LibrarySearchFieldAnchorView {
        let view = LibrarySearchFieldAnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: LibrarySearchFieldAnchorView, context: Context) {
        let coordinator = context.coordinator
        if canClaim && !coordinator.canClaim { coordinator.attempts = 0 }
        if coordinator.requestID != requestID { coordinator.attempts = 0 }
        coordinator.requestID = requestID
        coordinator.canClaim = canClaim
        view.coordinator = coordinator
        let pending = requestID != 0 && coordinator.appliedID != requestID
        if pending || !coordinator.didMarkField { view.scheduleClaim() }
    }

    final class Coordinator {
        var requestID = 0
        var appliedID = 0
        var canClaim = false
        var didMarkField = false
        var attempts = 0
    }
}

final class LibrarySearchFieldAnchorView: NSView {
    var coordinator: LibrarySearchFieldAnchor.Coordinator?
    private var claimQueued = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleClaim()
    }

    override func layout() {
        super.layout()
        guard let coordinator, coordinator.requestID != 0, coordinator.appliedID != coordinator.requestID else { return }
        scheduleClaim()
    }

    func scheduleClaim() {
        guard !claimQueued else { return }
        claimQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.claimQueued = false
                self?.claim()
            }
        }
    }

    private func claim() {
        guard let coordinator else { return }
        if let field = LibrarySearchFocus.nearestTextField(from: self) {
            LibrarySearchFocus.mark(field)
            coordinator.didMarkField = true
        }
        guard coordinator.requestID != 0, coordinator.appliedID != coordinator.requestID else { return }
        guard coordinator.canClaim else { return }
        guard let window, window.isKeyWindow, window.isVisible else {
            retry(coordinator)
            return
        }
        guard let field = LibrarySearchFocus.markedSearchField(in: window) ?? LibrarySearchFocus.nearestTextField(from: self) else {
            retry(coordinator)
            return
        }
        LibrarySearchFocus.mark(field)
        guard !field.isHiddenOrHasHiddenAncestor, field.bounds.width > 1, field.bounds.height > 1 else {
            retry(coordinator)
            return
        }
        let alreadyEditing = window.firstResponder === field || field.currentEditor() === window.firstResponder
        guard alreadyEditing || window.makeFirstResponder(field) else {
            retry(coordinator)
            return
        }
        coordinator.appliedID = coordinator.requestID
        coordinator.attempts = 0
    }

    private func retry(_ coordinator: LibrarySearchFieldAnchor.Coordinator) {
        guard coordinator.attempts < 40 else { return }
        coordinator.attempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.claim() }
        }
    }
}
