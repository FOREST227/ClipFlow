import XCTest
@testable import ClipFlowApp

final class ImageViewportTests: XCTestCase {
    func testZoomKeepsPointUnderPointerFixed() {
        var state = ImageViewport()
        state.scale(by: 2, anchor: CGPoint(x: 150, y: 100),
                    viewport: CGSize(width: 200, height: 200), fitted: CGSize(width: 200, height: 200))
        XCTAssertEqual(state.zoom, 2)
        XCTAssertEqual(state.offset.x, -50)
        XCTAssertEqual(state.offset.y, 0)
        state.scale(by: 0.5, anchor: CGPoint(x: 150, y: 100),
                    viewport: CGSize(width: 200, height: 200), fitted: CGSize(width: 200, height: 200))
        XCTAssertEqual(state.zoom, 1)
        XCTAssertEqual(state.offset, .zero)
    }
    func testZoomLimitsAndReset() {
        var state = ImageViewport()
        state.scale(by: 1000, anchor: .zero, viewport: CGSize(width: 200, height: 200),
                    fitted: CGSize(width: 200, height: 200))
        XCTAssertEqual(state.zoom, 12)
        state.reset()
        XCTAssertEqual(state.zoom, 1)
        XCTAssertEqual(state.offset, .zero)
        state.scale(by: 0.1, anchor: .zero, viewport: .zero, fitted: .zero)
        XCTAssertEqual(state.zoom, 1)
    }
    func testPanAndResizeKeepImageWithinReach() {
        var state = ImageViewport(zoom: 2, offset: CGPoint(x: 999, y: -999))
        state.clamp(viewport: CGSize(width: 300, height: 200), fitted: CGSize(width: 100, height: 200))
        XCTAssertEqual(state.offset.x, 0)
        XCTAssertEqual(state.offset.y, -100)
        state.clamp(viewport: CGSize(width: 500, height: 500), fitted: CGSize(width: 100, height: 200))
        XCTAssertEqual(state.offset, .zero)
    }
    func testInvalidGestureScaleIsIgnored() {
        var state = ImageViewport()
        for factor: CGFloat in [.nan, .infinity, -1, 0] {
            state.scale(by: factor, anchor: .zero, viewport: .zero, fitted: .zero)
            XCTAssertEqual(state.zoom, 1)
            XCTAssertEqual(state.offset, .zero)
        }
    }
}
