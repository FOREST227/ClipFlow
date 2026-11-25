import SwiftUI

struct QuickPastePanelFooter: View {
    let scope: QuickPasteScope
    let palette: ClipFlowPalette
    let onClose: () -> Void
    let onOpenLibrary: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSecondaryHints = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                QuickPasteKeyHint(keys: "↑↓", title: "选择")
                QuickPasteKeyHint(keys: "↩", title: "粘贴")
                QuickPasteKeyHint(shortcut: PlainTextPaste.quickPasteShortcut, title: PlainTextPaste.hintTitle)
            }
            .accessibilityElement(children: .contain)
            .accessibilityHint(QuickPasteSecondaryHint.spokenSummary(for: scope))
            Spacer(minLength: 8)
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
        .overlay(alignment: .bottomLeading) {
            secondaryHints
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.rowFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                )
                .offset(y: -30)
                .opacity(showsSecondaryHints ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!showsSecondaryHints)
        }
        .onHover { hovering in
            setSecondaryHintsVisible(hovering)
        }
    }

    private var secondaryHints: some View {
        HStack(spacing: 8) {
            QuickPasteKeyHint(keys: "⌘1–9", title: "直接粘贴")
            QuickPasteKeyHint(
                keys: QuickPasteSecondaryHint.keys(for: scope),
                title: QuickPasteSecondaryHint.title(for: scope)
            )
        }
    }

    private func setSecondaryHintsVisible(_ visible: Bool) {
        guard showsSecondaryHints != visible else { return }
        if reduceMotion {
            showsSecondaryHints = visible
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                showsSecondaryHints = visible
            }
        }
    }
}

private enum QuickPasteSecondaryHint {
    static func keys(for scope: QuickPasteScope) -> String {
        scope == .history ? "空格" : "⌃←→"
    }

    static func title(for scope: QuickPasteScope) -> String {
        scope == .history ? "详情" : "切换"
    }

    static func spokenSummary(for scope: QuickPasteScope) -> String {
        scope == .history ? "⌘1 到 9 直接粘贴，空格查看详情" : "⌘1 到 9 直接粘贴，Control 左右方向键切换"
    }
}
