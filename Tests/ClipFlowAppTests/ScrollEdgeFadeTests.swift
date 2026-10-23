import XCTest
import SwiftUI
import AppKit
@testable import ClipFlowApp

final class ScrollEdgeFadeTests: XCTestCase {
    func testShortContentHasNoFade() {
        let fade = ScrollEdgeFade(content: CGRect(x: 0, y: 0, width: 400, height: 200), viewportHeight: 600)
        XCTAssertEqual(fade.top, 0)
        XCTAssertEqual(fade.bottom, 0)
    }
    func testEndsRemainReadableAndMiddleFadesBothEdges() {
        let top = ScrollEdgeFade(content: CGRect(x: 0, y: 0, width: 400, height: 1000), viewportHeight: 600)
        XCTAssertEqual(top.top, 0)
        XCTAssertEqual(top.bottom, 1)
        let middle = ScrollEdgeFade(content: CGRect(x: 0, y: -200, width: 400, height: 1000), viewportHeight: 600)
        XCTAssertEqual(middle.top, 1)
        XCTAssertEqual(middle.bottom, 1)
        let bottom = ScrollEdgeFade(content: CGRect(x: 0, y: -400, width: 400, height: 1000), viewportHeight: 600)
        XCTAssertEqual(bottom.top, 1)
        XCTAssertEqual(bottom.bottom, 0)
    }
    func testFadeTracksDistanceWithoutOverscrollOverflow() {
        let fade = ScrollEdgeFade(content: CGRect(x: 0, y: -12, width: 400, height: 1000), viewportHeight: 600)
        XCTAssertEqual(fade.top, 0.5)
        let bounce = ScrollEdgeFade(content: CGRect(x: 0, y: 20, width: 400, height: 1000), viewportHeight: 600)
        XCTAssertEqual(bounce.top, 0)
        XCTAssertEqual(bounce.bottom, 1)
    }
}

@MainActor
final class ScrollHostTests: XCTestCase {
    func testLiveScrollViewHasNoReservedScrollbarTrack() throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: SoftEdgeScrollView {
            VStack { ForEach(0..<30) { Text("Row \($0)").frame(height: 40) } }
        })
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 400))
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        func visit(_ v: NSView, depth: Int = 0) -> [NSScrollView] {
            return (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap { visit($0, depth: depth + 1) }
        }
        let scroll = try XCTUnwrap(visit(host.view).first)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertEqual(scroll.contentView.frame.width, scroll.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentView.bounds.height)
    }
}
