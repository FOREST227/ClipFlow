import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class QuickPasteScrollTests: XCTestCase {
    func testFirstClickBelowFirstScreenKeepsRowAndSecondClickPastesIt() throws {
        try verifyScrolledSelection(includeImages: false)
    }

    func testMixedImageCodeAndTextKeepScrolledDoubleClickTarget() throws {
        try verifyScrolledSelection(includeImages: true)
    }

    private func verifyScrolledSelection(includeImages: Bool) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "QuickPasteScroll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 500,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for index in 0..<50 {
            if includeImages && index % 3 == 0 {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(index) / 50, green: 0.5, blue: 0.6, alpha: 1),
                    atX: 0, y: 0)
                store.ingestCopiedImage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    size: CGSize(width: 300, height: 500), sourceApp: "Test", sourceBundleID: nil)
            } else {
                let text = index % 2 == 0 ? "Note \(index)" : "func example\(index)() {\n    return true\n}"
                store.ingestCopiedText(text, sourceApp: "Test", sourceBundleID: nil)
            }
        }
        var pasted: [UUID] = []
        var closes = 0
        let host = NSHostingController(rootView: QuickPastePanelView(store: store,
            preferredTargetName: nil, onPaste: { pasted.append($0.id) }, onOpenLibrary: {},
            onClose: { closes += 1 }))
        let window = QuickPastePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 588),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        settle()
        let scroll = try XCTUnwrap(descendants(host.view, NSScrollView.self).first)
        for (step, offset) in [CGFloat(700), 1500, 2400].enumerated() {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
            let before = scroll.contentView.bounds.minY
            XCTAssertGreaterThan(before, 424)
            let rows = descendants(host.view, HUDInteractiveHostingView.self)
            let row = try XCTUnwrap(rows.first {
                scroll.contentView.bounds.insetBy(dx: 0, dy: 12).contains($0.convert($0.bounds, to: scroll.contentView))
            })
            let id = try XCTUnwrap(row.representedItemID)
            let revisions = Dictionary(uniqueKeysWithValues: rows.map { (ObjectIdentifier($0), $0.contentRevision) })
            func event(_ count: Int) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
                    modifierFlags: [], timestamp: 10 + Double(step) + Double(count) * 0.05,
                    windowNumber: window.windowNumber, context: nil, eventNumber: count,
                    clickCount: count, pressure: 1))
            }
            let previousPasteCount = pasted.count
            let root = try XCTUnwrap(window.contentView)
            let location = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let point = root.superview.map { $0.convert(location, from: nil) } ?? location
            XCTAssertTrue(root.hitTest(point) === row, "Native hit testing must identify the visible row")
            window.sendEvent(try event(1))
            settle()
            XCTAssertEqual(pasted.count, previousPasteCount, "First click only selects")
            XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 1)
            XCTAssertEqual(row.representedItemID, id)
            XCTAssertNotNil(row.window, "The clicked row must survive selection")
            for existing in descendants(host.view, HUDInteractiveHostingView.self) {
                if let old = revisions[ObjectIdentifier(existing)] {
                    XCTAssertEqual(existing.contentRevision, old,
                        "Selection must not replace hosted row content and invalidate lazy scroll geometry")
                }
            }
            window.sendEvent(try event(2))
            settle()
            XCTAssertEqual(pasted.last, id)
            XCTAssertEqual(pasted.count, previousPasteCount + 1)
            XCTAssertEqual(closes, pasted.count)
        }
    }
}
