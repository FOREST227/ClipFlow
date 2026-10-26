import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class InspectorHUDProbe {
    var pasted: [UUID] = []
    var closes = 0
}

@MainActor
final class InspectorHUDHarness {
    let context: InspectorTestContext
    let driver = ManualInspectorDriver()
    let inspector: InspectorPresentation
    let probe = InspectorHUDProbe()
    let host: NSHostingController<AnyView>
    let window: QuickPastePanel
    init(context: InspectorTestContext, reduceMotion: Bool = false, reduceTransparency: Bool = false) {
        _ = NSApplication.shared
        self.context = context
        inspector = InspectorPresentation(driver: driver)
        let probe = self.probe
        host = NSHostingController(rootView: AnyView(QuickPastePanelView(store: context.store,
            preferredTargetName: nil, onPaste: { probe.pasted.append($0.id) }, onOpenLibrary: {},
            onClose: { probe.closes += 1 }, inspector: inspector)
            .environment(\.inspectorMotionPolicy, InspectorMotionPolicy(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))))
        window = QuickPastePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 588),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        InspectorTestContext.settle(until: { !self.rows.isEmpty })
    }
    var rows: [HUDInteractiveHostingView] {
        InspectorTestContext.descendants(host.view, HUDInteractiveHostingView.self)
    }
    func pump() {
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    func close() { inspector.reset(); window.close() }
    func event(on row: NSView, count: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 10 + Double(count) * 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count, pressure: 1))
    }
    func escape() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 10, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }
    func clickPaste() throws {
        // Render-verified center of the plain-text inspector's existing paste button.
        // The fixture has fixed 360x588 geometry and minimum-height text content.
        let point = host.view.convert(NSPoint(x: 122, y: host.view.bounds.midY + 45), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 20, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 20.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
            inMode: .default, dequeue: true) { window.sendEvent(release) }
        pump()
    }
}

@MainActor
final class QuickPasteInspectorMotionTests: XCTestCase {
    func testLastClosingFrameCannotPasteUnderlyingRow() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<6 { _ = try context.text("HUD fixture \(n)") }
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.rows.first)
        row.rightMouseDown(with: try fixture.event(on: row))
        fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.itemID, row.representedItemID)
        fixture.driver.finishLatest(); fixture.pump()
        fixture.inspector.dismiss(reduceMotion: false)
        fixture.driver.emit(0.01); fixture.pump()
        row.mouseDown(with: try fixture.event(on: row))
        row.mouseDown(with: try fixture.event(on: row, count: 2))
        XCTAssertTrue(fixture.probe.pasted.isEmpty)
        XCTAssertTrue(fixture.rows.allSatisfy { !$0.interactionEnabled })
        fixture.driver.finishLatest(); fixture.pump()
        XCTAssertTrue(fixture.rows.allSatisfy(\.interactionEnabled))
    }

    func testEscapeWithWebFocusDismissesInspectorFirst() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("func example() {\n    return true\n}")
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        let web = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, WKWebView.self).first)
        fixture.window.makeFirstResponder(web)
        NSApp.sendEvent(try fixture.escape())
        XCTAssertEqual(fixture.inspector.snapshot.phase, .closing)
        XCTAssertTrue(fixture.window.isVisible)
        NSApp.sendEvent(try fixture.escape())
        XCTAssertTrue(fixture.window.isVisible, "Escape during closing must not dismiss the panel behind it")
        fixture.driver.finishLatest(); fixture.pump()
        NSApp.sendEvent(try fixture.escape())
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testRepeatedPasteInvokesExactItemOnce() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let wanted = try context.text("Wanted older item")
        _ = try context.text("First, not wanted")
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: wanted.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        try fixture.clickPaste()
        fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.phase, .closing)
        try fixture.clickPaste()
        fixture.pump()
        XCTAssertTrue(fixture.probe.pasted.isEmpty)
        fixture.driver.finishLatest(); fixture.pump()
        fixture.driver.finishLatest()
        XCTAssertEqual(fixture.probe.pasted, [wanted.id])
        XCTAssertEqual(fixture.probe.closes, 1)
    }

    func testHideOrReopenRejectsOldPasteCompletion() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let first = try context.text("Older")
        let next = try context.text("Newer")
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: first.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        try fixture.clickPaste()
        let old = try XCTUnwrap(fixture.driver.runs.last)
        fixture.inspector.reset()
        fixture.inspector.open(itemID: next.id, reduceMotion: false)
        old.update(0)
        old.completion()
        fixture.pump()
        XCTAssertEqual(fixture.inspector.snapshot.itemID, next.id)
        XCTAssertTrue(fixture.probe.pasted.isEmpty)
        XCTAssertEqual(fixture.probe.closes, 0)
    }

    func testDeletingPendingPasteItemCancelsBeforeViewUpdate() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let wanted = try context.text("Expires or is deleted while closing")
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: wanted.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        try fixture.clickPaste()
        XCTAssertEqual(fixture.inspector.snapshot.phase, .closing)
        context.store.delete(wanted.id)
        // Deliberately do not pump SwiftUI's onChange before the completion.
        fixture.driver.finishLatest()
        XCTAssertTrue(fixture.probe.pasted.isEmpty)
        XCTAssertEqual(fixture.probe.closes, 0)
    }

    func testScrolledOpenClosePreservesOffset() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        for n in 0..<50 { _ = try context.text("Scrolling item \(n)") }
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        let scroll = try XCTUnwrap(fixture.rows.first?.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1400))
        scroll.reflectScrolledClipView(scroll.contentView); fixture.pump()
        let row = try XCTUnwrap(fixture.rows.first {
            scroll.contentView.bounds.insetBy(dx: 0, dy: 8).contains($0.convert($0.bounds, to: scroll.contentView))
        })
        let id = row.representedItemID
        let offset = scroll.contentView.bounds.minY
        row.rightMouseDown(with: try fixture.event(on: row)); fixture.pump()
        let revision = row.contentRevision
        for p: CGFloat in [0.2, 0.5, 0.9] {
            fixture.driver.emit(p); fixture.pump()
            XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
            XCTAssertEqual(row.contentRevision, revision)
            XCTAssertEqual(row.representedItemID, id)
        }
        fixture.driver.finishLatest()
        fixture.inspector.dismiss(reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
        XCTAssertTrue(fixture.rows.contains { $0 === row })
    }

    func testPinchSurvivesMotion() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.image()
        let fixture = InspectorHUDHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.pump()
        InspectorTestContext.settle(until: {
            InspectorTestContext.descendants(fixture.host.view, DetailImageCanvas.self).first?.isImageReady == true
        })
        let canvas = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, DetailImageCanvas.self).first)
        fixture.driver.emit(0.6); fixture.pump()
        XCTAssertTrue(InspectorTestContext.descendants(fixture.host.view, DetailImageCanvas.self).first === canvas)
        let point = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        XCTAssertTrue(canvas.handleMagnifyEvent(HUDInspectorMagnifyEvent(number: fixture.window.windowNumber, point: point, amount: 0.5)))
        XCTAssertEqual(canvas.viewport.zoom, 1.5, accuracy: 0.001)
        fixture.driver.finishLatest(); fixture.pump()
        XCTAssertEqual(canvas.viewport.zoom, 1.5, accuracy: 0.001)
    }

    func testReducedMotionAndTransparency() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        _ = try context.text()
        let fixture = InspectorHUDHarness(context: context, reduceMotion: true, reduceTransparency: true)
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.rows.first)
        row.rightMouseDown(with: try fixture.event(on: row))
        XCTAssertEqual(fixture.driver.runs.last?.duration ?? -1, 0.11, accuracy: 0.0001)
        fixture.driver.finishLatest(); fixture.pump()
        let bridge = try XCTUnwrap(InspectorTestContext.descendants(fixture.host.view, InspectorEscapeView.self).first)
        XCTAssertTrue(bridge.handleEscape(try fixture.escape()))
        XCTAssertEqual(fixture.driver.runs.last?.duration ?? -1, 0.11, accuracy: 0.0001)
        XCTAssertTrue(fixture.inspector.blocksBackground)
    }
}

private final class HUDInspectorMagnifyEvent: NSEvent {
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
