import SwiftUI

enum ClipCategory: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case code
    case links
    case images
    case protected

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部内容"
        case .pinned: "置顶内容"
        case .text: "文本内容"
        case .code: "代码片段"
        case .links: "链接资源"
        case .images: "图片内容"
        case .protected: "敏感内容"
        }
    }

    /// Compact label for the single-row filter bar.
    var shortTitle: String {
        switch self {
        case .all: "全部"
        case .pinned: "置顶"
        case .text: "文本"
        case .code: "代码"
        case .links: "链接"
        case .images: "图片"
        case .protected: "敏感"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "按时间和来源整理的本地剪贴历史"
        case .pinned: "置顶后始终排在最前的常用内容"
        case .text: "普通文字与段落"
        case .code: "命令、代码和终端可直接使用的文本"
        case .links: "网址、参考资料与可分享内容"
        case .images: "截图与复制的图片"
        case .protected: "遮罩显示、本地保存或自动过期的条目"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .pinned: "pin"
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .links: "link"
        case .images: "photo"
        case .protected: "lock.shield"
        }
    }

    /// Decorative wash. Solid fills and light-mode labels use `solid`.
    var tint: Color { CategoryInk.wash(self) }
    var solid: Color { CategoryInk.solid(self) }
    func labelColor(for colorScheme: ColorScheme) -> Color {
        CategoryInk.label(self, colorScheme: colorScheme)
    }
}
