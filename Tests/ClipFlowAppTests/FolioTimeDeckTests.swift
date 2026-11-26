import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class FolioTimeDeckTests: XCTestCase {
    private func makeStore() throws -> (ClipFlowStore, URL, UserDefaults, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipFlowFolioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        return (store, directory, defaults, suite)
    }

    func testDefaultLibraryViewModeIsDeckAndPersists() throws {
        let (store, directory, defaults, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(store.libraryViewMode, .deck)
        store.libraryViewMode = .list
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(reloaded.libraryViewMode, .list)
    }

    func testPasteStackSequentialFIFOPopAutoCollectAndPruning() throws {
        let (store, directory, defaults, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        store.pasteStack.autoCollectEnabled = true
        store.ingestCopiedText("First snippet", sourceApp: "Xcode", sourceBundleID: nil)
        store.ingestCopiedText("Second snippet", sourceApp: "Safari", sourceBundleID: nil)
        store.ingestCopiedText("Third snippet", sourceApp: "Notes", sourceBundleID: nil)

        let queued = store.pasteStack.queuedItems(from: store.items)
        XCTAssertEqual(queued.map(\.fullText), ["First snippet", "Second snippet", "Third snippet"])

        // Deleting middle item automatically prunes it from Paste Stack
        store.delete(queued[1].id)
        XCTAssertEqual(store.pasteStack.queuedItems(from: store.items).map(\.fullText), ["First snippet", "Third snippet"])

        // FIFO pop order
        let firstOut = store.pasteStack.popNext(from: store.items)
        XCTAssertEqual(firstOut?.fullText, "First snippet")
        let secondOut = store.pasteStack.popNext(from: store.items)
        XCTAssertEqual(secondOut?.fullText, "Third snippet")
        XCTAssertNil(store.pasteStack.popNext(from: store.items))
    }

    func testFolioTimeDeckRendersAndSwitchesSelectionWithoutStoreBroadcast() throws {
        _ = NSApplication.shared
        let (store, directory, defaults, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        for index in 0..<6 {
            store.ingestCopiedText("func step\(index)() {}", sourceApp: "Xcode", sourceBundleID: nil)
        }

        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        var storeBroadcasts = 0
        let obs = store.objectWillChange.sink { storeBroadcasts += 1 }
        let filtered = store.filteredItems
        for item in filtered {
            store.select(item)
            store.pasteStack.toggle(item.id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(storeBroadcasts, 0, "Flipping deck cards or queuing into Paste Stack must not broadcast global ClipFlowStore changes")
        withExtendedLifetime(obs) {}
    }

    func testScreenEdgePeekDockingCollapsesAndRestoresWindowFrame() throws {
        _ = NSApplication.shared
        let (store, directory, defaults, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"))
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: 220, y: 180))
        window.orderFront(nil)
        defer { window.close() }

        let initialFrame = window.frame
        XCTAssertFalse(controller.navigation.isEdgeDocked)

        controller.setEdgeDocked(true, animated: false)
        XCTAssertTrue(controller.navigation.isEdgeDocked)
        XCTAssertFalse(window.isVisible)
        let peekPanel = try XCTUnwrap(controller.edgePeekPanel)
        XCTAssertTrue(peekPanel.isVisible)
        XCTAssertEqual(peekPanel.frame.width, MainWindowController.edgePeekVisibleWidth, accuracy: 1)

        controller.setEdgeDocked(false, animated: false)
        XCTAssertFalse(controller.navigation.isEdgeDocked)
        XCTAssertNil(controller.edgePeekPanel)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame.origin.x, initialFrame.origin.x, accuracy: 1)
    }

    func testHexSwatchParserAndCountdownFormatting() {
        let parsed = HexSwatchParser.parse(from: "Brand token #527966")
        XCTAssertEqual(parsed?.hex, "#527966")
        XCTAssertNil(HexSwatchParser.parse(from: "No color here"))
        XCTAssertEqual(ExpiryCountdownRing.format(seconds: 258), "04:18")
        XCTAssertEqual(ExpiryCountdownRing.format(seconds: 0), "00:00")
    }

    func testTimeDialAnchorsDeduplicateIdenticalTimestamps() throws {
        let (store, directory, defaults, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        for i in 1...9 {
            store.ingestCopiedText("Note \(i)", sourceApp: "Notes", sourceBundleID: nil)
        }
        let anchors = FolioTimeDialView.buildAnchors(for: store.items)
        XCTAssertEqual(anchors.count, 4)
        XCTAssertEqual(anchors.first?.label, "现在")
        let uniqueLabels = Set(anchors.map(\.label))
        XCTAssertEqual(uniqueLabels.count, anchors.count, "Time dial anchors must never repeat identical relative-time strings")
    }

    func testPrewarmQuickPasteAssetsHandlesOutOfBoundsIndicesSafely() throws {
        let (store, directory, defaults, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        for i in 1...60 {
            store.ingestCopiedText("Entry \(i)", sourceApp: "Notes", sourceBundleID: nil)
        }
        // Center index exceeding quickPasteItems cap (50), negative indices, and zero limit must never trap.
        store.prewarmQuickPasteAssets(around: 59, limit: 16)
        store.prewarmQuickPasteAssets(around: 999, limit: 16)
        store.prewarmQuickPasteAssets(around: -10, limit: 16)
        store.prewarmQuickPasteAssets(around: 59, limit: 16, in: store.items)
        store.prewarmQuickPasteAssets(around: 0, limit: 0)
    }

    func testScrollMonitorsYieldToCardDetailAndImageWheelZoomWorks() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }

        // 1. Quick Paste carousel scroll monitor yields when detail inspector blocks background
        let carouselMonitor = CarouselPointerMonitorView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView?.addSubview(carouselMonitor)
        var carouselSteps: [Int] = []
        carouselMonitor.onDiscreteStep = { carouselSteps.append($0) }
        carouselMonitor.isBlocked = true

        let wheelEvent = TestScrollWheelEvent(
            windowNumber: window.windowNumber,
            point: NSPoint(x: 320, y: 210),
            deltaY: 4
        )
        XCTAssertFalse(carouselMonitor.handleScroll(wheelEvent), "Carousel must yield scroll events while card detail is open")
        XCTAssertTrue(carouselSteps.isEmpty)
        carouselMonitor.removeFromSuperview()

        // 2. Folio deck scroll monitor yields when blocked, steps when unblocked
        let folioMonitor = FolioDeckScrollMonitorView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView?.addSubview(folioMonitor)
        var folioSteps: [Int] = []
        folioMonitor.onStep = { folioSteps.append($0) }
        folioMonitor.isBlocked = true
        XCTAssertFalse(folioMonitor.handle(wheelEvent), "Folio deck must yield scroll events while card detail is open")
        XCTAssertTrue(folioSteps.isEmpty)

        folioMonitor.isBlocked = false
        XCTAssertTrue(folioMonitor.handle(wheelEvent), "Folio deck handles scroll wheel when no detail overlay is open")
        XCTAssertEqual(folioSteps, [-1])
        folioMonitor.removeFromSuperview()

        // 3. DetailImageCanvas responds to scrollWheel by zooming smoothly
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = DetailImageCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView?.addSubview(canvas)
        defer { canvas.cancelLoading(); canvas.removeFromSuperview() }
        canvas.load(url)
        for _ in 0..<100 {
            if canvas.isImageReady { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(canvas.isImageReady)
        XCTAssertEqual(canvas.viewport.zoom, 1, accuracy: 0.001)

        canvas.scrollWheel(with: TestScrollWheelEvent(
            windowNumber: window.windowNumber,
            point: NSPoint(x: 160, y: 120),
            deltaY: 5
        ))
        XCTAssertGreaterThan(canvas.viewport.zoom, 1.3, "Scroll wheel up must zoom into detail image")

        canvas.scrollWheel(with: TestScrollWheelEvent(
            windowNumber: window.windowNumber,
            point: NSPoint(x: 160, y: 120),
            deltaY: -10
        ))
        XCTAssertEqual(canvas.viewport.zoom, 1.0, accuracy: 0.001, "Scroll wheel down clamps back to 100%")
    }

    func testTopToBottomDeckGeometryOrdersNewestAtTopAndOldestAtBottom() {
        let rearCount = 5
        let frontCount = 4
        let topMargin: CGFloat = 4
        let rearStep: CGFloat = 20
        let frontStep: CGFloat = 28
        let frontStartY: CGFloat = 404

        // Progress = 0 (#01 selected): #01 sits at topMargin; #02..#05 sit below in ascending Y order.
        let extractedAt0 = topMargin
        let y0_at0 = FolioTimeDeckView.interpolatedTopY(
            slotDelta: 0, rearCount: rearCount, frontCount: frontCount,
            rearStep: rearStep, frontStep: frontStep, extractedTopY: extractedAt0, frontStartY: frontStartY
        )
        let y1_at0 = FolioTimeDeckView.interpolatedTopY(
            slotDelta: -1, rearCount: rearCount, frontCount: frontCount,
            rearStep: rearStep, frontStep: frontStep, extractedTopY: extractedAt0, frontStartY: frontStartY
        )
        let y2_at0 = FolioTimeDeckView.interpolatedTopY(
            slotDelta: -2, rearCount: rearCount, frontCount: frontCount,
            rearStep: rearStep, frontStep: frontStep, extractedTopY: extractedAt0, frontStartY: frontStartY
        )
        XCTAssertEqual(y0_at0, 4, accuracy: 0.001)
        XCTAssertLessThan(y0_at0, y1_at0)
        XCTAssertLessThan(y1_at0, y2_at0)

        // Progress = 5 (#06 selected): #01 (slotDelta +5) at very top -> #06 (0) -> #07 (-1) -> #10 (-4) at bottom.
        let extractedAt5 = topMargin + rearStep * 5
        let yNewest = FolioTimeDeckView.interpolatedTopY(
            slotDelta: 5, rearCount: rearCount, frontCount: frontCount,
            rearStep: rearStep, frontStep: frontStep, extractedTopY: extractedAt5, frontStartY: frontStartY
        )
        let yActive = FolioTimeDeckView.interpolatedTopY(
            slotDelta: 0, rearCount: rearCount, frontCount: frontCount,
            rearStep: rearStep, frontStep: frontStep, extractedTopY: extractedAt5, frontStartY: frontStartY
        )
        let yOlder = FolioTimeDeckView.interpolatedTopY(
            slotDelta: -1, rearCount: rearCount, frontCount: frontCount,
            rearStep: rearStep, frontStep: frontStep, extractedTopY: extractedAt5, frontStartY: frontStartY
        )
        XCTAssertEqual(yNewest, 4, accuracy: 0.001)
        XCTAssertEqual(yActive, 104, accuracy: 0.001)
        XCTAssertEqual(yOlder, frontStartY, accuracy: 0.001)
        XCTAssertLessThan(yNewest, yActive)
        XCTAssertLessThan(yActive, yOlder)
    }

    func testTimeDialBeadHoverDetectionRadius() {
        let center = CGPoint(x: 9, y: 120)
        XCTAssertTrue(TimeDialScrubNSView.isPointNearBead(CGPoint(x: 9, y: 120), beadCenter: center))
        XCTAssertTrue(TimeDialScrubNSView.isPointNearBead(CGPoint(x: 18, y: 128), beadCenter: center))
        XCTAssertFalse(TimeDialScrubNSView.isPointNearBead(CGPoint(x: 40, y: 120), beadCenter: center))
        XCTAssertFalse(TimeDialScrubNSView.isPointNearBead(CGPoint(x: 9, y: 160), beadCenter: center))
    }

    func testCarouselScrollModelDoesNotTwitchPastTopOrBottomBoundary() {
        let model = CarouselScrollModel()
        model.jump(to: 0)

        // Scrolling further past top boundary (0) stays rock-solid with zero negative progress or interaction flicker.
        for _ in 0..<10 {
            model.applyContinuousDelta(-0.25, isMomentum: false, maxIndex: 10, reduceMotion: false) { _ in }
            XCTAssertEqual(model.progress, 0, accuracy: 0.0001)
            XCTAssertFalse(model.isInteracting)
        }
        model.animateTo(index: 0, maxIndex: 10, reduceMotion: false)
        XCTAssertEqual(model.progress, 0, accuracy: 0.0001)
        XCTAssertFalse(model.isInteracting)

        // Scrolling further past bottom boundary (10) stays rock-solid with zero overshoot or interaction flicker.
        model.jump(to: 10)
        for _ in 0..<10 {
            model.applyContinuousDelta(0.25, isMomentum: false, maxIndex: 10, reduceMotion: false) { _ in }
            XCTAssertEqual(model.progress, 10, accuracy: 0.0001)
            XCTAssertFalse(model.isInteracting)
        }
        model.animateTo(index: 10, maxIndex: 10, reduceMotion: false)
        XCTAssertEqual(model.progress, 10, accuracy: 0.0001)
        XCTAssertFalse(model.isInteracting)
    }

    func testStatusBarIconRendersArchivalCardBoxTemplate() throws {
        let active = ClipFlowStatusBarIcon.make(paused: false)
        let paused = ClipFlowStatusBarIcon.make(paused: true)
        XCTAssertEqual(active.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(paused.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(active.isTemplate)
        XCTAssertTrue(paused.isTemplate)
        XCTAssertNotNil(active.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotNil(paused.cgImage(forProposedRect: nil, context: nil, hints: nil))

        if let previewPath = ProcessInfo.processInfo.environment["CLIPFLOW_STATUS_ICON_PREVIEW"] {
            let canvasSize = NSSize(width: 480, height: 180)
            let canvas = NSImage(size: canvasSize, flipped: false) { _ in
                // Left half: Light Menu Bar (#F3EFE8); Right half: Dark Menu Bar (#1E2026)
                NSColor(srgbRed: 0.953, green: 0.937, blue: 0.910, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: 240, height: 180).fill()
                NSColor(srgbRed: 0.118, green: 0.125, blue: 0.149, alpha: 1).setFill()
                NSRect(x: 240, y: 0, width: 240, height: 180).fill()

                func drawTinted(_ img: NSImage, in rect: NSRect, color: NSColor) {
                    let copy = img.copy() as! NSImage
                    copy.isTemplate = false
                    let tinted = NSImage(size: rect.size, flipped: false) { r in
                        copy.draw(in: r)
                        color.setFill()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: rect)
                }

                // Draw at 3x (54pt) and real 2x (36pt) for both active & paused on Light & Dark
                drawTinted(active, in: NSRect(x: 34, y: 66, width: 72, height: 72), color: NSColor(white: 0.10, alpha: 0.92))
                drawTinted(paused, in: NSRect(x: 134, y: 66, width: 72, height: 72), color: NSColor(white: 0.10, alpha: 0.92))
                drawTinted(active, in: NSRect(x: 58, y: 20, width: 24, height: 24), color: NSColor(white: 0.10, alpha: 0.92))
                drawTinted(paused, in: NSRect(x: 158, y: 20, width: 24, height: 24), color: NSColor(white: 0.10, alpha: 0.92))

                drawTinted(active, in: NSRect(x: 274, y: 66, width: 72, height: 72), color: NSColor(white: 0.98, alpha: 0.95))
                drawTinted(paused, in: NSRect(x: 374, y: 66, width: 72, height: 72), color: NSColor(white: 0.98, alpha: 0.95))
                drawTinted(active, in: NSRect(x: 298, y: 20, width: 24, height: 24), color: NSColor(white: 0.98, alpha: 0.95))
                drawTinted(paused, in: NSRect(x: 398, y: 20, width: 24, height: 24), color: NSColor(white: 0.98, alpha: 0.95))
                return true
            }
            if let tiff = canvas.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: previewPath))
            }
        }
    }
}

private final class TestScrollWheelEvent: NSEvent {
    private let number: Int
    private let point: NSPoint
    private let dy: CGFloat

    init(windowNumber: Int, point: NSPoint, deltaY: CGFloat) {
        self.number = windowNumber
        self.point = point
        self.dy = deltaY
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { point }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}
