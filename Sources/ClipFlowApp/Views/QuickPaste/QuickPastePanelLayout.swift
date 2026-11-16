import Foundation

enum QuickPastePanelLayout {
    static let panelWidth: CGFloat = ClipFlowLayout.menuWidth
    static let plainHintSpacing: CGFloat = 6
    static let plainHintHeight: CGFloat = 18
    static let panelHeight: CGFloat = QuickPasteCardLayout.viewportHeight + 164 + plainHintSpacing + plainHintHeight
    static let cornerRadius: CGFloat = ClipFlowLayout.overlayRadius
    static let anchorOffset: CGFloat = 18
    static let screenInset: CGFloat = 12
}
