import Combine
import SwiftUI

enum QuickPasteScope: Equatable {
    case history
    case snippets
}

struct QuickPasteScopeBar: View {
    let scope: QuickPasteScope
    let snippetMatchCount: Int
    let palette: ClipFlowPalette
    let onSelect: (QuickPasteScope) -> Void

    var body: some View {
        HStack(spacing: 4) {
            scopeButton(.history, title: "历史", badge: nil, hint: "显示剪贴历史")
            scopeButton(.snippets, title: "片段",
                badge: snippetMatchCount > 0 ? "\(snippetMatchCount)" : nil,
                hint: "显示常用片段")
            Spacer(minLength: 0)
        }
        .padding(2)
        .frame(height: ClipFlowLayout.controlHeight)
        .background(palette.inputFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("快速粘贴范围")
    }

    private func scopeButton(_ value: QuickPasteScope, title: String, badge: String?, hint: String) -> some View {
        let selected = scope == value
        return Button { onSelect(value) } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(selected ? 0.22 : 0.12)))
                        .accessibilityLabel("\(badge) 个匹配片段")
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                selected ? ClipCategory.all.solid : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct QuickPasteSnippetList: View {
    let snippets: [SavedSnippet]
    let selection: HistorySelection
    let onSelect: (SavedSnippet) -> Void
    let onPaste: (SavedSnippet) -> Void
    var onPastePlain: (SavedSnippet) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ClipFlowPalette.resolve(for: colorScheme)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(snippets) { snippet in
                        QuickPasteSnippetRow(
                            snippet: snippet,
                            selected: selection.itemID == snippet.id,
                            palette: palette,
                            onSelect: { onSelect(snippet) },
                            onPaste: { onPaste(snippet) },
                            onPastePlain: { onPastePlain(snippet) }
                        )
                        .id(snippet.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onReceive(selection.revealRequests) { id in
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("常用片段")
    }
}

private struct QuickPasteSnippetRow: View {
    let snippet: SavedSnippet
    let selected: Bool
    let palette: ClipFlowPalette
    let onSelect: () -> Void
    let onPaste: () -> Void
    var onPastePlain: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(snippet.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("片段")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ClipCategory.code.labelColor(for: colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(ClipCategory.code.tint.opacity(0.2)))
            }
            if let category = snippet.category {
                Text(category)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    .lineLimit(1)
            }
            Text(snippet.body)
                .font(.system(size: 11))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .fill(selected ? palette.selectedRowFill : palette.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
                .strokeBorder(selected ? ClipCategory.code.labelColor(for: colorScheme).opacity(0.85) : palette.rowBorder, lineWidth: 1)
        )
        .overlay(SnippetClickCatcher(onClick: onSelect, onDoubleClick: onPaste, onPlainDoubleClick: onPastePlain))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SnippetLibrary.accessibilityLabel(for: snippet))
        .accessibilityHint("单击选中，双击或按回车粘贴。按住 Shift 双击则只粘贴纯文本。")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "粘贴", onPaste)
        .accessibilityAction(named: PlainTextPaste.pasteTitle, onPastePlain)
    }
}

/// Distinguishes a selection click from a paste double-click.
final class SnippetClickView: NSView {
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onPlainDoubleClick: () -> Void = {}

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 {
            if PlainTextPaste.isPlainTextClick(event.modifierFlags) {
                onPlainDoubleClick()
            } else {
                onDoubleClick()
            }
        } else {
            onClick()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SnippetClickCatcher: NSViewRepresentable {
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    var onPlainDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> SnippetClickView {
        let view = SnippetClickView()
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onPlainDoubleClick = onPlainDoubleClick
        return view
    }

    func updateNSView(_ nsView: SnippetClickView, context: Context) {
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onPlainDoubleClick = onPlainDoubleClick
    }
}
