import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class InspectorLifecycleTests: XCTestCase {
    func testClosingRetainedHistoryWindowCancelsPendingAction() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("Lifecycle fixture")
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        var calls = 0
        fixture.inspector.dismiss(reduceMotion: false) { calls += 1 }
        fixture.window.close()
        fixture.pump()
        print("REVIEW closed-window visible=\(fixture.window.isVisible) phase=\(fixture.inspector.snapshot.phase)")
        fixture.driver.finishLatest(); fixture.pump()
        print("REVIEW closed-window callback-count=\(calls)")
        XCTAssertEqual(calls, 0, "Pending history action must cancel when its window closes")
    }

    func testResigningHistoryWindowCancelsPendingAction() throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("Lifecycle fixture")
        let fixture = HistoryInspectorHarness(context: context)
        defer { fixture.close() }
        fixture.inspector.open(itemID: item.id, reduceMotion: false)
        fixture.driver.finishLatest(); fixture.pump()
        var calls = 0
        fixture.inspector.dismiss(reduceMotion: false) { calls += 1 }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        fixture.pump()
        fixture.driver.finishLatest(); fixture.pump()
        print("REVIEW resigned-window callback-count=\(calls)")
        XCTAssertEqual(calls, 0, "Pending history action must cancel on loss of window focus")
    }

    func testHiddenHistoryPageMustNotConsumeEscape() throws {
        _ = NSApplication.shared
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        _ = try context.text("Hidden page fixture")
        let controller = MainWindowController(store: context.store, locale: Locale(identifier: "zh-Hans"))
        controller.show(page: .history)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        InspectorTestContext.settle(until: { !InspectorTestContext.descendants(host, LibraryInteractiveHostingView.self).isEmpty })
        let row = try XCTUnwrap(InspectorTestContext.descendants(host, LibraryInteractiveHostingView.self).first)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        row.rightMouseDown(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        controller.navigation.select(.settings)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let bridge = try XCTUnwrap(InspectorTestContext.descendants(host, InspectorEscapeView.self).first)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let recorder = try XCTUnwrap(InspectorTestContext.descendants(host, ShortcutRecorderButton.self).first)
        context.store.registerShortcut = { _ in nil }
        context.store.suspendShortcut = {}
        recorder.performClick(nil)
        XCTAssertTrue(context.store.isRecordingShortcut)
        NSApp.sendEvent(escape)
        print("REVIEW settings-recorder-still-recording-after-escape=\(context.store.isRecordingShortcut)")
        XCTAssertFalse(context.store.isRecordingShortcut, "Escape must cancel visible Settings shortcut recorder")
        let handled = bridge.handleEscape(escape)
        print("REVIEW settings-page hidden-inspector-consumed-escape=\(handled)")
        XCTAssertFalse(handled, "Hidden history inspector must not intercept Settings keyboard input")
    }
}
