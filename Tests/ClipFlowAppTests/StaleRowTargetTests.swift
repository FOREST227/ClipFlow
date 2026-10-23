import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Simulates the hosting hierarchy briefly retaining an old hit-test recipient.
@MainActor
final class StaleRowTargetTests: XCTestCase {
    private final class HostingRoot: NSView {
        weak var staleTarget: NSView?
        var returnStaleTarget = true
        var usesFlippedCoordinates = false
        override var isFlipped: Bool { usesFlippedCoordinates }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if returnStaleTarget, let staleTarget { return staleTarget }
            return super.hitTest(point)
        }
    }

    private final class Overlay: NSView {
        var passesThrough = false
        override func hitTest(_ point: NSPoint) -> NSView? {
            passesThrough ? nil : super.hitTest(point)
        }
    }

    private func click(in window: NSWindow, at point: CGPoint, count: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 10 + Double(count) * 0.05, windowNumber: window.windowNumber,
            context: nil, eventNumber: count, clickCount: count, pressure: 1))
    }

    func testStaleFirstRowCannotStealFirstClickOrDoubleClickTarget() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        window.contentView = root
        let first = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 400, width: 320, height: 80))
        let intended = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 40, width: 320, height: 80))
        root.addSubview(first)
        root.addSubview(intended)
        var selected = ""
        var pastes: [String] = []
        for (view, id) in [(first, "first"), (intended, "intended")] {
            view.update(itemID: UUID(), rootView: AnyView(Text(id)),
                onSelect: { selected = id }, onPaste: { pastes.append(id) }, onInspect: {})
        }
        root.staleTarget = first
        let location = intended.convert(NSPoint(x: 100, y: 40), to: nil)
        // Both native delivery and the first re-hit-test still refer to the old row.
        first.mouseDown(with: try click(in: window, at: location))
        XCTAssertEqual(selected, "intended", "A distant stale recipient must not steal the first click")
        XCTAssertTrue(pastes.isEmpty)
        root.returnStaleTarget = false
        intended.mouseDown(with: try click(in: window, at: location, count: 2))
        XCTAssertEqual(pastes, ["intended"])
        // Recovery must also work if the hosting result remains stale on both clicks.
        root.returnStaleTarget = true
        first.mouseDown(with: try click(in: window, at: location))
        first.mouseDown(with: try click(in: window, at: location, count: 2))
        XCTAssertEqual(selected, "intended")
        XCTAssertEqual(pastes, ["intended", "intended"])
    }

    func testCorrectNativeRecipientSurvivesStaleHostingHitTest() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        root.usesFlippedCoordinates = true
        window.contentView = root
        let first = LibraryInteractiveHostingView(frame: NSRect(x: 0, y: 400, width: 320, height: 80))
        let intended = LibraryInteractiveHostingView(frame: NSRect(x: 0, y: 40, width: 320, height: 80))
        root.addSubview(first)
        root.addSubview(intended)
        var selected = ""
        first.update(rootView: AnyView(Text("first")), onSelect: { selected = "first" }, onInspect: {})
        intended.update(rootView: AnyView(Text("intended")), onSelect: { selected = "intended" }, onInspect: {})
        root.staleTarget = first
        intended.mouseDown(with: try click(in: window,
            at: intended.convert(NSPoint(x: 100, y: 40), to: nil)))
        XCTAssertEqual(selected, "intended")
    }

    func testStaleFirstRowWithRealClippedScrollOffset() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 320, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        window.contentView = root
        let scroll = NSScrollView(frame: root.bounds)
        root.addSubview(scroll)
        let document = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 3000))
        document.usesFlippedCoordinates = true
        document.returnStaleTarget = false
        scroll.documentView = document
        let first = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let intended = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 1600, width: 320, height: 80))
        document.addSubview(first)
        document.addSubview(intended)
        var selected = ""
        first.update(rootView: AnyView(Text("first")), onSelect: { selected = "first" },
            onPaste: {}, onInspect: {})
        intended.update(rootView: AnyView(Text("intended")), onSelect: { selected = "intended" },
            onPaste: {}, onInspect: {})
        root.staleTarget = first
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1500))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000)
        let firstRect = first.convert(first.bounds, to: scroll.contentView)
        XCTAssertFalse(firstRect.intersects(scroll.contentView.bounds))
        let before = scroll.contentView.bounds.minY
        first.mouseDown(with: try click(in: window,
            at: intended.convert(NSPoint(x: 100, y: 40), to: nil)))
        XCTAssertEqual(selected, "intended")
        XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 0.5)
    }

    func testFirstClickRetainedByClosedPanelRoutesToNewPanel() throws {
        _ = NSApplication.shared
        let oldWindow = NSWindow(contentRect: NSRect(x: 50, y: 100, width: 320, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        oldWindow.isReleasedWhenClosed = false
        let oldRoot = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        oldWindow.contentView = oldRoot
        let oldRow = HUDInteractiveHostingView(frame: oldRoot.bounds)
        oldRoot.addSubview(oldRow)
        var selected = ""
        var pastes: [String] = []
        oldRow.update(rootView: AnyView(Text("old first")), onSelect: { selected = "old first" },
            onPaste: { pastes.append("old first") }, onInspect: {})
        oldWindow.orderFront(nil)
        oldWindow.contentView = nil
        oldWindow.close()
        XCTAssertNil(oldRow.window)

        let newWindow = NSWindow(contentRect: NSRect(x: 600, y: 150, width: 320, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        newWindow.isReleasedWhenClosed = false
        defer { newWindow.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        newWindow.contentView = root
        let target = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 40, width: 320, height: 80))
        root.addSubview(target)
        target.update(rootView: AnyView(Text("intended")), onSelect: { selected = "intended" },
            onPaste: { pastes.append("intended") }, onInspect: {})
        newWindow.orderFront(nil)
        let point = target.convert(NSPoint(x: 100, y: 40), to: nil)
        let first = try click(in: newWindow, at: point)
        XCTAssertTrue(first.window === newWindow)
        oldRow.mouseDown(with: first)
        XCTAssertEqual(selected, "intended")
        target.mouseDown(with: try click(in: newWindow, at: point, count: 2))
        XCTAssertEqual(pastes, ["intended"])
    }

    func testStaleHostingTargetCannotBypassForegroundOverlay() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        window.contentView = root
        let first = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 400, width: 320, height: 80))
        let intended = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 40, width: 320, height: 80))
        root.addSubview(first)
        root.addSubview(intended)
        let blocker = Overlay(frame: intended.frame)
        root.addSubview(blocker)
        var firstSelections = 0
        var intendedSelections = 0
        first.update(rootView: AnyView(Text("first")), onSelect: { firstSelections += 1 },
            onPaste: {}, onInspect: {})
        intended.update(rootView: AnyView(Text("covered")), onSelect: { intendedSelections += 1 },
            onPaste: {}, onInspect: {})
        root.staleTarget = first
        let location = intended.convert(NSPoint(x: 100, y: 40), to: nil)
        let event = try click(in: window, at: location)
        root.returnStaleTarget = false
        XCTAssertTrue(root.hitTest(root.convert(location, from: nil)) === blocker)
        root.returnStaleTarget = true
        first.mouseDown(with: event)
        intended.mouseDown(with: event)
        XCTAssertEqual(firstSelections, 0)
        XCTAssertEqual(intendedSelections, 0, "Geometric recovery must respect a foreground overlay")
        blocker.passesThrough = true
        first.mouseDown(with: event)
        XCTAssertEqual(intendedSelections, 1, "Pass-through decoration must not block valid recovery")
        blocker.passesThrough = false
        blocker.isHidden = true
        first.mouseDown(with: event)
        XCTAssertEqual(intendedSelections, 2)
    }

    func testInspectorOrControlHitDoesNotClickThrough() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        window.contentView = root
        let row = HUDInteractiveHostingView(frame: root.bounds)
        let blocker = NSView(frame: root.bounds)
        root.addSubview(row)
        root.addSubview(blocker)
        root.staleTarget = blocker
        var selections = 0
        row.update(rootView: AnyView(Text("behind inspector")), onSelect: { selections += 1 },
            onPaste: {}, onInspect: {})
        row.mouseDown(with: try click(in: window, at: NSPoint(x: 100, y: 100)))
        XCTAssertEqual(selections, 0)
    }

    func testSwiftUIHostedRowDisablesAndResetsDoubleClickSequence() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "StaleHostedRow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        store.ingestCopiedText("Hosted selection fixture", sourceApp: "Test", sourceBundleID: nil)
        let item = try XCTUnwrap(store.items.first)
        let selection = HistorySelection()
        var selections = 0
        var pastes = 0
        var inspections = 0
        func content(disabled: Bool) -> AnyView {
            AnyView(HUDInteractiveRow(item: item, store: store, selection: selection,
                onSelect: { selections += 1 }, onPaste: { pastes += 1 }, onInspect: { inspections += 1 })
                .disabled(disabled).frame(width: 304, height: 64))
        }
        let host = NSHostingController(rootView: content(disabled: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 64),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.08)) }
        func findRow(_ view: NSView) -> HUDInteractiveHostingView? {
            if let row = view as? HUDInteractiveHostingView { return row }
            return view.subviews.lazy.compactMap { findRow($0) }.first
        }
        settle()
        let row = try XCTUnwrap(findRow(host.view))
        func event(_ count: Int) throws -> NSEvent {
            try click(in: window, at: row.convert(NSPoint(x: 100, y: 30), to: nil), count: count)
        }
        row.mouseDown(with: try event(1))
        XCTAssertEqual(selections, 1)
        host.rootView = content(disabled: true)
        settle()
        let retainedEvent = try event(2)
        row.mouseDown(with: retainedEvent)
        row.rightMouseDown(with: retainedEvent)
        row.otherMouseDown(with: retainedEvent)
        _ = row.menu(for: retainedEvent)
        XCTAssertEqual(selections, 1, "A retained callback must not select behind the inspector")
        XCTAssertEqual(inspections, 0)
        XCTAssertEqual(pastes, 0)

        host.rootView = content(disabled: false)
        settle()
        XCTAssertTrue(findRow(host.view) === row, "Enabling must preserve the row identity")
        row.mouseDown(with: try event(2))
        XCTAssertEqual(selections, 2)
        XCTAssertEqual(pastes, 0, "Clicks separated by an inspector must not become a double click")
        row.mouseDown(with: try event(3))
        XCTAssertEqual(pastes, 1, "A fresh two-click sequence must work after closing the inspector")
    }

    func testDisabledUnattachedRowsIgnoreRetainedCallbacks() throws {
        let quick = HUDInteractiveHostingView()
        let history = LibraryInteractiveHostingView()
        var selections = 0
        quick.update(rootView: AnyView(Text("quick")), onSelect: { selections += 1 },
            onPaste: {}, onInspect: {})
        history.update(rootView: AnyView(Text("history")), onSelect: { selections += 1 }, onInspect: {})
        quick.interactionEnabled = false
        history.interactionEnabled = false
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 10, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        quick.mouseDown(with: event)
        history.mouseDown(with: event)
        XCTAssertEqual(selections, 0)
    }

    func testStaleRecipientCannotSelectThroughGapOrHiddenRow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = HostingRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        window.contentView = root
        let row = HUDInteractiveHostingView(frame: NSRect(x: 0, y: 400, width: 320, height: 80))
        root.addSubview(row)
        var selections = 0
        row.update(rootView: AnyView(Text("first")), onSelect: { selections += 1 }, onPaste: {}, onInspect: {})
        root.staleTarget = row
        row.mouseDown(with: try click(in: window, at: NSPoint(x: 100, y: 200)))
        XCTAssertEqual(selections, 0, "Blank space must not fall back to the first row")
        row.isHidden = true
        row.mouseDown(with: try click(in: window, at: NSPoint(x: 100, y: 440)))
        XCTAssertEqual(selections, 0, "Hidden cards must not receive selection")
    }
}
