import AppKit
import CoreText
import SwiftUI

/// Formats a shortcut as separate modifier and key runs.
///
/// The system font draws ⌃ on the cap line, so a single string such as "⌃V"
/// looks like a superscript caret sitting on the letter. Menus avoid that by
/// drawing each symbol as its own run: a short gap between runs, and each
/// modifier shifted so its ink center sits on the key's optical middle.
/// `ClipFlowShortcut.displayName` stays the compact accessibility string.
final class ShortcutGlyphLayout {
    /// Gap between modifier glyphs, and between the last modifier and the key.
    static let spacing: CGFloat = 3

    struct Run: Equatable, Sendable {
        let text: String
        /// Points added to the baseline. Positive moves the glyph up.
        /// The key stays at zero; modifiers move onto its optical middle.
        let baselineOffset: CGFloat
    }

    private init() {}

    /// Compact string used by VoiceOver and stored messages. No spaces.
    static func plainText(for shortcut: ClipFlowShortcut) -> String {
        shortcut.keyCaps.joined()
    }

    static func runs(for shortcut: ClipFlowShortcut, font: NSFont) -> [Run] {
        let parts = shortcut.keyCaps
        guard let key = parts.last else { return [] }
        let target = opticalMiddle(of: key, font: font)
        return parts.enumerated().map { index, text in
            let isKey = index == parts.count - 1
            let offset = isKey ? 0 : target - inkMidY(text, font: font)
            return Run(text: text, baselineOffset: offset)
        }
    }

    /// Ink center above the baseline. Letters land on the cap-height center.
    static func inkMidY(_ text: String, font: NSFont) -> CGFloat {
        let bounds = imageBounds(of: text, font: font)
        guard bounds.height > 0 else { return font.capHeight / 2 }
        return bounds.midY
    }

    /// Where modifier ink should sit relative to the baseline.
    /// A letter's ink center is the cap-height center. A mark that does not
    /// fill the cap height (a period) keeps modifiers on that center.
    static func opticalMiddle(of key: String, font: NSFont) -> CGFloat {
        let bounds = imageBounds(of: key, font: font)
        let capCenter = font.capHeight / 2
        guard bounds.height >= font.xHeight * 0.75 else { return capCenter }
        return bounds.midY
    }

    static func attributedString(for shortcut: ClipFlowShortcut, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let pieces = runs(for: shortcut, font: font)
        for (index, run) in pieces.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .baselineOffset: run.baselineOffset
            ]
            if index < pieces.count - 1 {
                attributes[.kern] = spacing
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    @MainActor
    static func text(for shortcut: ClipFlowShortcut, pointSize: CGFloat, weight: Font.Weight = .regular) -> Text {
        Text(swiftAttributedString(for: shortcut, pointSize: pointSize, weight: weight))
    }

    @MainActor
    static func swiftAttributedString(for shortcut: ClipFlowShortcut, pointSize: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        let font = NSFont.systemFont(ofSize: pointSize, weight: nsFontWeight(weight))
        var result = AttributedString()
        let pieces = runs(for: shortcut, font: font)
        for (index, run) in pieces.enumerated() {
            var piece = AttributedString(run.text)
            piece.font = .system(size: pointSize, weight: weight)
            piece.baselineOffset = run.baselineOffset
            if index < pieces.count - 1 {
                piece.kern = spacing
            }
            result.append(piece)
        }
        return result
    }

    private static func nsFontWeight(_ weight: Font.Weight) -> NSFont.Weight {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .regular { return .regular }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }

    private static func imageBounds(of text: String, font: NSFont) -> CGRect {
        guard !text.isEmpty else { return .zero }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        let bounds = CTLineGetImageBounds(line, nil)
        if bounds.isNull || bounds.isInfinite || bounds.height <= 0 { return .zero }
        return bounds
    }
}
