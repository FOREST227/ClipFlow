import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class RowInteractionTests: XCTestCase {
    private func click(_ count: Int, at time: TimeInterval) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: count, pressure: 1))
    }

    func testQuickPasteRequiresTwoClicksOnTheSameRow() throws {
        let a = HUDInteractiveHostingView()
        let b = HUDInteractiveHostingView()
        var selections = 0
        var pastes = 0
        for row in [a, b] {
            row.update(rootView: AnyView(Text("row")), onSelect: { selections += 1 },
                onPaste: { pastes += 1 }, onInspect: {})
        }
        a.mouseDown(with: try click(1, at: 10))
        b.mouseDown(with: try click(2, at: 10.05))
        XCTAssertEqual(pastes, 0, "A system double-click count alone must not paste a new row")
        XCTAssertEqual(selections, 2)
        b.mouseDown(with: try click(3, at: 10.1))
        XCTAssertEqual(pastes, 1, "Two consecutive clicks on B may paste B")
        b.mouseDown(with: try click(4, at: 10.15))
        XCTAssertEqual(pastes, 1, "A completed double click must be consumed")
    }

    func testQuickPasteNormalDoubleClickAndInterruptedSequences() throws {
        let row = HUDInteractiveHostingView()
        var pastes = 0
        let id = UUID()
        func configure(_ itemID: UUID) {
            row.update(itemID: itemID, rootView: AnyView(Text("row")),
                onSelect: {}, onPaste: { pastes += 1 }, onInspect: {})
        }
        configure(id)
        row.mouseDown(with: try click(1, at: 10))
        configure(id) // A selection redraw must preserve a real double click.
        row.mouseDown(with: try click(2, at: 10.05))
        XCTAssertEqual(pastes, 1)
        row.mouseDown(with: try click(1, at: 20))
        row.mouseDown(with: try click(2, at: 20 + NSEvent.doubleClickInterval + 1))
        XCTAssertEqual(pastes, 1)
        row.mouseDown(with: try click(1, at: 30))
        row.rightMouseDown(with: try click(1, at: 30.01))
        row.mouseDown(with: try click(2, at: 30.05))
        XCTAssertEqual(pastes, 1)
        row.mouseDown(with: try click(1, at: 40))
        configure(UUID()) // Recycled view now represents a different item.
        row.mouseDown(with: try click(2, at: 40.05))
        XCTAssertEqual(pastes, 1)
    }

    func testClickDeliveredToPreviousRowUsesActualPointerTarget() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = root
        let a = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        let b = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        root.addSubview(a)
        root.addSubview(b)
        var selected = ""
        var pastes = 0
        for (row, name) in [(a, "a"), (b, "b")] {
            row.update(rootView: AnyView(Text(name)), onSelect: { selected = name },
                onPaste: { pastes += 1 }, onInspect: {})
        }
        func event(_ count: Int, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: 30, y: y), modifierFlags: [],
                timestamp: 10 + Double(count) * 0.05, windowNumber: window.windowNumber,
                context: nil, eventNumber: count, clickCount: count, pressure: 1))
        }
        a.mouseDown(with: try event(1, 150))
        XCTAssertEqual(selected, "a")
        // AppKit may keep delivering a multi-click sequence to its original view.
        a.mouseDown(with: try event(2, 50))
        XCTAssertEqual(selected, "b")
        XCTAssertEqual(pastes, 0)
    }

    func testHistoryClickDeliveredToPreviousRowUsesActualPointerTarget() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = root
        let a = LibraryInteractiveHostingView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        let b = LibraryInteractiveHostingView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        root.addSubview(a)
        root.addSubview(b)
        var selected = ""
        for (row, name) in [(a, "a"), (b, "b")] {
            row.update(rootView: AnyView(Text(name)), onSelect: { selected = name },
                onInspect: {})
        }
        func event(_ count: Int, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: 30, y: y), modifierFlags: [],
                timestamp: 10 + Double(count) * 0.05, windowNumber: window.windowNumber,
                context: nil, eventNumber: count, clickCount: count, pressure: 1))
        }
        a.mouseDown(with: try event(1, 150))
        XCTAssertEqual(selected, "a")
        // AppKit may keep delivering a multi-click sequence to its original view.
        a.mouseDown(with: try event(2, 50))
        XCTAssertEqual(selected, "b")
    }

    func testHistoryMultiClicksOnlySelect() throws {
        let row = LibraryInteractiveHostingView()
        var selections = 0
        var inspections = 0
        row.update(rootView: AnyView(Text("history")), onSelect: { selections += 1 },
            onInspect: { inspections += 1 })
        for count in 1...3 { row.mouseDown(with: try click(count, at: 10 + Double(count) * 0.05)) }
        XCTAssertEqual(selections, 3)
        XCTAssertEqual(inspections, 0)
    }

    func testRowOwnsClicksOverTextImagesAndPadding() {
        let row = LibraryInteractiveHostingView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        row.update(rootView: AnyView(ZStack { Color.white; Text("A row with content") }), onSelect: {}, onInspect: {})
        row.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 150, y: 50), NSPoint(x: 298, y: 98)] {
            XCTAssertTrue(row.hitTest(point) === row, "Entire row must route clicks to its selection handler")
        }
        XCTAssertNil(row.hitTest(NSPoint(x: 310, y: 50)))
    }

    func testRowsAcceptFirstClickAndNeverDragTheWindow() {
        for row in [LibraryInteractiveHostingView(), HUDInteractiveHostingView()] as [NSView] {
            XCTAssertTrue(row.acceptsFirstMouse(for: nil))
            XCTAssertFalse(row.mouseDownCanMoveWindow)
        }
    }

    func testLeftClickSelectsOnceAndRightClickInspects() throws {
        let row = LibraryInteractiveHostingView()
        var selections = 0
        var inspections = 0
        row.update(rootView: AnyView(Text("test")), onSelect: { selections += 1 }, onInspect: { inspections += 1 })
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(inspections, 0)
        row.rightMouseDown(with: event)
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(inspections, 1)
    }
}
