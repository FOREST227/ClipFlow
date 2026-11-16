import Foundation

enum LibraryImageThumbnail {
    static let height: CGFloat = 72
    static let maxWidth: CGFloat = 160

    static func width(imageWidth: Double?, imageHeight: Double?) -> CGFloat {
        guard let imageWidth, let imageHeight, imageWidth.isFinite, imageHeight.isFinite,
              imageWidth > 0, imageHeight > 0 else { return height }
        return min(maxWidth, max(1, height * imageWidth / imageHeight))
    }
}

enum LibraryImageShape: Equatable {
    case landscape, square, portrait

    static func resolve(width: Double?, height: Double?) -> Self {
        guard let width, let height, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return .square }
        let ratio = width / height
        if ratio >= 1.25 { return .landscape }
        if ratio <= 0.8 { return .portrait }
        return .square
    }
}

enum LibraryCardLayout {
    static let spacing: CGFloat = 8
    static let compactHeight: CGFloat = 72
    static let contentPadding: CGFloat = 8
    static let metadataHeight: CGFloat = 16
    static let blockSpacing: CGFloat = 6
    /// Metadata, the gap under it, and the thumbnail. Image rows stop there.
    static let imageHeight: CGFloat = contentPadding * 2 + metadataHeight + blockSpacing + LibraryImageThumbnail.height
    /// Code keeps a second row so five monospaced lines stay readable.
    static let expandedHeight: CGFloat = compactHeight * 2 + spacing
    static let viewportHeight: CGFloat = compactHeight * 6 + spacing * 5

    static func height(for kind: ClipboardKind) -> CGFloat {
        switch kind {
        case .image: imageHeight
        case .code: expandedHeight
        default: compactHeight
        }
    }
}

/// Tall-image details use the available pane height while keeping actions visible.
enum DetailImageLayout {
    static func previewHeight(shape: LibraryImageShape, availableHeight: CGFloat, expandedInfo: Bool) -> CGFloat {
        let available = max(80, availableHeight - (expandedInfo ? 340 : 220))
        return shape == .portrait ? available : min(260, available)
    }
}

enum QuickPasteCardLayout {
    static let spacing: CGFloat = 8
    static let compactHeight: CGFloat = 64
    static let verticalPadding: CGFloat = 8
    static let metadataHeight: CGFloat = 14
    static let contentSpacing: CGFloat = 6
    /// Landscape rows add one caption line under the thumbnail. That is the tallest image row.
    static let imageCaptionGap: CGFloat = 4
    static let imageCaptionHeight: CGFloat = 12
    static let imageHeight: CGFloat = verticalPadding * 2 + metadataHeight + contentSpacing
        + LibraryImageThumbnail.height + imageCaptionGap + imageCaptionHeight
    static let expandedHeight: CGFloat = compactHeight * 2 + spacing
    static let viewportHeight: CGFloat = compactHeight * 6 + spacing * 5

    static func height(for kind: ClipboardKind) -> CGFloat {
        switch kind {
        case .image: imageHeight
        case .code: expandedHeight
        default: compactHeight
        }
    }
}
