import SwiftUI

struct QuickPasteHistoryList: View {
    let clips: [ClipboardItem]
    @ObservedObject var store: ClipFlowStore
    let selection: HistorySelection
    let listProxy: QuickPasteListProxy
    let inspector: InspectorPresentation
    let reduceMotion: Bool
    let onPaste: (ClipboardItem) -> Void
    let onPastePlain: (ClipboardItem) -> Void

    var body: some View {
        QuickPasteNativeList(items: clips, store: store, selection: selection, proxy: listProxy,
            isBlocked: { [weak inspector] in inspector?.blocksBackground != false },
            onSelect: { item in selection.itemID = item.id },
            onPaste: onPaste,
            onPastePlain: onPastePlain,
            onInspect: { item in
                selection.itemID = item.id
                if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
                    inspector.dismiss(reduceMotion: reduceMotion)
                } else {
                    inspector.open(itemID: item.id, reduceMotion: reduceMotion)
                }
            },
            onInspectFrom: { item, source in
                selection.itemID = item.id
                if inspector.snapshot.itemID == item.id && inspector.snapshot.phase != .closing {
                    inspector.dismiss(reduceMotion: reduceMotion)
                } else {
                    inspector.open(itemID: item.id, reduceMotion: reduceMotion, source: source)
                }
            })
        .frame(height: QuickPasteCardLayout.viewportHeight)
    }
}
