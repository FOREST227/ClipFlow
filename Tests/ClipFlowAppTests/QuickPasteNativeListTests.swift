import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class QuickPasteNativeListTests: XCTestCase {
    private final class RehittingRoot: NSView {
        var rehit: (() -> NSView?)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let rehit { return rehit() }
            return super.hitTest(point)
        }
    }
    func testNativeRecipientMustNotBeRetargetedByHostingRehitDuringScroll() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<50 { _ = try context.text("Native target \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let root = RehittingRoot(frame: f.host.view.bounds)
        let hosted = f.host.view
        f.window.contentView = root
        hosted.frame = root.bounds
        root.addSubview(hosted)
        f.pump()
        let scroll = try XCTUnwrap(f.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1008))
        scroll.reflectScrolledClipView(scroll.contentView)
        f.pump()
        let intended = try XCTUnwrap(f.rows.first {
            scroll.contentView.bounds.insetBy(dx: 0, dy: 1).contains($0.convert($0.bounds, to: scroll.contentView))
        })
        let wanted = try XCTUnwrap(intended.representedItemID)
        let firstID = try XCTUnwrap(context.store.hudItems(matching: "").first?.id)
        XCTAssertNotEqual(wanted, firstID)
        let before = scroll.contentView.bounds.minY
        let point = intended.convert(CGPoint(x: 100, y: intended.bounds.midY), to: nil)
        // Model the hosting hit-test's own pending viewport update, not an explicit layout call.
        root.rehit = {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            f.host.view.layoutSubtreeIfNeeded()
            return f.rows.first { $0.representedItemID == firstID }
        }
        for count in 1...2 {
            intended.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: point, modifierFlags: [], timestamp: 10 + Double(count) * 0.05,
                windowNumber: f.window.windowNumber, context: nil, eventNumber: count,
                clickCount: count, pressure: 1)))
        }
        print("HOST_REHIT viewport", before, "->", scroll.contentView.bounds.minY,
            "pastedWanted", f.probe.pasted == [wanted], "pastedFirst", f.probe.pasted == [firstID])
        XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 0.5)
        XCTAssertEqual(f.probe.pasted, [wanted])
    }

    func testPinningOffscreenItemKeepsVisibleNeighbourAtSamePosition() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<50 { _ = try context.text("Anchor \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let scroll = try XCTUnwrap(f.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1008))
        scroll.reflectScrolledClipView(scroll.contentView); f.pump()
        let visible = f.rows.filter {
            scroll.contentView.bounds.insetBy(dx: 0, dy: 1).contains($0.convert($0.bounds, to: scroll.contentView))
        }.sorted { $0.convert($0.bounds, to: scroll.contentView).minY < $1.convert($1.bounds, to: scroll.contentView).minY }
        let anchor = try XCTUnwrap(visible.dropFirst().first)
        let id = try XCTUnwrap(anchor.representedItemID)
        let y = anchor.convert(anchor.bounds, to: nil).minY
        let pin = context.store.hudItems(matching: "")[35]
        context.store.togglePin(pin.id); f.pump()
        let after = try XCTUnwrap(f.rows.first { $0.representedItemID == id })
        print("PIN_ANCHOR delta", after.convert(after.bounds, to: nil).minY - y)
        XCTAssertEqual(after.convert(after.bounds, to: nil).minY, y, accuracy: 0.5,
            "Pinning an offscreen item must not move the visible cards under the pointer")
    }
    func testRecapturingVisibleItemKeepsUnchangedNeighbourAnchored() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<50 { _ = try context.text("Recapture \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let scroll = try XCTUnwrap(f.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1008))
        scroll.reflectScrolledClipView(scroll.contentView); f.pump()
        let rows = f.rows.filter { $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds) }
            .sorted { $0.convert($0.bounds, to: scroll.contentView).minY < $1.convert($1.bounds, to: scroll.contentView).minY }
        let changed = try XCTUnwrap(rows.first?.representedItemID)
        let neighbour = try XCTUnwrap(rows.dropFirst().first)
        let stableID = try XCTUnwrap(neighbour.representedItemID)
        let y = neighbour.convert(neighbour.bounds, to: nil).minY
        context.store.ingestCopiedText(try XCTUnwrap(context.store.item(withID: changed)).fullText,
            sourceApp: "Test", sourceBundleID: nil)
        f.pump()
        let after = try XCTUnwrap(f.rows.first { $0.representedItemID == stableID })
        XCTAssertEqual(after.convert(after.bounds, to: nil).minY, y, accuracy: 0.5)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500)
    }

    func testRevealConcealRefreshesOnlyContentWithoutMovingRow() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        context.store.ingestCopiedText("FixturePrivateNote", sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords")
        let item = try XCTUnwrap(context.store.items.first)
        XCTAssertTrue(item.isSensitive)
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let row = try XCTUnwrap(f.rows.first)
        let frame = row.convert(row.bounds, to: nil)
        // Exclude the initial selection animation from the text-only comparison.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func pixels() throws -> Data {
            f.pump()
            let region = CGRect(x: 12, y: 14, width: 200, height: 24)
            let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: region))
            row.cacheDisplay(in: region, to: bitmap)
            return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let hidden = try pixels()
        context.store.toggleReveal(item.id)
        let revealed = try pixels()
        XCTAssertNotEqual(hidden, revealed, "Revealing must update the existing native cell")
        context.store.toggleReveal(item.id)
        XCTAssertEqual(try pixels(), hidden, "Concealing must immediately restore the masked snippet")
        XCTAssertEqual(row.convert(row.bounds, to: nil), frame)
    }

    func testInspectorBlocksWindowRoutingBeforeSwiftUIUpdate() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("Blocked behind inspector")
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let row = try XCTUnwrap(f.rows.first)
        f.inspector.open(itemID: item.id, reduceMotion: false)
        // Deliberately do not pump the render loop: model already blocks input.
        f.window.sendEvent(try f.event(on: row))
        f.window.sendEvent(try f.event(on: row, count: 2))
        XCTAssertTrue(f.probe.pasted.isEmpty)
        XCTAssertEqual(f.probe.closes, 0)
    }

    private final class ForegroundControl: NSView {
        var presses = 0
        var releases = 0
        override func mouseUp(with event: NSEvent) { releases += 1 }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { presses += 1 }
    }
    func testNativeForegroundControlReceivesPressInsteadOfBackgroundList() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        _ = try context.text("Covered row")
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let root = NSView(frame: f.host.view.bounds)
        let hosted = f.host.view
        f.window.contentView = root; hosted.frame = root.bounds; root.addSubview(hosted)
        f.pump()
        let row = try XCTUnwrap(f.rows.first)
        let overlay = ForegroundControl(frame: row.convert(row.bounds, to: root))
        root.addSubview(overlay)
        f.window.sendEvent(try f.event(on: row))
        f.window.sendEvent(try f.event(on: row, count: 2))
        XCTAssertEqual(overlay.presses, 2, "Window routing must not consume a real foreground control")
        XCTAssertTrue(f.probe.pasted.isEmpty)
    }

    func testGapsHiddenListsAndDeletedRowsCannotPasteCachedRecipient() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<8 { _ = try context.text("Guard row \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let row = try XCTUnwrap(f.rows.first)
        f.window.sendEvent(try f.event(on: row))
        let gap = row.convert(CGPoint(x: 100, y: -4), to: nil)
        f.window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: gap,
            modifierFlags: [], timestamp: 10.1, windowNumber: f.window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 2, pressure: 1)))
        XCTAssertTrue(f.probe.pasted.isEmpty)
        let scroll = try XCTUnwrap(row.enclosingScrollView)
        scroll.isHidden = true
        row.mouseDown(with: try f.event(on: row))
        row.mouseDown(with: try f.event(on: row, count: 2))
        XCTAssertTrue(f.probe.pasted.isEmpty)
        scroll.isHidden = false
        context.store.delete(try XCTUnwrap(row.representedItemID))
        row.mouseDown(with: try f.event(on: row))
        row.mouseDown(with: try f.event(on: row, count: 2))
        XCTAssertTrue(f.probe.pasted.isEmpty)
    }

    func testRetainedRowCannotClickThroughOverlayScroller() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<30 { _ = try context.text("Scroller \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let row = try XCTUnwrap(f.rows.first)
        let scroll = try XCTUnwrap(row.enclosingScrollView)
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        scroller.isHidden = false
        let localY = scroll.convert(row.convert(CGPoint(x: 100, y: row.bounds.midY), to: nil), from: nil).y
        let point = scroll.convert(CGPoint(x: scroller.frame.midX, y: localY), to: nil)
        XCTAssertTrue(scroller.frame.contains(scroll.convert(point, from: nil)))
        for count in 1...2 {
            row.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 30 + Double(count) * 0.05,
                windowNumber: f.window.windowNumber, context: nil, eventNumber: count,
                clickCount: count, pressure: 1)))
        }
        XCTAssertTrue(f.probe.pasted.isEmpty)
    }

    func testRowPressDragReleaseDoesNotSwallowNextControlRelease() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        _ = try context.text("Lifecycle")
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let field = try XCTUnwrap(InspectorTestContext.descendants(f.host.view, NSTextField.self).first)
        f.window.makeFirstResponder(field)
        let row = try XCTUnwrap(f.rows.first)
        let point = row.convert(CGPoint(x: 100, y: row.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 50, windowNumber: f.window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        f.window.sendEvent(try event(.leftMouseDown))
        f.window.sendEvent(try event(.leftMouseDragged))
        f.window.sendEvent(try event(.leftMouseUp))
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(f.probe.pasted.isEmpty)
        let root = NSView(frame: f.host.view.bounds)
        let hosted = f.host.view
        f.window.contentView = root; hosted.frame = root.bounds; root.addSubview(hosted)
        f.pump()
        let overlay = ForegroundControl(frame: row.convert(row.bounds, to: root))
        root.addSubview(overlay)
        f.window.sendEvent(try event(.leftMouseDown))
        f.window.sendEvent(try event(.leftMouseUp))
        XCTAssertEqual(overlay.presses, 1)
        XCTAssertEqual(overlay.releases, 1)
    }

}
