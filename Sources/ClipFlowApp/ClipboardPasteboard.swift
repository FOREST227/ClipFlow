import AppKit
import Foundation
import UniformTypeIdentifiers

/// One pasteboard type, in the order it was declared, with the bytes `data(forType:)` returned.
/// Order is the array order. A dictionary would not survive JSON.
struct ClipboardPasteboardType: Codable, Equatable, Hashable, Sendable {
    var type: String
    var data: Data
}

/// Types read off a pasteboard, plus file URLs AppKit resolved across every item.
struct ClipboardPasteboardReading: Equatable, Sendable {
    var entries: [ClipboardPasteboardType]
    var fileURLs: [URL]

    static let empty = ClipboardPasteboardReading(entries: [], fileURLs: [])
}

/// Identifies spreadsheet, preview-image, and text pasteboard types without reading a live pasteboard.
enum ClipboardPasteboardKinds {
    static let stringTypes = [
        "public.utf8-plain-text",
        "NSStringPboardType",
        "public.utf16-plain-text",
        "NeXT plain ascii pasteboard type"
    ]

    static let htmlTypes = [
        "public.html",
        "Apple HTML pasteboard type"
    ]

    static let rtfTypes = [
        "public.rtf",
        "NeXT Rich Text Format v1.0 pasteboard type",
        "public.rtfd"
    ]

    static let tabSeparatedTypes = [
        "public.utf16-tab-separated-text",
        "public.utf8-tab-separated-text"
    ]

    static let imagePreference = [
        "public.png",
        "public.jpeg",
        "public.gif",
        "public.tiff",
        "org.webmproject.webp",
        "public.webp",
        "com.microsoft.bmp",
        "public.bmp",
        "public.heic",
        "NeXT TIFF v4.0 pasteboard type"
    ]

    static func isStringType(_ type: String) -> Bool {
        stringTypes.contains(type)
    }

    static func isHTMLType(_ type: String) -> Bool {
        htmlTypes.contains(type)
    }

    static func isRTFType(_ type: String) -> Bool {
        rtfTypes.contains(type) || type == "NeXT RTFD pasteboard type"
    }

    static func isFileURLType(_ type: String) -> Bool {
        type == "public.file-url" || type == "NSFilenamesPboardType" || type == "CorePasteboardFlavorType 0x6675726C"
    }

    static func isPDF(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower == "public.pdf" || lower == "com.adobe.pdf"
    }

    /// A rendered preview. Native spreadsheet payloads are not previews, even when they are large.
    static func isPreviewImage(_ type: String) -> Bool {
        if let uti = UTType(type), uti.conforms(to: .image) {
            return true
        }
        let lower = type.lowercased()
        if lower.contains("excel") || lower.contains("biff") || lower.contains("spreadsheet") {
            return false
        }
        return lower.contains("tiff") || lower.contains("png") || lower.contains("jpeg") || lower == "public.jpg"
    }

    /// Excel, Numbers, and WPS private types, plus TSV/CSV and the link flavors Excel puts beside cells.
    static func isSpreadsheetNative(_ type: String) -> Bool {
        if isPreviewImage(type) || isPDF(type) || isStringType(type) || isHTMLType(type) || isRTFType(type) || isFileURLType(type) {
            return false
        }
        let lower = type.lowercased()
        if lower.contains("excel") || lower.contains("biff") { return true }
        if lower.contains("xml spreadsheet") || lower.contains("spreadsheetml") || lower.contains("xmlss") { return true }
        if lower.contains("iwork") || lower.contains("tspnative") || lower.contains("numbers") { return true }
        if lower.contains("kingsoft") || lower.contains("wps") || lower.contains("kspread") { return true }
        if lower.contains("tab-separated") { return true }
        if lower == "csv" || lower == "text/csv" || lower.hasSuffix(".csv") || lower.contains("comma-separated") {
            return true
        }
        if lower == "link" || lower == "objectlink" || lower == "object link" { return true }
        if lower.contains("embed source") || lower.contains("embedsource") { return true }
        if lower.contains("link source") || lower.contains("linksource") { return true }
        if lower.contains("object descriptor") || lower.contains("objectdescriptor") { return true }
        if lower.contains("ownerlink") || lower.contains("owner link") { return true }
        return false
    }

    static func representsTable(_ snapshot: ClipboardRepresentations.Snapshot) -> Bool {
        if snapshot.extraTypes.contains(where: { isSpreadsheetNative($0.type) }) { return true }
        guard let html = snapshot.htmlData, !html.isEmpty else { return false }
        guard let text = ClipboardCaptureDecision.decodeText(html) else { return false }
        return ClipboardHTMLText.isTabularDocument(text)
    }
}

/// Keeps spreadsheet copies whole. Preview images are the only bytes dropped, and only after the total passes the cap.
enum ClipboardPasteboardBudget {
    /// A formatted selection is often several megabytes once Excel's private types and a preview are combined.
    static let totalByteLimit = 64 * 1024 * 1024

    static func selecting(_ entries: [ClipboardPasteboardType], limit: Int = totalByteLimit) -> [ClipboardPasteboardType] {
        let nonempty = entries.filter { !$0.data.isEmpty }
        let total = nonempty.reduce(0) { $0 + $1.data.count }
        guard total > limit else { return nonempty }
        var dropped = Set<Int>()
        var size = total
        let images = nonempty.indices
            .filter { ClipboardPasteboardKinds.isPreviewImage(nonempty[$0].type) }
            .sorted { nonempty[$0].data.count > nonempty[$1].data.count }
        for index in images where size > limit {
            dropped.insert(index)
            size -= nonempty[index].data.count
        }
        return nonempty.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }
}

/// Pure pasteboard classification. `types` is a type identifier mapped to the bytes of that type.
enum ClipboardCaptureDecision {
    static func choose(types: [String: Data]) -> ClipboardCapture.Choice? {
        let string = plainString(in: types)
        let rtf = rtfPlainText(in: types)
        let html = htmlString(in: types)
        let tsv = tabSeparatedString(in: types)
        let spreadsheet = types.keys.contains(where: ClipboardPasteboardKinds.isSpreadsheetNative)
        let tabular = html.map(ClipboardHTMLText.isTabularDocument) ?? false
        let image = imageData(in: types)
        let imageFile = singleImageFileURL(in: types)

        if let imageFile {
            let keepImage = bestText(string: string, rtf: rtf, html: html, tsv: tsv) == nil
                || !(spreadsheet || tabular || (tsv.map(ClipboardCapture.isMeaningful) ?? false))
            if keepImage {
                return .image(.file(imageFile))
            }
        }

        if let html, ClipboardHTMLText.isImageOnlyDocument(html), let image {
            let independent = isIndependent(string, html: html)
                || isIndependent(rtf, html: html)
                || isIndependent(tsv, html: html)
            let spreadsheetText = spreadsheet && bestText(string: string, rtf: rtf, html: html, tsv: tsv) != nil
            if !independent && !spreadsheetText && !tabular {
                return .image(.data(image))
            }
        }

        if let text = bestText(string: string, rtf: rtf, html: html, tsv: tsv) {
            return .text(text)
        }

        if let fileText = fallbackFileText(in: types) {
            return .text(fileText)
        }

        if let image {
            return .image(.data(image))
        }
        return nil
    }

    static func choose(_ reading: ClipboardPasteboardReading) -> ClipboardCapture.Choice? {
        var types = typeMap(from: reading.entries)
        if !reading.fileURLs.isEmpty, fileURLs(in: types).count != reading.fileURLs.count {
            let paths = reading.fileURLs.map(\.path)
            if let data = try? PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0) {
                types[ClipboardRepresentations.filenamesType.rawValue] = data
            }
        }
        return choose(types: types)
    }

    /// Spreadsheet and Numbers copies keep every declared type so paste can replay them in order.
    /// An ordinary web copy keeps its string, RTF, and HTML, and leaves the preview image behind.
    static func preservedEntries(_ entries: [ClipboardPasteboardType]) -> [ClipboardPasteboardType] {
        guard shouldPreserve(entries) else { return [] }
        return ClipboardPasteboardBudget.selecting(entries)
    }

    static func shouldPreserve(_ entries: [ClipboardPasteboardType]) -> Bool {
        if entries.contains(where: { ClipboardPasteboardKinds.isSpreadsheetNative($0.type) }) { return true }
        if entries.contains(where: { ClipboardPasteboardKinds.tabSeparatedTypes.contains($0.type) }) { return true }
        // Numbers attaches a PDF of the selection next to a real table. A web table does not.
        let tabular = htmlString(in: typeMap(from: entries)).map(ClipboardHTMLText.isTabularDocument) ?? false
        return tabular && entries.contains { ClipboardPasteboardKinds.isPDF($0.type) }
    }

    static func typeMap(from entries: [ClipboardPasteboardType]) -> [String: Data] {
        var map: [String: Data] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries where map[entry.type] == nil && !entry.data.isEmpty {
            map[entry.type] = entry.data
        }
        return map
    }

    static func decodeText(_ data: Data, preferringUTF16: Bool = false) -> String? {
        let encodings: [String.Encoding] = preferringUTF16
            ? [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf8]
            : [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                let cleaned = string.replacingOccurrences(of: "\0", with: "")
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func bestText(string: String?, rtf: String?, html: String?, tsv: String?) -> String? {
        if let string, ClipboardCapture.isMeaningful(string) { return string }
        if let rtf, ClipboardCapture.isMeaningful(rtf) { return rtf }
        if let html {
            let plain = ClipboardHTMLText.plainText(from: html)
            if ClipboardCapture.isMeaningful(plain) { return plain }
        }
        if let tsv, ClipboardCapture.isMeaningful(tsv) { return tsv }
        return nil
    }

    /// Text that is not just the URL or file name of an image-only HTML document.
    private static func isIndependent(_ text: String?, html: String) -> Bool {
        guard let text, ClipboardCapture.isMeaningful(text) else { return false }
        guard ClipboardHTMLText.isImageOnlyDocument(html) else { return true }
        return !ClipboardHTMLText.matchesImageReference(text, html: html)
    }

    private static func plainString(in types: [String: Data]) -> String? {
        for name in ClipboardPasteboardKinds.stringTypes {
            guard let data = types[name] else { continue }
            let utf16 = name.contains("utf16")
            if let text = decodeText(data, preferringUTF16: utf16) { return text }
        }
        return nil
    }

    private static func tabSeparatedString(in types: [String: Data]) -> String? {
        for name in ClipboardPasteboardKinds.tabSeparatedTypes {
            guard let data = types[name] else { continue }
            if let text = decodeText(data, preferringUTF16: name.contains("utf16")) { return text }
        }
        return nil
    }

    private static func htmlString(in types: [String: Data]) -> String? {
        for name in ClipboardPasteboardKinds.htmlTypes {
            guard let data = types[name], let text = decodeText(data) else { continue }
            return text
        }
        return nil
    }

    private static func rtfPlainText(in types: [String: Data]) -> String? {
        for name in ClipboardPasteboardKinds.rtfTypes {
            guard let data = types[name], !data.isEmpty else { continue }
            let text = name == "public.rtfd"
                ? NSAttributedString(rtfd: data, documentAttributes: nil)?.string
                : NSAttributedString(rtf: data, documentAttributes: nil)?.string
            if let text, ClipboardCapture.isMeaningful(text) { return text }
        }
        return nil
    }

    private static func imageData(in types: [String: Data]) -> Data? {
        var seen = Set(ClipboardPasteboardKinds.imagePreference)
        for name in ClipboardPasteboardKinds.imagePreference {
            if let data = types[name], !data.isEmpty { return data }
        }
        for (name, data) in types where !seen.contains(name) && !data.isEmpty && ClipboardPasteboardKinds.isPreviewImage(name) {
            seen.insert(name)
            return data
        }
        return nil
    }

    static func fileURLs(in types: [String: Data]) -> [URL] {
        let fromPlist = filenamePaths(in: types).map { URL(fileURLWithPath: $0) }
        var fromURL: [URL] = []
        for name in ["public.file-url", "CorePasteboardFlavorType 0x6675726C"] {
            guard let data = types[name], let string = decodeText(data) else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.isFileURL {
                fromURL.append(url)
            }
        }
        let chosen = fromPlist.count >= fromURL.count && !fromPlist.isEmpty ? fromPlist : fromURL
        var seen = Set<String>()
        return chosen.filter { url in
            seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted
        }
    }

    private static func singleImageFileURL(in types: [String: Data]) -> URL? {
        let urls = fileURLs(in: types)
        guard urls.count == 1, let url = urls.first else { return nil }
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        return url
    }

    private static func fallbackFileText(in types: [String: Data]) -> String? {
        let urls = fileURLs(in: types)
        guard !urls.isEmpty else { return nil }
        if urls.count == 1,
           let type = UTType(filenameExtension: urls[0].pathExtension),
           type.conforms(to: .image) {
            return nil
        }
        let text = urls.map(\.path).joined(separator: "\n")
        return ClipboardCapture.isMeaningful(text) ? text : nil
    }

    private static func filenamePaths(in types: [String: Data]) -> [String] {
        guard let data = types["NSFilenamesPboardType"],
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let paths = object as? [String] else {
            return []
        }
        return paths
    }
}

extension ClipboardPasteboardReading {
    /// Forces every declared type to render. Excel's private types are often promised and disappear if only the type list is saved.
    static func read(from pasteboard: NSPasteboard) -> ClipboardPasteboardReading {
        var entries: [ClipboardPasteboardType] = []
        var seen = Set<String>()
        // `pasteboard.types` keeps legacy names (`Biff8`, `Embed Source`) that a pasteboard item hides behind `dyn.` aliases.
        for type in pasteboard.types ?? [] {
            append(type.rawValue, data: pasteboard.data(forType: type), to: &entries, seen: &seen)
        }
        if entries.isEmpty {
            for item in pasteboard.pasteboardItems ?? [] {
                for type in item.types {
                    append(type.rawValue, data: item.data(forType: type) ?? item.string(forType: type).map { Data($0.utf8) }, to: &entries, seen: &seen)
                }
            }
        }
        return ClipboardPasteboardReading(entries: entries, fileURLs: ClipboardRepresentations.fileURLs(on: pasteboard))
    }

    private static func append(
        _ type: String,
        data: Data?,
        to entries: inout [ClipboardPasteboardType],
        seen: inout Set<String>
    ) {
        guard seen.insert(type).inserted, let data, !data.isEmpty else { return }
        entries.append(ClipboardPasteboardType(type: type, data: data))
    }
}
