import AppKit
import SwiftUI

struct HUDInteractiveRow: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let item: ClipboardItem
    let store: ClipFlowStore
    let selection: HistorySelection
    var onInspectFrom: ((InspectorSourceAnchor) -> Void)? = nil
    let onSelect: () -> Void
    let onPaste: () -> Void
    var onPastePlain: () -> Void = {}
    let onInspect: () -> Void

    func makeNSView(context: Context) -> HUDInteractiveHostingView {
        let view = HUDInteractiveHostingView()
        view.interactionEnabled = isEnabled
        view.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        view.update(
            itemID: item.id,
            rootView: AnyView(
                HUDRow(
                    item: item,
                    store: store
                )
            ),
            selectionView: AnyView(HUDSelectionChrome(itemID: item.id, selection: selection,
                tint: item.kind.tint)),
            onSelect: onSelect,
            onPaste: onPaste,
            onPastePlain: onPastePlain,
            onInspect: InspectorSourceAnchor.callback(for: view, fallback: onInspect, anchored: onInspectFrom)
        )
        return view
    }

    func updateNSView(_ nsView: HUDInteractiveHostingView, context: Context) {
        nsView.interactionEnabled = isEnabled
        nsView.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        nsView.update(
            itemID: item.id,
            rootView: AnyView(
                HUDRow(
                    item: item,
                    store: store
                )
            ),
            selectionView: AnyView(HUDSelectionChrome(itemID: item.id, selection: selection,
                tint: item.kind.tint)),
            onSelect: onSelect,
            onPaste: onPaste,
            onPastePlain: onPastePlain,
            onInspect: InspectorSourceAnchor.callback(for: nsView, fallback: onInspect, anchored: onInspectFrom)
        )
    }
}
