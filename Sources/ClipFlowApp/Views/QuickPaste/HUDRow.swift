import SwiftUI

struct HUDRow: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ClipFlowPalette { .resolve(for: colorScheme) }
    let item: ClipboardItem
    @ObservedObject var store: ClipFlowStore
    /// Position among the first nine rows, pasted directly with ⌘1…⌘9.
    var shortcutIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: item.isImage || item.kind == .code || showsTableGrid ? 6 : 4) {
            HStack(spacing: 5) {
                Image(systemName: iconName).foregroundStyle(item.kind.labelColor(for: colorScheme))
                Text(SpreadsheetPreview.typeLabel(for: item)).foregroundStyle(item.kind.labelColor(for: colorScheme)).fixedSize()
                Text(item.sourceApp).lineLimit(1)
                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.pinned.tint) }
                if item.isSensitive { Image(systemName: "lock.fill").foregroundStyle(item.privacy.color) }
                Spacer(minLength: 4)
                Text(item.timeLabel).lineLimit(1).fixedSize()
                if let shortcutIndex, shortcutIndex < 9 {
                    Text("⌘\(shortcutIndex + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 4).frame(height: 14)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            .frame(height: 14)

            if item.isImage {
                imageContent
            } else if let grid = tableGrid, showsTableGrid {
                SpreadsheetGridView(grid: grid, style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
                    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
            } else if item.kind == .code {
                Text(String(store.displayFullText(for: item).prefix(1000)))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(7)
                    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
            } else {
                Text(store.displaySnippet(for: item))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: QuickPasteCardLayout.height(for: item), alignment: .top)

    }

    @ViewBuilder private var imageContent: some View {
        let shape = LibraryImageShape.resolve(width: item.imageWidth, height: item.imageHeight)
        if shape == .landscape {
            VStack(alignment: .leading, spacing: 4) {
                ClipThumbnailView(store: store, item: item, height: LibraryImageThumbnail.height, cornerRadius: ClipFlowLayout.controlRadius,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                Text(item.imageDimensionText ?? "图片").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ClipThumbnailView(store: store, item: item, height: LibraryImageThumbnail.height, cornerRadius: ClipFlowLayout.controlRadius,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    .frame(width: shape == .portrait ? 66 : 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(shape == .portrait ? "竖向图片" : "方形图片")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tint: Color {
        item.kind.tint
    }

    private var iconName: String { SpreadsheetPreview.symbolName(for: item) }

    private var tableGrid: SpreadsheetPreviewGrid? {
        guard store.isRevealed(item) else { return nil }
        return SpreadsheetPreview.grid(for: item)
    }

    private var showsTableGrid: Bool {
        guard let tableGrid else { return false }
        return tableGrid.rows.count > 1 || tableGrid.columnCount > 1
    }
}
