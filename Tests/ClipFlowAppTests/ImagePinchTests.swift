import AppKit
import XCTest
import SwiftUI
@testable import ClipFlowApp

@MainActor
final class ImagePinchTests: XCTestCase {
    func testQuickPasteImageInspectorMountsZoomCanvas() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HUDPinch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        store.ingestCopiedImage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            size: CGSize(width: 32, height: 32), sourceApp: "Test", sourceBundleID: nil)
        let item = try XCTUnwrap(store.items.first)
        let host = NSHostingController(rootView: HUDInspectorOverlay(item: item, store: store,
            onClose: {}, onPaste: {}).frame(width: 360, height: 588))
        let window = QuickPastePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 588),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> DetailImageCanvas? {
            if let canvas = view as? DetailImageCanvas { return canvas }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        for _ in 0..<100 {
            if find(host.view)?.isImageReady == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let canvas = try XCTUnwrap(find(host.view))
        XCTAssertTrue(canvas.isImageReady)
        XCTAssertGreaterThan(canvas.bounds.height, 0)
        XCTAssertTrue(canvas.isPinchMonitorInstalled)
        let point = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        let event = TestMagnifyEvent(number: window.windowNumber, point: point, amount: 0.5)
        XCTAssertTrue(canvas.handleMagnifyEvent(event))
        XCTAssertEqual(canvas.viewport.zoom, 1.5, accuracy: 0.001)
        XCTAssertFalse(canvas.handleMagnifyEvent(TestMagnifyEvent(number: window.windowNumber + 1,
            point: point, amount: 1)))
        XCTAssertFalse(canvas.handleMagnifyEvent(TestMagnifyEvent(number: window.windowNumber,
            point: CGPoint(x: -1000, y: -1000), amount: 1)))
        XCTAssertEqual(canvas.viewport.zoom, 1.5, accuracy: 0.001)
        canvas.cancelLoading()
        XCTAssertFalse(canvas.isPinchMonitorInstalled)
    }

    func testSwiftUIPinchBridgeHandlesCumulativeScaleAndSeparateGestures() async throws {
        _ = NSApplication.shared
        let canvas = DetailImageCanvas(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let pinch = DetailImagePinchBridge()
        pinch.canvas = canvas
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        defer { canvas.cancelLoading(); try? FileManager.default.removeItem(at: url) }
        canvas.load(url)
        for _ in 0..<100 {
            if canvas.isImageReady { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(canvas.isImageReady)
        pinch.update(totalScale: 1.5)
        XCTAssertEqual(canvas.viewport.zoom, 1.5, accuracy: 0.001)
        pinch.update(totalScale: 2)
        XCTAssertEqual(canvas.viewport.zoom, 2, accuracy: 0.001)
        pinch.update(totalScale: 2)
        XCTAssertEqual(canvas.viewport.zoom, 2, "Repeated cumulative values must not multiply again")
        pinch.end()
        pinch.update(totalScale: 0.5)
        XCTAssertEqual(canvas.viewport.zoom, 1, accuracy: 0.001)
        pinch.end()
        pinch.update(totalScale: 1.25)
        XCTAssertEqual(canvas.viewport.zoom, 1.25, accuracy: 0.001)
    }
}


private final class TestMagnifyEvent: NSEvent {
    private let number: Int
    private let point: NSPoint
    private let amount: CGFloat
    init(number: Int, point: NSPoint, amount: CGFloat) {
        self.number = number
        self.point = point
        self.amount = amount
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .magnify }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { amount }
}
