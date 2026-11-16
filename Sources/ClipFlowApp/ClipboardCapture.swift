import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct EncodedClipboardImage: Sendable, Equatable {
    let pngData: Data
    let size: CGSize
    let signature: String
}

/// Decides whether a pasteboard change is text, copied files, or an image.
///
/// Web pages often attach a rendered preview beside the copied string, RTF, or HTML.
/// That preview is not the copy. An image is recorded when there is no meaningful
/// text or file list, or when the pasteboard is an image file or an image-only
/// document whose string is only the image URL or file name.
/// Spreadsheet copies (Excel, Numbers, WPS) keep the cell text even when a preview
/// image or an image-only HTML wrapper is sitting on the same item.
final class ClipboardCapture {
    enum Choice: Equatable {
        case text(String)
        case image(ClipboardImageEncoder.Source)
    }

    static func choose(from pasteboard: NSPasteboard) -> Choice? {
        choose(ClipboardPasteboardReading.read(from: pasteboard))
    }

    static func choose(_ reading: ClipboardPasteboardReading) -> Choice? {
        ClipboardCaptureDecision.choose(reading)
    }

    /// Classification over a type identifier → bytes map. Tests call this without `NSPasteboard`.
    static func choose(types: [String: Data]) -> Choice? {
        ClipboardCaptureDecision.choose(types: types)
    }

    static func isMeaningful(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
    }

    private init() {}
}

/// Reads and writes the rich pasteboard representations stored with a history item.
///
/// Plain text stays on the item. RTF, HTML, and file URLs are captured beside it.
/// A spreadsheet copy also keeps every original type, in declaration order, so a later
/// paste can put those bytes back unchanged.
final class ClipboardRepresentations {
    struct Snapshot: Equatable, Sendable {
        var rtfData: Data?
        var htmlData: Data?
        var fileURLs: [String]
        var extraTypes: [ClipboardPasteboardType] = []

        static let empty = Snapshot(rtfData: nil, htmlData: nil, fileURLs: [], extraTypes: [])
    }

    static let rtfTypes: [NSPasteboard.PasteboardType] = [
        .rtf,
        NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type"),
        .rtfd
    ]

    static let htmlTypes: [NSPasteboard.PasteboardType] = [
        .html,
        NSPasteboard.PasteboardType("Apple HTML pasteboard type")
    ]

    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func capture(from pasteboard: NSPasteboard) -> Snapshot {
        capture(ClipboardPasteboardReading.read(from: pasteboard))
    }

    static func capture(_ reading: ClipboardPasteboardReading) -> Snapshot {
        let types = ClipboardCaptureDecision.typeMap(from: reading.entries)
        return Snapshot(
            rtfData: rtfData(in: types),
            htmlData: htmlData(in: types),
            fileURLs: reading.fileURLs.map(\.absoluteString),
            extraTypes: ClipboardCaptureDecision.preservedEntries(reading.entries)
        )
    }

    /// Writes one pasteboard item whose types and bytes match `records`, in that order.
    /// `NSPasteboardItem.setData` rejects legacy names such as `Biff8` and `Embed Source`,
    /// so this uses `declareTypes`, which keeps those identifiers.
    @discardableResult
    static func writeOriginal(_ records: [ClipboardPasteboardType], to pasteboard: NSPasteboard) -> Bool {
        let records = records.filter { !$0.data.isEmpty }
        guard !records.isEmpty else { return false }
        let types = records.map { NSPasteboard.PasteboardType($0.type) }
        guard pasteboard.declareTypes(types, owner: nil) != 0 else { return false }
        var wrote = false
        for record in records {
            if pasteboard.setData(record.data, forType: NSPasteboard.PasteboardType(record.type)) {
                wrote = true
            }
        }
        return wrote
    }

    @discardableResult
    static func write(plainText: String, snapshot: Snapshot, to pasteboard: NSPasteboard) -> Bool {
        if !snapshot.extraTypes.isEmpty {
            return writeOriginal(snapshot.extraTypes, to: pasteboard)
        }
        pasteboard.clearContents()

        let files = snapshot.fileURLs.compactMap(fileURL(from:))
        let rtf = nonempty(snapshot.rtfData)
        let html = nonempty(snapshot.htmlData)
        if files.isEmpty && rtf == nil && html == nil {
            return pasteboard.setString(plainText, forType: .string)
        }

        var items: [NSPasteboardItem] = []
        if files.isEmpty {
            let item = NSPasteboardItem()
            fill(item, plainText: plainText, rtf: rtf, html: html)
            items = [item]
        } else {
            for (index, url) in files.enumerated() {
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                if index == 0 {
                    fill(item, plainText: plainText, rtf: rtf, html: html)
                }
                items.append(item)
            }
        }
        return pasteboard.writeObjects(items)
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var collected = readFileURLObjects(on: pasteboard)
        let paths = filenamePaths(on: pasteboard)
        if paths.count > collected.count {
            collected = paths.map { URL(fileURLWithPath: $0) }
        }
        if collected.isEmpty {
            for item in pasteboard.pasteboardItems ?? [] {
                guard let value = item.string(forType: .fileURL),
                      let url = fileURL(from: value) else { continue }
                collected.append(url)
            }
        }

        var seen = Set<String>()
        return collected.filter { url in
            seen.insert(canonicalPath(url)).inserted
        }
    }

    private static func fill(_ item: NSPasteboardItem, plainText: String, rtf: Data?, html: Data?) {
        if !plainText.isEmpty {
            item.setString(plainText, forType: .string)
        }
        if let rtf {
            item.setData(rtf, forType: .rtf)
        }
        if let html {
            setHTML(html, on: item)
        }
    }

    private static func rtfData(in types: [String: Data]) -> Data? {
        for name in ["public.rtf", "NeXT Rich Text Format v1.0 pasteboard type"] {
            if let data = nonempty(types[name]) { return data }
        }
        guard let rtfd = nonempty(types["public.rtfd"]),
              let attributed = NSAttributedString(rtfd: rtfd, documentAttributes: nil),
              attributed.length > 0 else {
            return nil
        }
        return nonempty(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
    }

    private static func htmlData(in types: [String: Data]) -> Data? {
        for name in ClipboardPasteboardKinds.htmlTypes {
            if let data = nonempty(types[name]) { return data }
        }
        return nil
    }

    private static func readFileURLObjects(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private static func filenamePaths(on pasteboard: NSPasteboard) -> [String] {
        guard pasteboard.types?.contains(filenamesType) == true else { return [] }
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return paths
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let paths = item.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
                return paths
            }
        }
        return []
    }

    private static func setHTML(_ data: Data, on item: NSPasteboardItem) {
        if let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16), !string.isEmpty {
            item.setString(string, forType: .html)
        } else {
            item.setData(data, forType: .html)
        }
    }

    private static func fileURL(from string: String) -> URL? {
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }

    private static func nonempty(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private init() {}
}

/// Plain text of clipboard HTML, ignoring markup that only wraps a picture.
final class ClipboardHTMLText {
    static func plainText(from html: String) -> String {
        let body = documentBody(html)
        let withBreaks = insertingLineBreaks(in: body)
        let stripped = strippingTags(from: withBreaks)
        let decoded = decodingEntities(in: stripped)
        let collapsed = decoded.replacingOccurrences(
            of: "[\\t\\f\\r ]+",
            with: " ",
            options: .regularExpression
        )
        return collapsed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func isImageOnlyDocument(_ html: String) -> Bool {
        let body = documentBody(html)
        guard containsImageTag(body) else { return false }
        return !ClipboardCapture.isMeaningful(plainText(from: html))
    }

    /// A real table, not an `<img>` wrapped in markup. Both `<table>` and a cell are required.
    static func isTabularDocument(_ html: String) -> Bool {
        let body = documentBody(html)
        let hasTable = body.range(of: "<table\\b", options: [.regularExpression, .caseInsensitive]) != nil
        let hasCell = body.range(of: "<t[dh]\\b", options: [.regularExpression, .caseInsensitive]) != nil
        return hasTable && hasCell
    }

    /// True when `text` is only the source URL or file name of an image in `html`.
    static func matchesImageReference(_ text: String, html: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return imageReferences(in: documentBody(html)).contains { reference in
            let source = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.caseInsensitiveCompare(source) == .orderedSame { return true }
            let name = imageFileName(from: source)
            return !name.isEmpty && trimmed.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func imageReferences(in html: String) -> [String] {
        let pattern = #"(?i)<(?:img|image|svg)\b[^>]*?\b(?:src|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            for group in 1..<match.numberOfRanges {
                let source = Range(match.range(at: group), in: html).map { String(html[$0]) }
                if let source, !source.isEmpty { return source }
            }
            return nil
        }
    }

    private static func imageFileName(from reference: String) -> String {
        let withoutFragment = reference.split(separator: "#", maxSplits: 1).first.map(String.init) ?? reference
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutFragment
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        if let url = URL(string: decoded) {
            let name = url.lastPathComponent
            if !name.isEmpty, name != "/" { return name }
        }
        let name = (decoded as NSString).lastPathComponent
        return name == "/" ? "" : name
    }

    private static func documentBody(_ html: String) -> String {
        removingBlocks(named: ["script", "style"], from: removingComments(from: html))
    }

    private static func removingComments(from html: String) -> String {
        html.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
    }

    private static func removingBlocks(named names: [String], from html: String) -> String {
        names.reduce(html) { partial, name in
            partial.replacingOccurrences(
                of: "(?is)<\(name)\\b[^>]*>.*?</\(name)\\s*>",
                with: "",
                options: .regularExpression
            )
        }
    }

    private static func insertingLineBreaks(in html: String) -> String {
        html.replacingOccurrences(
            of: "(?i)<br\\s*/?>|</(?:p|div|li|tr|h[1-6])\\s*>",
            with: "\n",
            options: .regularExpression
        )
    }

    private static func strippingTags(from html: String) -> String {
        html.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
    }

    private static func containsImageTag(_ html: String) -> Bool {
        html.range(of: "<(?:img|image|svg)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func decodingEntities(in text: String) -> String {
        var decoded = decodeNumericEntities(in: text)
        let named = [
            ("&nbsp;", "\u{00A0}"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&")
        ]
        for (entity, value) in named {
            decoded = decoded.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return decoded
    }

    private static func decodeNumericEntities(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);", options: .caseInsensitive) else {
            return text
        }

        let source = text as NSString
        var decoded = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1, let range = Range(match.range, in: decoded) else { continue }
            let token = source.substring(with: match.range(at: 1))
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token)
            }
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { continue }
            decoded.replaceSubrange(range, with: String(scalar))
        }
        return decoded
    }

    private init() {}
}

/// Turns clipboard image bytes into the PNG payload stored in history.
/// Safe to call off the main thread: it reads only the data or file it is given.
final class ClipboardImageEncoder {
    enum Source: Sendable, Equatable {
        case data(Data)
        case file(URL)
    }

    static func encode(_ source: Source) -> EncodedClipboardImage? {
        let data: Data?
        switch source {
        case .data(let inline):
            data = inline
        case .file(let url):
            data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard let data, !data.isEmpty else { return nil }
        return pngPayload(from: data)
    }

    static func signature(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func pngPayload(from data: Data) -> EncodedClipboardImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        guard let image = orientedImage(from: source) else { return nil }

        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            pngData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), pngData.length > 0 else { return nil }

        let encoded = pngData as Data
        return EncodedClipboardImage(
            pngData: encoded,
            size: CGSize(width: image.width, height: image.height),
            signature: signature(for: encoded)
        )
    }

    private static func orientedImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private init() {}
}
