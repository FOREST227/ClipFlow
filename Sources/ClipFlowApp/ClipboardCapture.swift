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

/// Decides whether a pasteboard change is text or an image.
///
/// Web pages often attach a rendered preview beside the copied string, RTF, or HTML.
/// That preview is not the copy. An image is recorded when there is no meaningful
/// text, or when the pasteboard is an image file or an image-only document such as
/// a copied picture.
final class ClipboardCapture {
    enum Choice: Equatable {
        case text(String)
        case image(ClipboardImageEncoder.Source)
    }

    static func choose(from pasteboard: NSPasteboard) -> Choice? {
        if let fileURL = singleImageFileURL(on: pasteboard) {
            return .image(.file(fileURL))
        }

        if let html = htmlString(on: pasteboard),
           ClipboardHTMLText.isImageOnlyDocument(html),
           let image = imageData(on: pasteboard) {
            return .image(.data(image))
        }

        if let text = meaningfulText(on: pasteboard) {
            return .text(text)
        }

        if let image = imageData(on: pasteboard) {
            return .image(.data(image))
        }

        return nil
    }

    static func isMeaningful(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
    }

    private static func meaningfulText(on pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string), isMeaningful(string) {
            return string
        }

        for type in rtfTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            let text = type == .rtfd
                ? NSAttributedString(rtfd: data, documentAttributes: nil)?.string
                : NSAttributedString(rtf: data, documentAttributes: nil)?.string
            if let text, isMeaningful(text) {
                return text
            }
        }

        if let html = htmlString(on: pasteboard) {
            let text = ClipboardHTMLText.plainText(from: html)
            if isMeaningful(text) {
                return text
            }
        }

        return nil
    }

    private static func htmlString(on pasteboard: NSPasteboard) -> String? {
        for type in htmlTypes {
            if let string = pasteboard.string(forType: type), !string.isEmpty {
                return string
            }
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            if let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                return string
            }
        }
        return nil
    }

    private static func singleImageFileURL(on pasteboard: NSPasteboard) -> URL? {
        guard let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
              fileURLs.count == 1,
              let fileURL = fileURLs.first,
              let type = UTType(filenameExtension: fileURL.pathExtension),
              type.conforms(to: .image) else {
            return nil
        }
        return fileURL
    }

    private static func imageData(on pasteboard: NSPasteboard) -> Data? {
        let preferred: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            .tiff,
            NSPasteboard.PasteboardType(UTType.webP.identifier),
            NSPasteboard.PasteboardType(UTType.bmp.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier)
        ]

        var seen = Set(preferred.map(\.rawValue))
        for type in preferred {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return data
            }
        }

        for type in pasteboard.types ?? [] where !seen.contains(type.rawValue) {
            seen.insert(type.rawValue)
            guard let uti = UTType(type.rawValue), uti.conforms(to: .image) else { continue }
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return data
            }
        }

        return nil
    }

    private static let rtfTypes: [NSPasteboard.PasteboardType] = [
        .rtf,
        NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type"),
        .rtfd
    ]

    private static let htmlTypes: [NSPasteboard.PasteboardType] = [
        .html,
        NSPasteboard.PasteboardType("Apple HTML pasteboard type")
    ]

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
