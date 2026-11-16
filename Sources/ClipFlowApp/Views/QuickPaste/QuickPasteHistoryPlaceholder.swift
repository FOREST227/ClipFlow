import SwiftUI

struct QuickPasteHistoryPlaceholder: View {
    let queryIsEmpty: Bool
    let shortcut: ClipFlowShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(queryIsEmpty ? "还没有捕获到内容" : "没有匹配的内容")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Group {
                if queryIsEmpty {
                    (Text("先去其他应用复制文字或图片，然后按下 ")
                        + ShortcutGlyphLayout.text(for: shortcut, pointSize: 12, weight: .medium)
                        + Text("，就能在指针附近把它调出来。"))
                        .accessibilityLabel("先去其他应用复制文字或图片，然后按下 \(shortcut.displayName)，就能在指针附近把它调出来。")
                } else {
                    Text("试试其他关键词，或打开历史记录查看全部内容。")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: QuickPasteCardLayout.viewportHeight, alignment: .top)
    }
}
