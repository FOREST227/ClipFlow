import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class QuickPasteMomentumTests: XCTestCase {
    private final class PendingScrollLayout: NSView {
        var pendingUpdate: (() -> Void)?
        override func layout() {
            super.layout()
            let update = pendingUpdate
            pendingUpdate = nil
            update?()
        }
    }
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    func testMouseDownMustNotFlushPendingScrollLayoutAndRetargetFirstRow() throws {
        _ = NSApplication.shared
        let root = PendingScrollLayout(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        let window = QuickPastePanel(contentRect: root.bounds, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let scroll = NSScrollView(frame: root.bounds)
        root.addSubview(scroll)
        let document = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 320, height: 2400))
        scroll.documentView = document
        let first = HUDInteractiveHostingView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let intended = HUDInteractiveHostingView(frame: CGRect(x: 0, y: 1500, width: 320, height: 80))
        document.addSubview(first); document.addSubview(intended)
        var selected: [String] = []
        var pasted: [String] = []
        for (row, name) in [(first, "FIRST"), (intended, "VISIBLE")] {
            row.update(itemID: UUID(), rootView: AnyView(Text(name)),
                onSelect: { selected.append(name) }, onPaste: { pasted.append(name) }, onInspect: {})
        }
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1500))
        scroll.reflectScrolledClipView(scroll.contentView)
        let location = intended.convert(CGPoint(x: 100, y: 40), to: nil)
        XCTAssertTrue(intended.visibleRect.height > 0)
        XCTAssertFalse(first.convert(first.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds))
        // A pending virtual-list layout may adjust its estimated scroll anchor.
        // The click handler must not flush that pending layout before choosing the pressed card.
        root.pendingUpdate = {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        root.needsLayout = true
        func event(_ count: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 50 + Double(count) * 0.05,
                windowNumber: window.windowNumber, context: nil, eventNumber: count,
                clickCount: count, pressure: 1))
        }
        intended.mouseDown(with: try event(1))
        print("PENDING_LAYOUT selected", selected, "offset", scroll.contentView.bounds.minY)
        XCTAssertEqual(selected, ["VISIBLE"], "A pending scroll layout must not turn a visible-card click into a first-row click")
        XCTAssertEqual(scroll.contentView.bounds.minY, 1500, "Handling a row press must not force a viewport jump")
        intended.mouseDown(with: try event(2))
        XCTAssertEqual(pasted, ["VISIBLE"])
    }

    func testMovingWheelStreamBetweenClicksDoesNotPastePreviousRecipient() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<40 { _ = try context.text("Moving wheel \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let scroll = try XCTUnwrap(f.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        f.pump()
        let row = try XCTUnwrap(f.rows.first { scroll.contentView.bounds.insetBy(dx: 0, dy: 12)
            .contains($0.convert($0.bounds, to: scroll.contentView)) })
        let point = row.convert(CGPoint(x: 100, y: row.bounds.midY), to: nil)
        func rowAtPointer() throws -> HUDInteractiveHostingView {
            try XCTUnwrap(f.rows.first {
                let local = $0.convert(point, from: nil)
                return $0.bounds.contains(local) && $0.visibleRect.contains(local)
            })
        }
        func wheel() throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: -25, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.location = CGPoint(x: point.x, y: (NSScreen.main?.frame.height ?? 1000) - point.y)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        func press(_ count: Int) throws {
            f.window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 100 + Double(count) * 0.05,
                windowNumber: f.window.windowNumber, context: nil, eventNumber: count,
                clickCount: count, pressure: 1)))
        }
        // Positive control: this exact LOCAL wheel stream must actually move AppKit's viewport.
        // No CG events are posted to the user's input stream; this is not physical momentum emulation.
        let control = scroll.contentView.bounds.minY
        f.window.sendEvent(try wheel())
        InspectorTestContext.settle(until: { scroll.contentView.bounds.minY > control })
        f.pump()
        let afterControl = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(afterControl, control)
        let firstID = try XCTUnwrap(try rowAtPointer().representedItemID)
        try press(1)
        let before = scroll.contentView.bounds.minY
        for _ in 0..<4 { f.window.sendEvent(try wheel()); f.pump() }
        InspectorTestContext.settle(until: { scroll.contentView.bounds.minY >= before + 80 })
        f.pump()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, before)
        let nextID = try XCTUnwrap(try rowAtPointer().representedItemID)
        XCTAssertNotEqual(firstID, nextID, "The wheel fixture must move a different card under the pointer")
        try press(2)
        XCTAssertTrue(f.probe.pasted.isEmpty, "Moving to another card must start a new click sequence")
        try press(3)
        XCTAssertEqual(f.probe.pasted, [nextID], "Only the new pointer target may be pasted")
        print("MOVING_WHEEL positive-control", control, "->", afterControl,
            "final offset", scroll.contentView.bounds.minY,
            "first-target != second-target; pasted exact new target")
    }

    func testPinReorderBetweenPressesCannotPasteFirstOrRecycledItem() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<50 { _ = try context.text("Pin between clicks \(n)") }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let scroll = try XCTUnwrap(f.rows.first?.enclosingScrollView)
        var movedTargets = 0
        for n in 0..<12 {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 600 + n * 100))
            scroll.reflectScrolledClipView(scroll.contentView); f.pump()
            let row = try XCTUnwrap(f.rows.first { scroll.contentView.bounds.insetBy(dx: 0, dy: 12)
                .contains($0.convert($0.bounds, to: scroll.contentView)) })
            let firstID = try XCTUnwrap(row.representedItemID)
            let point = row.convert(CGPoint(x: 100, y: row.bounds.midY), to: nil)
            func press(_ count: Int) throws {
                f.window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: 200 + Double(n) + Double(count) * 0.05,
                    windowNumber: f.window.windowNumber, context: nil, eventNumber: n * 3 + count,
                    clickCount: count, pressure: 1)))
            }
            let oldCount = f.probe.pasted.count
            try press(1)
            context.store.togglePin(firstID); f.pump()
            let current = try XCTUnwrap(f.rows.first {
                let local = $0.convert(point, from: nil)
                return $0.bounds.contains(local) && $0.visibleRect.contains(local)
            })
            let nextID = try XCTUnwrap(current.representedItemID)
            try press(2)
            if nextID != firstID {
                movedTargets += 1
                XCTAssertEqual(f.probe.pasted.count, oldCount,
                    "A reorder moving a new card under the pointer must never paste it on its first press")
                try press(3)
            }
            XCTAssertEqual(f.probe.pasted.count, oldCount + 1)
            XCTAssertEqual(f.probe.pasted.last, nextID)
        }
        XCTAssertGreaterThan(movedTargets, 0, "The fixture must exercise actual pointer-target changes")
        print("PIN_BETWEEN_CLICKS verified", movedTargets, "changed pointer targets")
    }

    func testImmediateClickDuringScrollAndPinReorderTargetsVisibleCard() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<50 {
            if n % 5 == 0 {
                _ = try context.image(width: 80 + n, height: 130 + n)
            } else {
                _ = try context.text(n % 3 == 0 ? "func sample\(n)() { return true }" : "Momentum note \(n)")
            }
        }
        let f = InspectorHUDHarness(context: context)
        defer { f.close() }
        let scroll = try XCTUnwrap(f.rows.first?.enclosingScrollView)
        for n in 0..<60 {
            let offset = CGFloat(500 + (n * 137) % 2200)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            // Let one display pass prepare the moving viewport, not a 300ms idle wait.
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            if n % 3 == 0 {
                let pin = context.store.quickPasteItems[15]
                context.store.togglePin(pin.id)
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
            func visibleTarget() -> HUDInteractiveHostingView? {
                f.rows.first { row in
                    let rect = row.convert(row.bounds, to: scroll.contentView)
                    return rect.height > 40 && scroll.contentView.bounds.insetBy(dx: 0, dy: 12).contains(rect)
                }
            }
            // A click needs a displayed row, not an assumption that every runner
            // materializes native cells within 1ms. This does not wait for scroll
            // completion; both presses still follow immediately with no idle gap.
            InspectorTestContext.settle(until: {
                // XCTest pumps RunLoop, not NSApplication.run's display pass.
                f.host.view.layoutSubtreeIfNeeded()
                f.window.displayIfNeeded()
                return visibleTarget() != nil
            })
            let row = try XCTUnwrap(visibleTarget(), "Stress iteration \(n) must have a visible target")
            let wanted = try XCTUnwrap(row.representedItemID)
            let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let before = scroll.contentView.bounds.minY
            let oldCount = f.probe.pasted.count
            for count in 1...2 {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: point, modifierFlags: [], timestamp: 100 + Double(n) + Double(count) * 0.05,
                    windowNumber: f.window.windowNumber, context: nil, eventNumber: n * 2 + count,
                    clickCount: count, pressure: 1))
                f.window.sendEvent(event)
            }
            XCTAssertEqual(f.probe.pasted.count, oldCount + 1, "step \(n), offset \(before)")
            XCTAssertEqual(f.probe.pasted.last, wanted, "step \(n), pointer target must never become first item")
            XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 1, "Mouse selection must not jump")
        }
        XCTAssertEqual(f.probe.pasted.count, 60)
        print("STRESS_VERIFIED_PAIRS", f.probe.pasted.count)
    }
}
