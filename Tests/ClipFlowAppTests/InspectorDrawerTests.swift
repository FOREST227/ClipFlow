import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class InspectorDrawerTests: XCTestCase {
    let destination = CGRect(x: 100, y: 100, width: 340, height: 576)
    let source = CGRect(x: 110, y: 340, width: 320, height: 136)

    func testShellReallyStartsAtSourceCardAndFinishesAtDrawer() {
        let closed = InspectorDrawerLayout.resolve(progress: 0, sourceRectInWindow: source,
            destinationRectInWindow: destination, footerHeight: 124, reduceMotion: false)
        XCTAssertEqual(closed.shellRect, CGRect(x: 10, y: 200, width: 320, height: 136))
        XCTAssertEqual(closed.coverTop, closed.shellRect.minY)
        let opened = InspectorDrawerLayout.resolve(progress: 1, sourceRectInWindow: source,
            destinationRectInWindow: destination, footerHeight: 124, reduceMotion: false)
        XCTAssertEqual(opened.shellRect, CGRect(x: 0, y: 0, width: 340, height: 576))
        XCTAssertEqual(opened.coverTop, 452)
        XCTAssertEqual(opened.coverHeight, 124)
    }
    func testForegroundCoverDescendsAndBodyAppearsLast() {
        var last: CGFloat = -1
        for p in stride(from: 0.0, through: 1, by: 0.1) {
            let frame = InspectorDrawerLayout.resolve(progress: CGFloat(p), sourceRectInWindow: source,
                destinationRectInWindow: destination, footerHeight: 124, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(frame.coverTop, last)
            XCTAssertGreaterThanOrEqual(frame.coverHeight, 0)
            last = frame.coverTop
        }
        XCTAssertEqual(InspectorMotionValues.resolve(progress: 0.5, reduceMotion: false,
            reduceTransparency: false).contentOpacity, 0)
        XCTAssertEqual(InspectorMotionValues.resolve(progress: 1, reduceMotion: false,
            reduceTransparency: false).contentOpacity, 1)
    }
    func testReducedMotionAndInvalidGeometryAreFinite() {
        for p: CGFloat in [0, 0.3, 0.8, 1] {
            let frame = InspectorDrawerLayout.resolve(progress: p, sourceRectInWindow: source,
                destinationRectInWindow: destination, footerHeight: 124, reduceMotion: true)
            XCTAssertEqual(frame.shellRect, CGRect(x: 0, y: 0, width: 340, height: 576))
            XCTAssertEqual(frame.coverTop, 452)
        }
        let frame = InspectorDrawerLayout.resolve(progress: .nan, sourceRectInWindow: .zero,
            destinationRectInWindow: .zero, footerHeight: 900, reduceMotion: false)
        XCTAssertTrue(frame.shellRect.width.isFinite && frame.coverTop.isFinite)
    }
    func testImageDetailBackgroundIsNativeWhite() throws {
        _ = NSApplication.shared
        let canvas = DetailImageCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200,
            pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { canvas.draw(canvas.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        let color = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.98)
        XCTAssertGreaterThan(color.greenComponent, 0.98)
        XCTAssertGreaterThan(color.blueComponent, 0.98)
    }

    func testAnchorUsesVisibleNativeRectAndRefreshesOnClose() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = root
        let row = NSView(frame: CGRect(x: 20, y: 200, width: 320, height: 136))
        root.addSubview(row)
        window.orderFront(nil)
        let anchor = InspectorSourceAnchor(view: row)
        let driver = ManualInspectorDriver()
        let presentation = InspectorPresentation(driver: driver)
        presentation.open(itemID: UUID(), reduceMotion: false, source: anchor)
        XCTAssertEqual(presentation.snapshot.sourceRectInWindow, row.convert(row.bounds, to: nil))
        driver.finishLatest()
        row.setFrameOrigin(CGPoint(x: 25, y: 250))
        presentation.dismiss(reduceMotion: false)
        XCTAssertEqual(presentation.snapshot.sourceRectInWindow, row.convert(row.bounds, to: nil))
        row.removeFromSuperview()
        XCTAssertNil(anchor.rectInWindow())
    }
    func testRightClickCapturesScrolledQuickPasteSourceWithoutMovingIt() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<30 { _ = try context.text("Drawer source \(n)") }
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        let scroll = try XCTUnwrap(fixture.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 800))
        scroll.reflectScrolledClipView(scroll.contentView); fixture.pump()
        let row = try XCTUnwrap(fixture.rows.first {
            scroll.contentView.bounds.contains($0.convert($0.bounds, to: scroll.contentView))
        })
        let rect = row.convert(row.bounds, to: nil)
        let offset = scroll.contentView.bounds.origin
        row.rightMouseDown(with: try fixture.event(on: row)); fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.sourceRectInWindow, rect)
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
    }
    func testAnchoredCallbackRejectsDetachedSource() {
        let row = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 72))
        var calls = 0
        let callback = InspectorSourceAnchor.callback(for: row, fallback: { calls += 100 },
            anchored: { _ in calls += 1 })
        callback()
        XCTAssertEqual(calls, 0, "A retained callback must not open from an invisible or detached row")
    }

    func testRightClickCapturesHistorySource() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        _ = try context.text()
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.rows.first)
        row.rightMouseDown(with: try fixture.event(on: row)); fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.sourceRectInWindow, row.convert(row.bounds, to: nil))
    }
}
