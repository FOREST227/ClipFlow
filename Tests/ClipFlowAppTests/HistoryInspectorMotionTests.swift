import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class HistoryInspectorHarness {
    let context: InspectorTestContext
    let driver = ManualInspectorDriver()
    let inspector: InspectorPresentation
    let host: NSHostingController<AnyView>
    let window: NSWindow
    init(context: InspectorTestContext) {
        _ = NSApplication.shared
        self.context = context
        inspector = InspectorPresentation(driver: driver)
        host = NSHostingController(rootView: AnyView(ContentView(showsBackground: false,
            showsPermissionOverlay: false, store: context.store, inspector: inspector)
            .frame(width: 620, height: 850)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 850),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        InspectorTestContext.settle(until: { !self.rows.isEmpty })
    }
    var rows: [LibraryInteractiveHostingView] {
        InspectorTestContext.descendants(host.view, LibraryInteractiveHostingView.self)
    }
    func pump() {
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    func close() { window.close(); inspector.reset() }
    func event(on row: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 10, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    func escape(in target: NSWindow? = nil) throws -> NSEvent {
        let target = target ?? window
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 10, windowNumber: target.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }
}

@MainActor
final class HistoryInspectorMotionTests: XCTestCase {
    func testClosingKeepsNativeRowsDisabled() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<8 { _ = try context.text("History fixture \(n)") }
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.rows.first)
        row.rightMouseDown(with: try fixture.event(on: row))
        fixture.pump()
        XCTAssertNotNil(fixture.inspector.snapshot.itemID)
        fixture.driver.finishLatest()
        fixture.pump()
        fixture.inspector.dismiss(reduceMotion: false)
        let other = try XCTUnwrap(fixture.rows.dropFirst().first)
        let selected = context.store.selectedItemID
        for p: CGFloat in [0.8, 0.4, 0.01] {
            fixture.driver.emit(p)
            fixture.pump()
            XCTAssertTrue(fixture.rows.allSatisfy { !$0.interactionEnabled })
            other.mouseDown(with: try fixture.event(on: other))
            XCTAssertEqual(context.store.selectedItemID, selected)
        }
        fixture.driver.finishLatest()
        fixture.pump()
        XCTAssertTrue(fixture.rows.allSatisfy(\.interactionEnabled))
        other.mouseDown(with: try fixture.event(on: other))
        XCTAssertNotEqual(context.store.selectedItemID, selected)
    }

    func testScrolledOpenClosePreservesRowsAndOffset() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<80 {
            _ = try context.text(n % 3 == 0 ? "func item\(n)() {\n    return true\n}" : "History row \(n)")
        }
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        let scroll = try XCTUnwrap(fixture.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1500))
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.pump()
        let offset = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(offset, 424)
        let row = try XCTUnwrap(fixture.rows.first {
            scroll.contentView.bounds.insetBy(dx: 0, dy: 10).contains($0.convert($0.bounds, to: scroll.contentView))
        })
        func visibleIdentities() -> Set<ObjectIdentifier> {
            Set(fixture.rows.filter {
                $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)
            }.map(ObjectIdentifier.init))
        }
        let identities = visibleIdentities()
        row.rightMouseDown(with: try fixture.event(on: row))
        fixture.pump()
        let revisions = Dictionary(uniqueKeysWithValues: fixture.rows.map { (ObjectIdentifier($0), $0.contentRevision) })
        for p: CGFloat in [0.2, 0.5, 0.8] {
            fixture.driver.emit(p); fixture.pump()
            XCTAssertEqual(visibleIdentities(), identities)
            XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
            for current in fixture.rows { XCTAssertEqual(current.contentRevision, revisions[ObjectIdentifier(current)]) }
        }
        fixture.driver.finishLatest(); fixture.pump()
        fixture.inspector.dismiss(reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
        XCTAssertEqual(visibleIdentities(), identities)
    }

    func testEscapeWithWebFocusClosesInspectorNotWindow() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("func command() {\n    print(\"fixture\")\n}")
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        let web = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, WKWebView.self).first)
        fixture.window.makeFirstResponder(web)
        NSApp.sendEvent(try fixture.escape())
        XCTAssertEqual(fixture.inspector.snapshot.phase, .closing)
        XCTAssertTrue(fixture.window.isVisible)
        fixture.driver.finishLatest(); fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.phase, .closed)
    }

    func testWrongWindowEscapeIsIgnored() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text()
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        let bridge = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, InspectorEscapeView.self).first)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertFalse(bridge.handleEscape(try fixture.escape(in: other)))
        XCTAssertEqual(fixture.inspector.snapshot.phase, .open)
    }

    func testPortraitAndShortTextFitWindow() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let items = [try context.text("Short note"), try context.image(width: 40, height: 900)]
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        for item in items {
            fixture.inspector.open(itemID: item.id, reduceMotion: false)
            fixture.driver.finishLatest(); fixture.pump()
            for canvas in InspectorTestContext.descendants(fixture.host.view, DetailImageCanvas.self) {
                XCTAssertGreaterThan(canvas.bounds.height, 0)
                XCTAssertLessThanOrEqual(canvas.convert(canvas.bounds, to: fixture.host.view).maxY,
                    fixture.host.view.bounds.maxY + 1)
            }
        }
    }

    func testInvalidatedSensitiveItemDisappearsImmediately() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("ghp_" + String(repeating: "a", count: 36))
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        context.store.delete(item.id)
        fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.phase, .closed)
        XCTAssertNil(fixture.inspector.snapshot.itemID)
        XCTAssertFalse(fixture.inspector.blocksBackground)
        let expired = try context.text("ghp_" + String(repeating: "b", count: 36))
        XCTAssertTrue(expired.autoExpire)
        fixture.inspector.open(itemID: expired.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        context.store.purgeExpired(at: Date().addingTimeInterval(600))
        fixture.pump()
        XCTAssertNil(fixture.inspector.snapshot.itemID)
        XCTAssertFalse(fixture.inspector.blocksBackground)
    }
}
