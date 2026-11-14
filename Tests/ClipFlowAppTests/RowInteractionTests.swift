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

    func testHistoryDoubleClickOpensDetailsOnce() throws {
        let row = LibraryInteractiveHostingView()
        var selections = 0
        var inspections = 0
        row.update(rootView: AnyView(Text("history")), onSelect: { selections += 1 },
            onInspect: { inspections += 1 })
        row.mouseDown(with: try click(1, at: 10))
        XCTAssertEqual(inspections, 0, "A single click only selects")
        row.mouseDown(with: try click(2, at: 10.05))
        XCTAssertEqual(inspections, 1)
        row.mouseDown(with: try click(3, at: 10.1))
        XCTAssertEqual(selections, 3)
        XCTAssertEqual(inspections, 1, "A completed double click must be consumed")
    }

    func testHistoryDoubleClickRequiresBothClicksOnTheSameRow() throws {
        let a = LibraryInteractiveHostingView()
        let b = LibraryInteractiveHostingView()
        var inspections = 0
        for row in [a, b] {
            row.update(rootView: AnyView(Text("row")), onSelect: {}, onInspect: { inspections += 1 })
        }
        a.mouseDown(with: try click(1, at: 10))
        b.mouseDown(with: try click(2, at: 10.05))
        XCTAssertEqual(inspections, 0, "A system double-click count alone must not open another row")
        let recycled = LibraryInteractiveHostingView()
        recycled.update(rootView: AnyView(Text("row")), onSelect: {}, onInspect: { inspections += 1 })
        recycled.identifier = NSUserInterfaceItemIdentifier("first")
        recycled.mouseDown(with: try click(1, at: 20))
        recycled.identifier = NSUserInterfaceItemIdentifier("second")
        recycled.mouseDown(with: try click(2, at: 20.05))
        XCTAssertEqual(inspections, 0, "A reused row showing another item starts a new sequence")
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

    func testLeftClickSelectsOnceAndRightClickOpensTheContextMenu() throws {
        _ = NSApplication.shared
        let presenter = ClipboardRowHitView.presentContextMenu
        defer { ClipboardRowHitView.presentContextMenu = presenter }
        var presented: [NSMenu] = []
        ClipboardRowHitView.presentContextMenu = { menu, _, _ in presented.append(menu) }
        var selections = 0
        var inspections = 0
        var copies = 0
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let entries: () -> [ClipboardRowMenuEntry] = {
            [.action(title: "复制", symbol: "doc.on.doc") { copies += 1 }, .separator,
             .action(title: "删除条目", symbol: "trash") {}]
        }
        let history = LibraryInteractiveHostingView()
        history.update(rootView: AnyView(Text("test")), onSelect: { selections += 1 },
            onInspect: { inspections += 1 }, menuProvider: entries)
        let quick = HUDInteractiveHostingView()
        quick.update(rootView: AnyView(Text("test")), onSelect: { selections += 1 }, onPaste: {},
            onInspect: { inspections += 1 }, menuProvider: entries)

        history.mouseDown(with: event)
        XCTAssertEqual(selections, 1)
        XCTAssertTrue(presented.isEmpty)
        history.rightMouseDown(with: event)
        quick.rightMouseDown(with: event)
        XCTAssertEqual(selections, 3, "Right click selects the row its menu acts on")
        XCTAssertEqual(inspections, 0, "Details are a menu entry, not the right-click action")
        XCTAssertEqual(presented.count, 2)
        let menu = try XCTUnwrap(presented.first)
        XCTAssertEqual(menu.items.map(\.title), ["复制", "", "删除条目"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        let copy = menu.items[0]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(copies, 1)

        history.interactionEnabled = false
        quick.interactionEnabled = false
        history.rightMouseDown(with: event)
        quick.rightMouseDown(with: event)
        XCTAssertNil(history.menu(for: event))
        XCTAssertNil(quick.menu(for: event))
        XCTAssertEqual(presented.count, 2, "Rows behind an overlay must not open a menu")
    }

    func testRowsWithoutMenuEntriesIgnoreRightClick() throws {
        let presenter = ClipboardRowHitView.presentContextMenu
        defer { ClipboardRowHitView.presentContextMenu = presenter }
        var presented = 0
        ClipboardRowHitView.presentContextMenu = { _, _, _ in presented += 1 }
        let row = LibraryInteractiveHostingView()
        var selections = 0
        row.update(rootView: AnyView(Text("test")), onSelect: { selections += 1 }, onInspect: {})
        row.rightMouseDown(with: try click(1, at: 1))
        XCTAssertEqual(presented, 0)
        XCTAssertEqual(selections, 0)
    }

    func testOpenDetailsInspectsOnlyWhileEnabled() {
        var inspections = 0
        let history = LibraryInteractiveHostingView()
        history.update(rootView: AnyView(Text("test")), onSelect: {}, onInspect: { inspections += 1 })
        let quick = HUDInteractiveHostingView()
        quick.update(rootView: AnyView(Text("test")), onSelect: {}, onPaste: {}, onInspect: { inspections += 1 })
        for row in [history, quick] as [ClipboardRowHitView] { row.openDetails() }
        XCTAssertEqual(inspections, 2)
        history.interactionEnabled = false
        quick.interactionEnabled = false
        for row in [history, quick] as [ClipboardRowHitView] { row.openDetails() }
        XCTAssertEqual(inspections, 2)
    }

    func testHoverActionBarClicksRunTheActionInsteadOfSelecting() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        window.contentView = root
        let row = LibraryInteractiveHostingView(frame: root.bounds)
        root.addSubview(row)
        var selections = 0
        var actions: [LibraryCardAction] = []
        row.update(rootView: AnyView(Text("row")), onSelect: { selections += 1 }, onInspect: {},
            onAction: { actions.append($0) })
        func press(x: CGFloat, fromTop y: CGFloat) throws {
            row.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: row.convert(NSPoint(x: x, y: row.isFlipped ? y : row.bounds.height - y), to: nil),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        let layout = LibraryCardActionLayout.self
        let barMinX = 300 - layout.trailingInset - layout.barSize.width
        let centerY = layout.topInset + layout.barSize.height / 2
        func centerX(_ index: CGFloat) -> CGFloat {
            barMinX + layout.padding + index * (layout.buttonSize.width + layout.spacing) + layout.buttonSize.width / 2
        }
        try press(x: centerX(0), fromTop: centerY)
        XCTAssertEqual(selections, 1, "The hidden action bar must not swallow clicks")
        XCTAssertTrue(actions.isEmpty)

        row.hover.isHovered = true
        try press(x: centerX(0), fromTop: centerY)
        XCTAssertEqual(row.hover.confirmedAction, .copy)
        XCTAssertTrue(row.hover.isHovered, "Copy keeps the bar visible to show its confirmation")
        try press(x: centerX(1), fromTop: centerY)
        XCTAssertFalse(row.hover.isHovered, "Pinning reorders rows under the pointer")
        XCTAssertEqual(actions, [.copy, .pin])
        XCTAssertEqual(selections, 1)
        row.hover.isHovered = true
        try press(x: barMinX - 4, fromTop: centerY)
        XCTAssertEqual(actions, [.copy, .pin], "Delete is not a hover target")
        XCTAssertEqual(selections, 2)
        row.hover.isHovered = true
        try press(x: 40, fromTop: centerY)
        XCTAssertEqual(selections, 3, "The rest of a hovered row still selects")

        row.interactionEnabled = false
        XCTAssertFalse(row.hover.isHovered, "Rows behind an overlay drop their hover actions")
    }

    func testActionBarGeometryMapsButtonsAndRejectsOutside() {
        let layout = LibraryCardActionLayout.self
        let width: CGFloat = 454
        let minX = width - layout.trailingInset - layout.barSize.width
        let y = layout.topInset + 4
        XCTAssertEqual(layout.buttonSize, CGSize(width: 28, height: 28))
        XCTAssertFalse(LibraryCardAction.hoverActions.contains(.delete))
        XCTAssertEqual(layout.action(at: CGPoint(x: minX + 1, y: y), rowWidth: width), .copy)
        XCTAssertEqual(layout.action(at: CGPoint(x: minX + layout.padding + layout.buttonSize.width + layout.spacing + 4, y: y), rowWidth: width), .pin)
        XCTAssertEqual(layout.action(at: CGPoint(x: minX + layout.barSize.width - 1, y: y), rowWidth: width), .pin)
        XCTAssertNil(layout.action(at: CGPoint(x: minX - 1, y: y), rowWidth: width))
        XCTAssertNil(layout.action(at: CGPoint(x: width - 2, y: y), rowWidth: width))
        XCTAssertNil(layout.action(at: CGPoint(x: minX + 10, y: layout.topInset + layout.barSize.height + 1), rowWidth: width))
        XCTAssertNil(layout.action(at: CGPoint(x: 10, y: y), rowWidth: 40), "A row narrower than the bar has no actions")
    }
}
