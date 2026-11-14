import AppKit

/// Writes a history item back as its original plain string.
///
/// A normal paste restores RTF, HTML, and file URLs beside the string.
/// Plain paste declares only `public.utf8-plain-text` and leaves the stored item alone.
final class PlainTextPaste {
    static let pasteTitle = "粘贴为纯文本"
    static let copyTitle = "复制为纯文本"
    static let hintTitle = "粘贴为纯文本"
    /// ⇧↩ in the quick-paste panel. Shift alone is not a valid summon shortcut.
    static let quickPasteShortcut = ClipFlowShortcut(keyCode: 36, flags: .shift)

    private init() {}

    /// RTF or HTML is present. Images and already-plain items are excluded.
    static func hasRichText(_ item: ClipboardItem) -> Bool {
        guard !item.isImage else { return false }
        return hasBytes(item.rtfData) || hasBytes(item.htmlData)
    }

    /// Images have no plain string. Empty text is left on the original paste path.
    static func canPasteAsPlainText(_ item: ClipboardItem) -> Bool {
        !item.isImage && !item.fullText.isEmpty
    }

    /// ⇧ combined with a click, without ⌘, ⌥, or ⌃.
    static func isPlainTextClick(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .command, .option, .control]) == .shift
    }

    /// Declares only the string type and stores `text` unchanged.
    @discardableResult
    static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.declareTypes([.string], owner: nil) != 0 else { return false }
        return pasteboard.setString(text, forType: .string)
    }

    /// AppKit always lists the modern string UTI together with this legacy name.
    /// Both read the same bytes. They are not a second representation.
    static let legacyStringTypeName = "NSStringPboardType"
    static let plainStringTypeNames: Set<String> = ["public.utf8-plain-text", legacyStringTypeName]

    static func typeNames(on pasteboard: NSPasteboard) -> [String] {
        (pasteboard.types ?? []).map(\.rawValue)
    }

    /// True when every declared type is the plain string or its legacy alias.
    static func containsOnlyPlainString(_ pasteboard: NSPasteboard) -> Bool {
        let names = Set(typeNames(on: pasteboard))
        return names.contains("public.utf8-plain-text") && names.isSubset(of: plainStringTypeNames)
    }

    private static func hasBytes(_ data: Data?) -> Bool {
        data?.isEmpty == false
    }
}
