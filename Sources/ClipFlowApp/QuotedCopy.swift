import Foundation

/// Keeps short quotations, including paths such as “文稿/ClipFlow”, on one line.
enum QuotedCopy {
    /// A quotation longer than this may still wrap. The limit stays inside a settings column.
    static let maximumUnbrokenCount = 32
    private static let wordJoiner = "\u{2060}"
    private static let closers: [Character: Character] = [
        "“": "”",
        "\"": "\"",
        "「": "」",
        "『": "』"
    ]

    static func keepingQuotesIntact(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let closer = closers[character],
               let end = characters[(index + 1)...].firstIndex(of: closer) {
                let length = characters.distance(from: index, to: end) + 1
                if length <= maximumUnbrokenCount {
                    result += characters[index...end].map(String.init).joined(separator: wordJoiner)
                    index = end + 1
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }
}
