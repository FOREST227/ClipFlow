import SwiftUI

/// One detail-card action. The face is an ordinary text or symbol view, not a button-style label.
/// A masked ancestor drops `ButtonStyleConfiguration.Label` text and leaves an empty pill.
struct InspectorCommand: Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case copy
        case paste
        case pin
        case saveSnippet
        case reveal
        case more
        case copyOriginal
        case insertDown
        case insertRight
        case copyPlain
        case pastePlain
    }

    var id: ID
    var title: String
    var symbol: String
    var accessibilityLabel: String
    var help: String?
    var isPrimary: Bool = false

    var hasVisibleFace: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension InspectorCommand.ID {
    var anchor: String {
        switch self {
        case .copy: "copy"
        case .paste: "paste"
        case .pin: "pin"
        case .saveSnippet: "save-snippet"
        case .reveal: "reveal"
        case .more: "more"
        case .copyOriginal: "copy-original"
        case .insertDown: "insert-down"
        case .insertRight: "insert-right"
        case .copyPlain: "copy-plain"
        case .pastePlain: "paste-plain"
        }
    }
}

/// Detail-card actions in reading order, plus how many trailing commands are the icon cluster.
struct InspectorActionSet: Equatable, Sendable {
    var commands: [InspectorCommand]
    /// Trailing commands that stay together when a row wraps.
    var iconClusterCount: Int
}

enum InspectorOverflowActionID: String, Equatable, Sendable {
    case copyPlain
    case pastePlain
    case pin
    case saveSnippet
    case openURL
    case revealInFinder
    case copyOriginal
    case insertDown
    case insertRight
    case delete
}

struct InspectorOverflowAction: Equatable, Sendable {
    var id: InspectorOverflowActionID
    var title: String
    var symbol: String
    var shortcut: String?
    var isDestructive: Bool = false
}

enum InspectorOverflowEntry: Equatable, Sendable {
    case action(InspectorOverflowAction)
    case separator
}

enum InspectorCommands {
    static func bar(pinned: Bool, canSaveSnippet: Bool, showsReveal: Bool, revealed: Bool) -> [InspectorCommand] {
        actions(
            pinned: pinned,
            canSaveSnippet: canSaveSnippet,
            showsReveal: showsReveal,
            revealed: revealed,
            hasRichText: false,
            hasOriginalTypes: false,
            offersExcelInsert: false
        ).commands
    }

    /// The face of the card: paste, copy, reveal for protected items, and overflow.
    static func actions(
        pinned: Bool,
        canSaveSnippet: Bool,
        showsReveal: Bool,
        revealed: Bool,
        hasRichText: Bool,
        hasOriginalTypes: Bool,
        offersExcelInsert: Bool
    ) -> InspectorActionSet {
        _ = (pinned, canSaveSnippet, hasRichText, hasOriginalTypes, offersExcelInsert)
        var commands = [
            InspectorCommand(id: .paste, title: "粘贴", symbol: "arrow.down.doc", accessibilityLabel: "粘贴", isPrimary: true),
            InspectorCommand(id: .copy, title: "复制", symbol: "doc.on.doc", accessibilityLabel: "复制")
        ]
        if showsReveal {
            commands.append(InspectorCommand(
                id: .reveal,
                title: revealed ? "隐藏" : "显示",
                symbol: revealed ? "eye.slash" : "eye",
                accessibilityLabel: revealed ? "隐藏" : "显示",
                help: revealed ? "隐藏" : "显示"
            ))
        }
        commands.append(InspectorCommand(id: .more, title: "", symbol: "ellipsis", accessibilityLabel: "更多操作", help: "更多操作"))
        return InspectorActionSet(commands: commands, iconClusterCount: 0)
    }

    /// Secondary and kind-specific actions. Delete stays last, under a divider.
    static func overflowMenu(
        pinned: Bool,
        canSaveSnippet: Bool,
        hasRichText: Bool,
        canOpenURL: Bool,
        canRevealInFinder: Bool,
        hasOriginalTypes: Bool,
        offersExcelInsert: Bool
    ) -> [InspectorOverflowEntry] {
        var entries: [InspectorOverflowEntry] = []
        if hasRichText {
            entries.append(.action(InspectorOverflowAction(
                id: .copyPlain, title: PlainTextPaste.copyTitle, symbol: "doc.text", shortcut: nil)))
            entries.append(.action(InspectorOverflowAction(
                id: .pastePlain,
                title: PlainTextPaste.pasteTitle,
                symbol: "arrow.down.doc",
                shortcut: ShortcutGlyphLayout.plainText(for: PlainTextPaste.quickPasteShortcut))))
        }
        entries.append(.action(InspectorOverflowAction(
            id: .pin,
            title: pinned ? "取消置顶" : "置顶",
            symbol: pinned ? "pin.slash" : "pin",
            shortcut: nil)))
        if canSaveSnippet {
            entries.append(.action(InspectorOverflowAction(
                id: .saveSnippet, title: "存为片段", symbol: "plus.square.on.square", shortcut: nil)))
        }
        if canOpenURL {
            entries.append(.action(InspectorOverflowAction(
                id: .openURL, title: "访问链接", symbol: "safari", shortcut: nil)))
        }
        if canRevealInFinder {
            entries.append(.action(InspectorOverflowAction(
                id: .revealInFinder, title: "在访达中显示", symbol: "folder", shortcut: nil)))
        }
        if hasOriginalTypes {
            entries.append(.action(InspectorOverflowAction(
                id: .copyOriginal, title: SpreadsheetClipboard.copyOnlyTitle, symbol: "doc.on.clipboard", shortcut: nil)))
        }
        if offersExcelInsert {
            entries.append(.action(InspectorOverflowAction(
                id: .insertDown, title: SpreadsheetShift.down.menuTitle, symbol: "arrow.down", shortcut: nil)))
            entries.append(.action(InspectorOverflowAction(
                id: .insertRight, title: SpreadsheetShift.right.menuTitle, symbol: "arrow.right", shortcut: nil)))
        }
        entries.append(.separator)
        entries.append(.action(InspectorOverflowAction(
            id: .delete, title: "删除条目", symbol: "trash", shortcut: nil, isDestructive: true)))
        return entries
    }

    static func canRevealInFinder(_ item: ClipboardItem) -> Bool {
        item.fileURLs?.contains { URL(string: $0)?.isFileURL == true } == true
    }

    static func finderURL(for item: ClipboardItem) -> URL? {
        item.fileURLs?.compactMap { URL(string: $0) }.first { $0.isFileURL }
    }

    static func spreadsheet(hasOriginalTypes: Bool, offersExcelInsert: Bool) -> [InspectorCommand] {
        var commands: [InspectorCommand] = []
        if hasOriginalTypes {
            commands.append(InspectorCommand(
                id: .copyOriginal,
                title: SpreadsheetClipboard.copyOnlyTitle,
                symbol: "doc.on.clipboard",
                accessibilityLabel: SpreadsheetClipboard.copyOnlyTitle,
                help: "把原始表格数据放回剪贴板，不自动粘贴。可接着在 Excel 里用选择性粘贴或「插入复制的单元格」。"
            ))
        }
        if offersExcelInsert {
            commands.append(InspectorCommand(
                id: .insertDown,
                title: SpreadsheetShift.down.menuTitle,
                symbol: "arrow.down",
                accessibilityLabel: SpreadsheetShift.down.menuTitle,
                help: "在 Excel 当前单元格处插入同样大小的区域并下移原有单元格，再粘贴原格式。"
            ))
            commands.append(InspectorCommand(
                id: .insertRight,
                title: "右移单元格",
                symbol: "arrow.right",
                accessibilityLabel: SpreadsheetShift.right.menuTitle,
                help: "在 Excel 当前单元格处插入同样大小的区域并向右移开原有单元格，再粘贴原格式。"
            ))
        }
        return commands
    }

    static func plainText(hasRichText: Bool) -> [InspectorCommand] {
        guard hasRichText else { return [] }
        return [
            InspectorCommand(
                id: .copyPlain,
                title: PlainTextPaste.copyTitle,
                symbol: "doc.text",
                accessibilityLabel: PlainTextPaste.copyTitle,
                help: "只复制原来的文字，不带格式"
            ),
            InspectorCommand(
                id: .pastePlain,
                title: PlainTextPaste.pasteTitle,
                symbol: "arrow.down.doc",
                accessibilityLabel: PlainTextPaste.pasteTitle,
                help: "只粘贴原来的文字，不带格式"
            )
        ]
    }
}

struct InspectorCommandFace: View {
    let command: InspectorCommand
    let fill: Color
    let foreground: Color
    var border: Color = .clear

    var body: some View {
        HStack(spacing: 6) {
            if !command.symbol.isEmpty {
                Image(systemName: command.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
            if !command.title.isEmpty {
                Text(command.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, command.title.isEmpty ? 10 : 12)
        .frame(minWidth: 32, minHeight: ClipFlowLayout.controlHeight, maxHeight: ClipFlowLayout.controlHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.accessibilityLabel)
    }
}

struct InspectorCommandButton: View {
    let command: InspectorCommand
    let fill: Color
    let foreground: Color
    var border: Color = .clear
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            InspectorCommandFace(command: command, fill: fill, foreground: foreground, border: border)
        }
        .buttonStyle(.plain)
        .help(command.help ?? command.accessibilityLabel)
        .accessibilityLabel(command.accessibilityLabel)
    }
}
