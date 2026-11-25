import SwiftUI

struct HUDInspectorOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    var sourceRectInWindow: CGRect? = nil
    var motion: InspectorMotionProgress? = nil
    let onClose: () -> Void
    let onPaste: () -> Void
    var onPastePlain: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = max(280, proxy.size.width - 12)
            ZStack {
                LibraryInspectorOverlay(item: item, store: store,
                    palette: .resolve(for: colorScheme), maxHeight: max(280, proxy.size.height - 12),
                    contentWidth: cardWidth, onPasteAction: onPaste, onPastePlainAction: onPastePlain,
                    sourceRectInWindow: sourceRectInWindow, motion: motion, onClose: onClose)
                    .frame(width: cardWidth)
                    .padding(6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
