import AppKit
import SwiftUI

struct ClipThumbnailView: View {
    @ObservedObject var store: ClipFlowStore
    let item: ClipboardItem
    let height: CGFloat
    var cornerRadius: CGFloat = 20
    var showsDimensionLabel: Bool = true
    var contentMode: ContentMode = .fill
    var insetPreview: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.10))

            previewContent

            if showsDimensionLabel, let dimension = item.imageDimensionText {
                Text(dimension)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var previewContent: some View {
        if !store.isRevealed(item) {
            previewPlaceholder(
                title: "图片预览已隐藏",
                icon: "lock.fill",
                tint: item.privacy.color
            )
        } else if let image = store.imagePreview(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(insetPreview ? 8 : 0)
        } else {
            previewPlaceholder(
                title: "图片不可用",
                icon: "photo.badge.exclamationmark",
                tint: ClipCategory.protected.tint
            )
        }
    }

    private func previewPlaceholder(title: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.16), Color.black.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

/// A separate hosting surface keeps highlight animation out of image/text layout.
struct LibrarySelectionChrome: View {
    let itemID: ClipboardItem.ID
    let selection: HistorySelection
    let tint: Color
    let palette: ClipFlowPalette
    @ViewState private var isSelected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
            .fill(isSelected ? palette.softFill : palette.rowFill)
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.22 : 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.65) : palette.rowBorder,
                    lineWidth: isSelected ? 1.5 : 1))
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: 3)
                    .opacity(isSelected ? 1 : 0)
                    .padding(.vertical, 18).padding(.leading, 9)
            }
            .animation(reduceMotion ? nil : ClipFlowMotion.rowSelection, value: isSelected)
            .onReceive(selection.$itemID.map { $0 == itemID }.removeDuplicates()) {
                if isSelected != $0 { isSelected = $0 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let displayedSnippet: String
    let palette: ClipFlowPalette
    @ObservedObject var store: ClipFlowStore
    var hover: RowHoverState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: item.kind == .image || item.kind == .code ? 6 : 3) {
            metadata
            if item.isImage {
                imageContent
            } else if item.kind == .code {
                Text(String(store.displayFullText(for: item).prefix(1200)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(5).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(itemTint.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                tags
            } else {
                Text(displayedSnippet)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                tags
            }
        }
        // Reserve the selection rail's gutter even when not selected.
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: LibraryCardLayout.height(for: item.kind), alignment: .top)
        .overlay(alignment: .topTrailing) {
            if let hover { LibraryCardActionBar(hover: hover, pinned: item.pinned) }
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(item.sourceApp).lineLimit(1)
            Text(item.kind.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(itemTint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(itemTint.opacity(0.1), in: Capsule())
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.pinned.tint) }
            Spacer(minLength: 4)
            Text(item.timeLabel).lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .frame(height: 16)
    }

    @ViewBuilder private var imageContent: some View {
        let shape = LibraryImageShape.resolve(width: item.imageWidth, height: item.imageHeight)
        if shape == .landscape {
            ClipThumbnailView(store: store, item: item, height: 88, cornerRadius: 8,
                showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
            HStack {
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text("横向").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                ClipThumbnailView(store: store, item: item, height: 104, cornerRadius: 8,
                    showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                    .frame(width: shape == .portrait ? 76 : 104)
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    tags
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tags: some View {
        HStack(spacing: 6) {
            Text(item.labels.filter { $0 != item.sourceApp }.prefix(2).joined(separator: " · "))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isSensitive {
                Label(item.privacy.label, systemImage: "lock.fill")
                    .foregroundStyle(item.privacy.color).lineLimit(1)
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .frame(height: 12)
    }

    private var itemTint: Color {
        item.kind.tint
    }
}

