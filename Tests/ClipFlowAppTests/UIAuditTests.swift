import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class UIAuditTests: XCTestCase {
    func testClearHistoryConfirmationNamesTheUnpinnedCount() {
        XCTAssertEqual(ClearHistoryConfirmation.message(unpinnedCount: 12), "清空未置顶的 12 条，置顶保留")
        XCTAssertFalse(ClearHistoryConfirmation.canRequest(unpinnedCount: 0))
        XCTAssertTrue(ClearHistoryConfirmation.canRequest(unpinnedCount: 3))
    }

    func testHistoryPasteIndexUsesTheVisibleRow() {
        let items = (0..<4).map { index in
            ClipboardClassifier.makeItem(text: "Row \(index)", sourceApp: "Test", sourceBundleID: nil,
                autoProtectSecrets: false, existingItem: nil)
        }
        XCTAssertEqual(HistoryPasteRouting.item(at: 0, in: items)?.fullText, "Row 0")
        XCTAssertEqual(HistoryPasteRouting.item(at: 3, in: items)?.fullText, "Row 3")
        XCTAssertNil(HistoryPasteRouting.item(at: 9, in: items))
        XCTAssertNil(HistoryPasteRouting.item(at: -1, in: items))
    }

    func testCardSummaryUsesThePlainFirstLine() {
        let markdown = "# 项目笔记\n\n## 本周安排\n- 完成界面调整\n**所有记录，随时找回。**"
        XCTAssertEqual(ClipboardCardSummary.plainFirstLine(of: markdown), "项目笔记")
        XCTAssertEqual(ClipboardCardSummary.plainFirstLine(of: "第一行\n第二行"), "第一行")
        XCTAssertEqual(ClipboardCardSummary.plainFirstLine(of: "- 清单项\n更多"), "清单项")
    }

    func testThumbnailWidthTracksAspectAndCapsAt160() {
        XCTAssertEqual(LibraryImageThumbnail.height, 72)
        XCTAssertEqual(LibraryImageThumbnail.width(imageWidth: 720, imageHeight: 400), 129.6, accuracy: 0.1)
        XCTAssertEqual(LibraryImageThumbnail.width(imageWidth: 1600, imageHeight: 200), 160, accuracy: 0.1)
        XCTAssertEqual(LibraryImageThumbnail.width(imageWidth: nil, imageHeight: nil), 72)
    }

    func testLightCommentColorClearsWhite() throws {
        let html = DetailTextDocument.html(text: "// note", markdown: false, language: "swift", dark: false)
        XCTAssertTrue(html.contains("#5C6B7A"))
        XCTAssertFalse(html.contains("#7b8796"))
        let comment = try XCTUnwrap(NSColor(srgbRed: 0x5C / 255.0, green: 0x6B / 255.0, blue: 0x7A / 255.0, alpha: 1)
            .usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(contrast(comment, NSColor.white), 4.5)
    }

    func testSolidInksAndSecondaryTextClearTheirBackgrounds() throws {
        let cream = try XCTUnwrap(NSColor(srgbRed: 247.0 / 255, green: 246.0 / 255, blue: 244.0 / 255, alpha: 1).usingColorSpace(.sRGB))
        let secondary = try components(ClipFlowPalette.secondaryText(for: .light))
        XCTAssertEqual(secondary.redComponent, 92.0 / 255, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(contrast(secondary, cream), 4.5)

        let listening = try components(ClipFlowPalette.listeningStatus)
        XCTAssertGreaterThanOrEqual(contrast(listening, cream), 4.5)
        let paused = try components(ClipFlowPalette.pausedStatus)
        XCTAssertGreaterThanOrEqual(contrast(paused, cream), 4.5)

        for category in ClipCategory.allCases {
            let solid = try components(category.solid)
            XCTAssertGreaterThanOrEqual(contrast(solid, NSColor.white), 4.5, category.title)
        }
        let brand = try components(ClipCategory.all.solid)
        XCTAssertEqual(brand.redComponent, 0.15, accuracy: 0.01)
        XCTAssertEqual(brand.greenComponent, 0.40, accuracy: 0.01)
        XCTAssertEqual(brand.blueComponent, 0.78, accuracy: 0.01)
        XCTAssertEqual(ClipFlowLayout.controlRadius, 10)
        XCTAssertEqual(ClipFlowLayout.rowRadius, 14)
        XCTAssertEqual(ClipFlowLayout.overlayRadius, 22)
        XCTAssertEqual(ClipFlowLayout.libraryMinHeight, 560)
        XCTAssertEqual(ClipFlowMotion.pressScale, 0.98, accuracy: 0.001)
        XCTAssertEqual(ClipFlowMotion.inspectorOpen, 0.28, accuracy: 0.001)
        XCTAssertEqual(ClipFlowMotion.inspectorClose, 0.20, accuracy: 0.001)
    }

    func testFilterFadesOnlyWhenTheRowOverflows() {
        let fitted = FilterEdgeFade.resolve(offset: 0, contentWidth: 400, viewportWidth: 454, depth: 12)
        XCTAssertEqual(fitted.leading, 0)
        XCTAssertEqual(fitted.trailing, 0)
        let overflow = FilterEdgeFade.resolve(offset: 0, contentWidth: 498, viewportWidth: 454, depth: 12)
        XCTAssertEqual(overflow.leading, 0)
        XCTAssertEqual(overflow.trailing, 1)
        let mid = FilterEdgeFade.resolve(offset: 6, contentWidth: 498, viewportWidth: 454, depth: 12)
        XCTAssertEqual(mid.leading, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(mid.trailing, 0)
    }

    func testShellTransformStartsOnTheSourceCard() {
        let destination = CGRect(x: 100, y: 100, width: 340, height: 576)
        let source = CGRect(x: 110, y: 340, width: 320, height: 136)
        let closed = InspectorShellTransform.resolve(progress: 0, sourceRectInWindow: source,
            destinationRectInWindow: destination, reduceMotion: false)
        let visual = closed.visualRect(in: CGRect(x: 0, y: 0, width: 340, height: 576))
        XCTAssertEqual(visual.origin.x, 10, accuracy: 0.6)
        XCTAssertEqual(visual.origin.y, 200, accuracy: 0.6)
        XCTAssertEqual(visual.width, 320, accuracy: 0.6)
        XCTAssertEqual(visual.height, 136, accuracy: 0.6)
        let opened = InspectorShellTransform.resolve(progress: 1, sourceRectInWindow: source,
            destinationRectInWindow: destination, reduceMotion: false)
        XCTAssertEqual(opened.scaleX, 1, accuracy: 0.001)
        XCTAssertEqual(opened.scaleY, 1, accuracy: 0.001)
        XCTAssertEqual(opened.offset, .zero)
        let reduced = InspectorShellTransform.resolve(progress: 0.2, sourceRectInWindow: source,
            destinationRectInWindow: destination, reduceMotion: true)
        XCTAssertEqual(reduced.scaleX, 1)
        XCTAssertEqual(reduced.offset, .zero)
    }

    private func components(_ color: Color) throws -> NSColor {
        try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: NSColor) -> CGFloat {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent) + 0.0722 * channel(srgb.blueComponent)
        }
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
