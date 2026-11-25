import AppKit
import SwiftUI

struct ClipThumbnailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipFlowStore
    let item: ClipboardItem
    let height: CGFloat
    var cornerRadius: CGFloat = ClipFlowLayout.overlayRadius
    var expandsToContainer: Bool = true
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
        .frame(maxWidth: expandsToContainer ? .infinity : nil)
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
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
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
        let accent = FolioTheme.primaryAccent(for: colorScheme)
        RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
            .fill(isSelected ? palette.selectedRowFill : palette.rowFill)
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.70) : palette.rowBorder,
                    lineWidth: isSelected ? 1.5 : 1))
            .overlay(alignment: .leading) {
                Capsule().fill(accent).frame(width: 3)
                    .opacity(isSelected ? 1 : 0)
                    .padding(.vertical, 12).padding(.leading, 9)
            }
            .animation(reduceMotion ? nil : ClipFlowMotion.rowSelection, value: isSelected)
            .onReceive(selection.$itemID.map { $0 == itemID }.removeDuplicates()) {
                if isSelected != $0 { isSelected = $0 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum ClipboardCardSummary {
    /// First readable line, with Markdown markers removed so a heading is not shown as source.
    static func plainFirstLine(of text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`>#]+"#, with: "", options: .regularExpression)
        for line in stripped.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed) }
        }
        return ""
    }
}

struct ClipboardCard: View {
    let item: ClipboardItem
    let displayedSnippet: String
    let palette: ClipFlowPalette
    @ObservedObject var store: ClipFlowStore
    var hover: RowHoverState? = nil
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: item.kind == .image || item.kind == .code ? 8 : 6) {
            metadata
            if item.isImage {
                imageContent
            } else if item.kind == .code {
                Text(String(store.displayFullText(for: item).prefix(1200)))
                    .font(.system(size: ClipFlowType.meta, weight: .medium, design: .monospaced))
                    .lineLimit(5).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.vertical, 2)
                tags
            } else {
                Text(summaryLine)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                tags
            }
        }
        // Symmetric breathing room: 9pt from left edge | 3pt bar | 10pt to content.
        .padding(.leading, 22)
        .padding(.trailing, ClipFlowLayout.space12)
        .padding(.vertical, ClipFlowLayout.space8)
        .frame(maxWidth: .infinity)
        .frame(height: LibraryCardLayout.height(for: item.kind), alignment: .top)
        .onReceive(store.historySelection.$itemID.map { $0 == item.id }.removeDuplicates()) {
            if isSelected != $0 { isSelected = $0 }
        }
        .overlay(alignment: .topTrailing) {
            if let hover {
                LibraryCardActionBar(hover: hover, pasteStack: store.pasteStack, itemID: item.id, pinned: item.pinned)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            AppIconBadgeView(item: item, size: 15)
            Text(item.sourceApp).lineLimit(1)
            Text(item.kind.label)
                .font(.system(size: ClipFlowType.mono, weight: .semibold))
                .foregroundStyle(item.kind.labelColor(for: colorScheme))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(item.kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(ClipCategory.pinned.labelColor(for: colorScheme)) }
            Spacer(minLength: 4)
            if item.autoExpire && item.expiresAt != nil {
                ExpiryCountdownRing(item: item, compact: true)
            } else {
                Text(item.timeLabel).lineLimit(1)
            }
        }
        .font(.system(size: ClipFlowType.mono, weight: .medium))
        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
        .frame(height: 16)
    }

    @ViewBuilder private var imageContent: some View {
        let thumbHeight: CGFloat = 104
        let thumbWidth: CGFloat = {
            guard let w = item.imageWidth, let h = item.imageHeight, w.isFinite, h.isFinite, w > 0, h > 0 else {
                return thumbHeight
            }
            return min(184, max(68, thumbHeight * w / h))
        }()
        HStack(alignment: .center, spacing: ClipFlowLayout.space12) {
            ClipThumbnailView(store: store, item: item, height: thumbHeight,
                cornerRadius: ClipFlowLayout.controlRadius, expandsToContainer: false,
                showsDimensionLabel: false, contentMode: .fit, insetPreview: true)
                .frame(width: thumbWidth, height: thumbHeight)
            VStack(alignment: .leading, spacing: ClipFlowLayout.space8) {
                Text(item.title).font(.system(size: ClipFlowType.cardTitle, weight: isSelected ? .semibold : .medium))
                    .lineLimit(2)
                tags
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .center)
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
        .font(.system(size: ClipFlowType.mono))
        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
        .frame(height: 13)
    }

    private var summaryLine: String {
        let line = ClipboardCardSummary.plainFirstLine(of: store.displayFullText(for: item))
        return line.isEmpty ? displayedSnippet : line
    }
}

