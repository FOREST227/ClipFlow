import AppKit
import QuartzCore
import XCTest
@testable import ClipFlowApp

@MainActor
final class AppearanceTests: XCTestCase {
    func testLegacyAppearancePreferencesArePreserved() throws {
        let suite = "ClipFlowAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "appearanceMode")
        XCTAssertEqual(ClipFlowAppearance.load(from: defaults), .light)
        defaults.set(2, forKey: "appearanceMode")
        XCTAssertEqual(ClipFlowAppearance.load(from: defaults), .dark)
        defaults.set(0, forKey: "appearanceMode")
        XCTAssertEqual(ClipFlowAppearance.load(from: defaults), .system)
    }

    func testEquivalentResolvedColorsDoNotCrossfade() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let vibrantLight = try XCTUnwrap(NSAppearance(named: .vibrantLight))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let vibrantDark = try XCTUnwrap(NSAppearance(named: .vibrantDark))
        XCTAssertFalse(AppearanceTransition.needsCrossfade(from: light, to: vibrantLight))
        XCTAssertFalse(AppearanceTransition.needsCrossfade(from: dark, to: vibrantDark))
        XCTAssertTrue(AppearanceTransition.needsCrossfade(from: light, to: dark))
        XCTAssertTrue(AppearanceTransition.needsCrossfade(from: dark, to: light))
    }

    func testFollowingSystemWithMatchingColorDoesNotCrossfade() throws {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        application.appearance = nil
        let system = application.effectiveAppearance
        let matchingName = try XCTUnwrap(system.bestMatch(from: [.aqua, .darkAqua]))
        application.appearance = NSAppearance(named: matchingName)
        let manual = application.effectiveAppearance
        application.appearance = nil
        XCTAssertFalse(AppearanceTransition.needsCrossfade(from: manual, to: application.effectiveAppearance))
    }

    func testSwitchingAppearanceDoesNotSynchronouslyRasterizeWindow() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let application = NSApplication.shared
        let original = application.appearance
        let controller = NSViewController()
        let content = AppearanceRasterizationSpy(frame: NSRect(x: 0, y: 0, width: 500, height: 660))
        controller.view = content
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            application.appearance = original
        }
        content.wantsLayer = true
        window.orderFront(nil)
        window.displayIfNeeded()
        XCTAssertNotNil(content.layer)
        let transition = AppearanceTransition()
        transition.apply(.light)
        let initialCount = content.snapshotRequests
        let start = CACurrentMediaTime()
        transition.apply(.dark)
        print("Appearance apply synchronous time: \(CACurrentMediaTime() - start)s")
        XCTAssertEqual(content.snapshotRequests, initialCount,
            "Appearance switching must not rasterize the window on the input event thread")
        XCTAssertEqual(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNotNil(content.layer?.animation(forKey: AppearanceTransition.animationKey))
        transition.apply(.light)
        transition.apply(.system)
        XCTAssertNil(application.appearance)
        let systemIsDark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        transition.apply(systemIsDark ? .dark : .light)
        transition.apply(.system)
        XCTAssertNil(content.layer?.animation(forKey: AppearanceTransition.animationKey),
            "Matching System appearance must remove any in-flight fade without starting another")
        XCTAssertEqual(content.snapshotRequests, initialCount)
    }

    func testAppearancePersistsAndSystemModeClearsOverride() throws {
        let suite = "ClipFlowAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.appearanceMode, .system)
        store.appearanceMode = .light
        XCTAssertEqual(ClipFlowStore(storageDirectory: directory, defaults: defaults).appearanceMode, .light)
        XCTAssertEqual(store.appearanceMode.appKitAppearance?.name, .aqua)
        store.appearanceMode = .dark
        XCTAssertEqual(ClipFlowStore(storageDirectory: directory, defaults: defaults).appearanceMode, .dark)
        XCTAssertEqual(store.appearanceMode.appKitAppearance?.name, .darkAqua)
        store.appearanceMode = .system
        XCTAssertEqual(ClipFlowStore(storageDirectory: directory, defaults: defaults).appearanceMode, .system)
        XCTAssertNil(store.appearanceMode.appKitAppearance)
    }

    func testUnrecognizedSavedAppearanceFallsBackToSystem() throws {
        let suite = "ClipFlowAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("unknown", forKey: "appearanceMode")
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.appearanceMode, .system)
    }
}

@MainActor
private final class AppearanceRasterizationSpy: NSView {
    var snapshotRequests = 0
    override func bitmapImageRepForCachingDisplay(in rect: NSRect) -> NSBitmapImageRep? {
        snapshotRequests += 1
        return super.bitmapImageRepForCachingDisplay(in: rect)
    }
}
