import Foundation

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
    static let expandedHeight: CGFloat = compactHeight * 2 + spacing
    static let viewportHeight: CGFloat = compactHeight * 6 + spacing * 5

    static func height(for kind: ClipboardKind) -> CGFloat {
        kind == .image || kind == .code ? expandedHeight : compactHeight
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
    static let expandedHeight: CGFloat = compactHeight * 2 + spacing
    static let viewportHeight: CGFloat = compactHeight * 6 + spacing * 5

    static func height(for kind: ClipboardKind) -> CGFloat {
        kind == .image || kind == .code ? expandedHeight : compactHeight
    }
}
