import SwiftUI

struct QuickPasteKeyHint: View {
    private let title: String
    private let keys: String?
    private let shortcut: ClipFlowShortcut?

    init(keys: String, title: String) {
        self.keys = keys
        self.title = title
        self.shortcut = nil
    }

    init(shortcut: ClipFlowShortcut, title: String) {
        self.keys = nil
        self.title = title
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 3) {
            keyCap
                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(title).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKeys) \(title)")
    }

    @ViewBuilder
    private var keyCap: some View {
        if let shortcut {
            ShortcutGlyphLayout.text(for: shortcut, pointSize: 9, weight: .semibold)
        } else {
            Text(keys ?? "")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
    }

    private var spokenKeys: String {
        shortcut?.displayName ?? keys ?? ""
    }
}
