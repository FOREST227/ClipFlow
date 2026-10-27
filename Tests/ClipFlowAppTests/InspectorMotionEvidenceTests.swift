import AppKit
import SwiftUI
import XCTest
@testable import ClipFlowApp

/// Explicit opt-in evidence export; never reads personal history or installs the app.
@MainActor
final class InspectorMotionEvidenceTests: XCTestCase {
    func testExportMotionEvidence() throws {
        let environment = ProcessInfo.processInfo.environment
        if let readyPath = environment["CLIPFLOW_MOTION_PROFILE_READY"] {
            try profileNativeDriver(readyPath: readyPath)
            return
        }
        guard let path = environment["CLIPFLOW_MOTION_CAPTURE_DIR"] else {
            throw XCTSkip("Set CLIPFLOW_MOTION_CAPTURE_DIR or CLIPFLOW_MOTION_PROFILE_READY for motion evidence")
        }
        let output = URL(fileURLWithPath: path)
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = previousAppearance }
        _ = try context.text("https://example.com/project")
        _ = try context.text("func greeting(_ name: String) -> String {\n    return \"Hello, \\(name)!\"\n}\n\nprint(greeting(\"ClipFlow\"))")
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let icon = try Data(contentsOf: project.appendingPathComponent("assets/icon/ClipFlow-icon-1024.png"))
        context.store.ingestCopiedImage(icon, size: CGSize(width: 1024, height: 1024),
            sourceApp: "预览", sourceBundleID: nil)
        let image = try XCTUnwrap(context.store.items.first)
        _ = try context.text("ClipFlow 品牌设计：暖金、雾蓝，与顺畅的工作节奏。")
        let history = HistoryInspectorHarness(context: context, showsBackground: true)
        defer { history.close() }
        context.store.select(image)
        history.pump()
        try export(view: history.host.view, state: history.inspector, driver: history.driver, itemID: image.id,
            directory: output.appendingPathComponent("history"), pump: history.pump)
        let hud = InspectorHUDHarness(context: context)
        defer { hud.close() }
        try export(view: hud.host.view, state: hud.inspector, driver: hud.driver, itemID: image.id,
            directory: output.appendingPathComponent("quick-paste"), pump: hud.pump)
        try "Native SwiftUI/AppKit component frames, synthetic data, deterministic progress at 60 samples/sec. Not a frame-rate benchmark.\n".write(
            to: output.appendingPathComponent("CAPTURE.txt"), atomically: true, encoding: .utf8)
    }

    private func export(view: NSView, state: InspectorPresentation, driver: ManualInspectorDriver,
                        itemID: UUID, directory: URL, pump: () -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = 0
        func capture() throws {
            pump()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(String(format: "frame-%03d.png", index)))
            index += 1
        }
        // Holds repeat an already-rendered image; only transitions require fresh rendering.
        func hold(_ count: Int) throws {
            try capture()
            let previous = directory.appendingPathComponent(String(format: "frame-%03d.png", index - 1))
            for _ in 1..<count {
                try FileManager.default.copyItem(at: previous,
                    to: directory.appendingPathComponent(String(format: "frame-%03d.png", index)))
                index += 1
            }
        }
        try hold(45)
        let source = try XCTUnwrap(InspectorTestContext.descendants(view, ClipboardRowHitView.self)
            .first { $0.identifier?.rawValue == itemID.uuidString })
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 10, windowNumber: try XCTUnwrap(source.window).windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        source.rightMouseDown(with: event)
        XCTAssertEqual(state.snapshot.itemID, itemID)
        for step in 1...17 { driver.emit(CGFloat(step) / 17); try capture() }
        driver.finishLatest()
        try hold(45)
        state.dismiss(reduceMotion: false)
        for step in 1...12 { driver.emit(1 - CGFloat(step) / 12); try capture() }
        driver.finishLatest()
        try hold(45)
        XCTAssertFalse(state.blocksBackground)
    }

    private func profileNativeDriver(readyPath: String) throws {
        let context = try InspectorTestContext()
        defer { context.cleanup() }
        let item = try context.text("func motionExample() {\n    print(\"ClipFlow\")\n}")
        let state = InspectorPresentation(driver: AppKitInspectorAnimationDriver())
        let host = NSHostingController(rootView: QuickPastePanelView(store: context.store,
            preferredTargetName: nil, onPaste: { _ in }, onOpenLibrary: {}, onClose: {}, inspector: state))
        let window = QuickPastePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 588),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "ClipFlow 动效验收"
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { state.reset(); window.close() }
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
        let end = Date().addingTimeInterval(35)
        var opens = 0
        while Date() < end {
            if state.snapshot.phase == .closed {
                opens += 1
                state.open(itemID: item.id, reduceMotion: false)
            } else if state.snapshot.phase == .open {
                state.dismiss(reduceMotion: false)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            // XCTest pumps a RunLoop rather than NSApplication.run(). Deliver the
            // normal AppKit display pass for an on-screen, non-rasterized profile.
            NSApp.updateWindows()
            window.displayIfNeeded()
        }
        XCTAssertGreaterThan(opens, 5)
        print("Production NSAnimation cycles:", opens)
    }
}
