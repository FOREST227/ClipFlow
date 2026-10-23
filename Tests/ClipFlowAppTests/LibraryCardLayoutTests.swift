import XCTest
@testable import ClipFlowApp

final class LibraryCardLayoutTests: XCTestCase {
    func testSixUnitsFitTextImageAndMixedRowsIncludingGaps() {
        for (small, large, gap, viewport) in [
            (LibraryCardLayout.compactHeight, LibraryCardLayout.expandedHeight,
             LibraryCardLayout.spacing, LibraryCardLayout.viewportHeight),
            (QuickPasteCardLayout.compactHeight, QuickPasteCardLayout.expandedHeight,
             QuickPasteCardLayout.spacing, QuickPasteCardLayout.viewportHeight)
        ] {
            XCTAssertEqual(6 * small + 5 * gap, viewport)
            XCTAssertEqual(3 * large + 2 * gap, viewport)
            XCTAssertEqual(2 * large + 2 * small + 3 * gap, viewport)
        }
    }

    func testTallImageDetailsGrowButReserveSpaceForActions() {
        XCTAssertEqual(DetailImageLayout.previewHeight(shape: .portrait, availableHeight: 660, expandedInfo: false), 440)
        XCTAssertEqual(DetailImageLayout.previewHeight(shape: .portrait, availableHeight: 800, expandedInfo: false), 580)
        XCTAssertEqual(DetailImageLayout.previewHeight(shape: .portrait, availableHeight: 660, expandedInfo: true), 320)
        XCTAssertEqual(DetailImageLayout.previewHeight(shape: .landscape, availableHeight: 800, expandedInfo: false), 260)
        XCTAssertEqual(DetailImageLayout.previewHeight(shape: .square, availableHeight: 800, expandedInfo: false), 260)
    }

    func testQuickPasteUsesSmallerMatchingGrid() {
        XCTAssertEqual(QuickPasteCardLayout.height(for: .text), 64)
        XCTAssertEqual(QuickPasteCardLayout.height(for: .link), 64)
        XCTAssertEqual(QuickPasteCardLayout.height(for: .image), 136)
        XCTAssertEqual(QuickPasteCardLayout.height(for: .code), 136)
        XCTAssertEqual(QuickPasteCardLayout.height(for: .secret), 64)
        XCTAssertEqual(QuickPasteCardLayout.expandedHeight,
            2 * QuickPasteCardLayout.compactHeight + QuickPasteCardLayout.spacing)
    }

    func testTwoCompactCardsAndGapEqualOneExpandedCard() {
        XCTAssertEqual(LibraryCardLayout.height(for: .image), 2 * LibraryCardLayout.height(for: .text) + LibraryCardLayout.spacing)
        XCTAssertEqual(LibraryCardLayout.height(for: .code), LibraryCardLayout.height(for: .image))
        XCTAssertEqual(LibraryCardLayout.height(for: .link), LibraryCardLayout.height(for: .text))
        XCTAssertEqual(LibraryCardLayout.height(for: .secret), LibraryCardLayout.height(for: .text))
    }
    func testImageShapeKeepsNearSquaresTogether() {
        XCTAssertEqual(LibraryImageShape.resolve(width: 1200, height: 1000), .square)
        XCTAssertEqual(LibraryImageShape.resolve(width: 1000, height: 1200), .square)
        XCTAssertEqual(LibraryImageShape.resolve(width: 1600, height: 900), .landscape)
        XCTAssertEqual(LibraryImageShape.resolve(width: 900, height: 1600), .portrait)
        XCTAssertEqual(LibraryImageShape.resolve(width: 100, height: 8000), .portrait)
    }
    func testMissingOrInvalidDimensionsFallBackToSquare() {
        XCTAssertEqual(LibraryImageShape.resolve(width: nil, height: nil), .square)
        XCTAssertEqual(LibraryImageShape.resolve(width: 100, height: 0), .square)
        XCTAssertEqual(LibraryImageShape.resolve(width: .nan, height: 100), .square)
        XCTAssertEqual(LibraryImageShape.resolve(width: .infinity, height: 100), .square)
    }
}
