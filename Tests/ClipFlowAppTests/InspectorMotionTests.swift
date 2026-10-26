import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class InspectorTestContext {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "InspectorMotion.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: ClipFlowStore
    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    func text(_ text: String = "A plain fixture") throws -> ClipboardItem {
        store.ingestCopiedText(text, sourceApp: "Test", sourceBundleID: nil)
        return try XCTUnwrap(store.items.first)
    }
    func image(width: Int = 100, height: Int = 300) throws -> ClipboardItem {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        store.ingestCopiedImage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            size: CGSize(width: width, height: height), sourceApp: "Test", sourceBundleID: nil)
        return try XCTUnwrap(store.items.first)
    }
    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
    static func settle(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor
final class InspectorMotionTests: XCTestCase {
    func testMotionEndpointsAndReducedMotion() {
        let open = InspectorMotionValues.resolve(progress: 1, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(open.shellScaleY, 1)
        XCTAssertEqual(open.shellOffsetY, 0)
        XCTAssertEqual(open.contentOpacity, 1)
        let closed = InspectorMotionValues.resolve(progress: 0, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(closed.contentOpacity, 0)
        XCTAssertEqual(closed.shellScaleY, 0.9, accuracy: 0.001)
        for value in stride(from: 0.0, through: 1, by: 0.1) {
            let frame = InspectorMotionValues.resolve(progress: CGFloat(value), reduceMotion: true, reduceTransparency: true)
            XCTAssertEqual(frame.shellScaleY, 1)
            XCTAssertEqual(frame.shellOffsetY, 0)
            XCTAssertEqual(frame.contentOffsetY, 0)
            XCTAssertEqual(frame.backgroundBlur, 0)
        }
    }
    func testClampedFiniteProgressAndContinuousReversal() {
        for value: CGFloat in [-1, 0, 0.18, 0.45, 1, 2, .nan, .infinity] {
            let frame = InspectorMotionValues.resolve(progress: value, reduceMotion: false, reduceTransparency: false)
            XCTAssertTrue(frame.shellScaleY.isFinite && frame.contentOpacity.isFinite)
            XCTAssertTrue((0...1).contains(frame.contentOpacity))
        }
        let a = InspectorMotionValues.resolve(progress: 0.45, reduceMotion: false, reduceTransparency: false)
        let b = InspectorMotionValues.resolve(progress: 0.45, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(a, b)
    }
    func testNativeDriverCompletesAndCancelDoesNotComplete() {
        let driver = AppKitInspectorAnimationDriver()
        var completed = false
        var last: CGFloat = 0
        driver.animate(from: 0, to: 1, duration: 0.04, update: { last = $0 }, completion: { completed = true })
        InspectorTestContext.settle(until: { completed })
        XCTAssertTrue(completed)
        XCTAssertEqual(last, 1, accuracy: 0.001)
        completed = false
        driver.animate(from: 1, to: 0, duration: 0.04, update: { last = $0 }, completion: { completed = true })
        driver.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertFalse(completed)
    }

    func testTicksPreserveRendererAndCanvasIdentity() throws {
        _ = NSApplication.shared
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for item in [try context.text("func example() {\n    print(\"hello\")\n}"), try context.image()] {
            let progress = InspectorMotionProgress(value: 0)
            let host = NSHostingController(rootView: LibraryInspectorOverlay(item: item, store: context.store,
                palette: .resolve(for: .light), maxHeight: 560, motion: progress, onClose: {}))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 438, height: 600))
            window.orderFront(nil)
            defer { window.close() }
            host.view.layoutSubtreeIfNeeded()
            InspectorTestContext.settle(until: {
                item.isImage ? InspectorTestContext.descendants(host.view, DetailImageCanvas.self).first?.isImageReady == true
                    : InspectorTestContext.descendants(host.view, WKWebView.self).first?.isLoading == false
            })
            let web = InspectorTestContext.descendants(host.view, WKWebView.self).first
            let canvas = InspectorTestContext.descendants(host.view, DetailImageCanvas.self).first
            let delegate = web?.navigationDelegate
            let key = (delegate as? DetailTextRenderer.Coordinator)?.key
            for value in [CGFloat(0.2), 0.5, 0.8, 1, 0.5, 0.1] {
                progress.setValue(value)
                host.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                XCTAssertTrue(InspectorTestContext.descendants(host.view, WKWebView.self).first === web)
                XCTAssertTrue(InspectorTestContext.descendants(host.view, DetailImageCanvas.self).first === canvas)
                if let web {
                    XCTAssertTrue(web.navigationDelegate === delegate)
                    XCTAssertEqual((web.navigationDelegate as? DetailTextRenderer.Coordinator)?.key, key)
                }
            }
            if item.isImage { XCTAssertNotNil(canvas); XCTAssertTrue(canvas?.isImageReady == true) }
            else { XCTAssertNotNil(web) }
        }
    }
}
