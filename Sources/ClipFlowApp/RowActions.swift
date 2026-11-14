import AppKit
import SwiftUI

/// One entry of a clipboard row's context menu.
enum ClipboardRowMenuEntry {
    case action(title: String, symbol: String, handler: () -> Void)
    case separator
}

@MainActor
enum ClipboardRowMenu {
    static func make(_ entries: [ClipboardRowMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, symbol, handler):
                menu.addItem(ClipboardRowMenuItem(title: title, symbol: symbol, handler: handler))
            }
        }
        return menu
    }

    /// Shared by the history list and the quick-paste panel. `leading` carries
    /// the surface-specific primary entries (details, paste).
    static func entries(for item: ClipboardItem, store: ClipFlowStore,
                        leading: [ClipboardRowMenuEntry]) -> [ClipboardRowMenuEntry] {
        let id = item.id
        var entries = leading
        entries.append(.action(title: "复制", symbol: "doc.on.doc") { [weak store] in
            guard let current = store?.item(withID: id) else { return }
            ClipFlowRuntime.shared.copyToClipboard(current)
        })
        entries.append(.action(title: item.pinned ? "取消置顶" : "置顶",
            symbol: item.pinned ? "pin.slash" : "pin") { [weak store] in store?.togglePin(id) })
        if item.privacy != .standard {
            entries.append(.action(title: store.isRevealed(item) ? "隐藏内容" : "显示内容",
                symbol: store.isRevealed(item) ? "eye.slash" : "eye") { [weak store] in store?.toggleReveal(id) })
        }
        if let url = item.primaryURL {
            entries.append(.action(title: "访问链接", symbol: "safari") { NSWorkspace.shared.open(url) })
        }
        entries.append(.separator)
        entries.append(.action(title: "删除条目", symbol: "trash") { [weak store] in store?.delete(id) })
        return entries
    }
}

private final class ClipboardRowMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(ClipboardRowMenuItem.performHandler), keyEquivalent: "")
        self.handler = handler
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @objc private func performHandler() { handler?() }
}

/// Hover is published separately so it repaints only the action bar, never the card.
@MainActor
final class RowHoverState: ObservableObject {
    @Published var isHovered = false
    @Published private(set) var confirmedAction: LibraryCardAction?
    private var confirmationToken = 0

    /// Briefly swaps an action's icon for a checkmark.
    func confirm(_ action: LibraryCardAction) {
        confirmationToken += 1
        let token = confirmationToken
        confirmedAction = action
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.confirmationToken == token else { return }
            self.confirmedAction = nil
        }
    }
}

enum LibraryCardAction: Int, CaseIterable {
    case copy, pin, delete

    /// Delete stays in the context menu and in VoiceOver actions.
    static let hoverActions: [LibraryCardAction] = [.copy, .pin]
}

/// The action bar is drawn by SwiftUI but clicked through the row's native
/// event handling, so both sides share this geometry.
enum LibraryCardActionLayout {
    static let buttonSize = CGSize(width: 28, height: 28)
    static let spacing: CGFloat = ClipFlowLayout.space4
    static let padding: CGFloat = ClipFlowLayout.space4
    static let trailingInset: CGFloat = ClipFlowLayout.space8
    static let topInset: CGFloat = ClipFlowLayout.space4

    static var barSize: CGSize {
        let count = CGFloat(LibraryCardAction.hoverActions.count)
        return CGSize(width: count * buttonSize.width + (count - 1) * spacing + 2 * padding,
            height: buttonSize.height + 2 * padding)
    }

    /// `point` is measured from the row's top-left corner.
    static func action(at point: CGPoint, rowWidth: CGFloat) -> LibraryCardAction? {
        let bar = CGRect(x: rowWidth - trailingInset - barSize.width, y: topInset,
            width: barSize.width, height: barSize.height)
        guard bar.minX >= 0, bar.contains(point) else { return nil }
        let x = point.x - bar.minX - padding
        guard x >= 0 else { return LibraryCardAction.hoverActions.first }
        let index = min(LibraryCardAction.hoverActions.count - 1, Int(x / (buttonSize.width + spacing)))
        return LibraryCardAction.hoverActions[index]
    }
}

enum HistoryPasteRouting {
    /// Same index rule as quick paste: ⌘1 is the first visible row.
    static func item(at index: Int, in items: [ClipboardItem]) -> ClipboardItem? {
        items.indices.contains(index) ? items[index] : nil
    }
}

struct LibraryCardActionBar: View {
    @ObservedObject var hover: RowHoverState
    let pinned: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: LibraryCardActionLayout.spacing) {
            ForEach(LibraryCardAction.hoverActions, id: \.self) { action in
                Image(systemName: hover.confirmedAction == action ? "checkmark" : symbol(for: action))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(action == .delete ? ClipCategory.protected.tint : Color.primary.opacity(0.75))
                    .frame(width: LibraryCardActionLayout.buttonSize.width,
                        height: LibraryCardActionLayout.buttonSize.height)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
                    .help(title(for: action))
            }
        }
        .padding(LibraryCardActionLayout.padding)
        .background(colorScheme == .dark ? Color(red: 0.22, green: 0.24, blue: 0.29) : Color.white,
            in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.trailing, LibraryCardActionLayout.trailingInset)
        .padding(.top, LibraryCardActionLayout.topInset)
        .opacity(hover.isHovered ? 1 : 0)
        .animation(reduceMotion ? nil : ClipFlowMotion.fade, value: hover.isHovered)
        .accessibilityHidden(true)
    }

    private func symbol(for action: LibraryCardAction) -> String {
        switch action {
        case .copy: "doc.on.doc"
        case .pin: pinned ? "pin.slash" : "pin"
        case .delete: "trash"
        }
    }

    private func title(for action: LibraryCardAction) -> String {
        switch action {
        case .copy: "复制"
        case .pin: pinned ? "取消置顶" : "置顶"
        case .delete: "删除条目"
        }
    }
}

enum ListKeyCommand: Equatable {
    case moveUp, moveDown, activate, toggleDetails
    case pasteIndex(Int)

    /// - Parameters:
    ///   - isEditingText: a text field owns keyboard focus.
    ///   - isComposing: an input method has uncommitted text; every key belongs to it.
    ///   - queryIsEmpty: Space only reaches the list while the search field is empty.
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        isEditingText: Bool, isComposing: Bool, queryIsEmpty: Bool) -> ListKeyCommand? {
        guard !isComposing else { return nil }
        let active = modifiers.intersection([.command, .option, .control, .shift])
        if active == .command, let index = digitKeyCodes.firstIndex(of: keyCode) {
            return .pasteIndex(index)
        }
        guard active.isEmpty else { return nil }
        switch keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 36, 76: return .activate
        case 49: return !isEditingText || queryIsEmpty ? .toggleDetails : nil
        default: return nil
        }
    }

    /// ANSI key codes for 1...9, independent of the active input source.
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}

/// Window-scoped key handling that still works while the search field has focus.
struct ListKeyCommandMonitor: NSViewRepresentable {
    var queryIsEmpty = true
    let onCommand: (ListKeyCommand) -> Bool
    @Environment(\.isEnabled) private var scopeEnabled

    func makeNSView(context: Context) -> ListKeyCommandView {
        let view = ListKeyCommandView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ListKeyCommandView, context: Context) {
        view.queryIsEmpty = queryIsEmpty
        view.onCommand = onCommand
        view.scopeEnabled = scopeEnabled
    }
    static func dismantleNSView(_ view: ListKeyCommandView, coordinator: ()) { view.stop() }
}

final class ListKeyCommandView: NSView {
    var queryIsEmpty = true
    var onCommand: (ListKeyCommand) -> Bool = { _ in false }
    var scopeEnabled = true
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard scopeEnabled, !isHiddenOrHasHiddenAncestor, event.type == .keyDown,
              let window, window.isVisible, event.windowNumber == window.windowNumber else { return false }
        let editor = window.firstResponder as? NSTextView
        guard let command = ListKeyCommand.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
            isEditingText: editor != nil, isComposing: editor?.hasMarkedText() == true,
            queryIsEmpty: queryIsEmpty) else { return false }
        // With Full Keyboard Access, Space activates the focused control.
        if command == .toggleDetails, editor == nil, window.firstResponder !== window,
           NSApp.isFullKeyboardAccessEnabled { return false }
        return onCommand(command)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
