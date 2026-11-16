import SwiftUI

struct QuickPastePanelFooter: View {
    let scope: QuickPasteScope
    let palette: ClipFlowPalette
    let onClose: () -> Void
    let onOpenLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: QuickPastePanelLayout.plainHintSpacing) {
            HStack(spacing: 8) {
                QuickPasteKeyHint(keys: "↑↓", title: "选择")
                QuickPasteKeyHint(keys: "↩", title: "粘贴")
                QuickPasteKeyHint(keys: "⌘1–9", title: "直接粘贴")
                if scope == .history {
                    QuickPasteKeyHint(keys: "空格", title: "详情")
                } else {
                    QuickPasteKeyHint(keys: "⌃←→", title: "切换")
                }
                Spacer(minLength: 0)
                Button {
                    onClose()
                    onOpenLibrary()
                } label: {
                    Text("历史记录")
                }
                .buttonStyle(MenuFooterActionStyle(fill: palette.secondaryButtonFill))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ClipFlowLayout.controlHeight)
            QuickPasteKeyHint(shortcut: PlainTextPaste.quickPasteShortcut, title: PlainTextPaste.hintTitle)
                .frame(height: QuickPastePanelLayout.plainHintHeight, alignment: .leading)
        }
    }
}
