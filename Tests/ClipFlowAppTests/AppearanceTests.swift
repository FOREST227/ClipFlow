import AppKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class AppearanceTests: XCTestCase {
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
