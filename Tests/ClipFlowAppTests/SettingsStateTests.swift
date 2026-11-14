import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import ClipFlowApp

@MainActor
final class SettingsStateTests: XCTestCase {
    func testBlankExclusionSaveShowsTheStoredDefaults() throws {
        let (store, draft) = try makeDraft()
        draft.excludedAppsText = " \n\t "
        draft.saveExcludedApps(into: store)
        XCTAssertNil(draft.exclusionError)
        XCTAssertEqual(store.excludedBundleIDs, PasswordManagerApps.bundleIDs)
        XCTAssertEqual(draft.excludedAppsText, PasswordManagerApps.bundleIDs.joined(separator: "\n"))
    }

    func testInvalidExclusionSaveKeepsThePreviousListAndNormalizedSaveRewritesTheEditor() throws {
        let (store, draft) = try makeDraft()
        let original = store.excludedBundleIDs
        draft.excludedAppsText = "com.example.editor\nSafari"
        draft.saveExcludedApps(into: store)
        XCTAssertEqual(store.excludedBundleIDs, original)
        XCTAssertEqual(draft.excludedAppsText, "com.example.editor\nSafari")
        XCTAssertEqual(draft.exclusionError, ExcludedAppRules.invalidMessage(["Safari"]))

        draft.excludedAppsText = "  com.example.editor \n\ncom.example.editor\ncom.example.other  "
        draft.saveExcludedApps(into: store)
        XCTAssertEqual(store.excludedBundleIDs, ["com.example.editor", "com.example.other"])
        XCTAssertEqual(draft.excludedAppsText, "com.example.editor\ncom.example.other")
        XCTAssertNil(draft.exclusionError)
        let reloaded = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(reloaded.excludedBundleIDs, ["com.example.editor", "com.example.other"])
    }

    func testBundleIDRulesAcceptTheBuiltInPasswordManagersOnly() {
        for bundleID in PasswordManagerApps.bundleIDs {
            XCTAssertTrue(ExcludedAppRules.isBundleID(bundleID), bundleID)
        }
        XCTAssertFalse(ExcludedAppRules.isBundleID("Safari"))
        XCTAssertFalse(ExcludedAppRules.isBundleID("com..example"))
        XCTAssertFalse(ExcludedAppRules.isBundleID("com.example app"))
        XCTAssertFalse(ExcludedAppRules.isBundleID("com.-bad.app"))
        XCTAssertFalse(ExcludedAppRules.isBundleID("你好.com.app"))
        XCTAssertTrue(ExcludedAppRules.isBundleID("in.sinew.Enpass-Desktop.App"))
    }

    func testEditingClearsAStaleExclusionError() throws {
        let (_, draft) = try makeDraft()
        draft.exclusionError = "无法保存"
        draft.noteExclusionEdits()
        XCTAssertNil(draft.exclusionError)
    }

    func testLaunchAtLoginFailureStaysVisibleAndApprovalStaysOn() throws {
        let (store, _) = try makeDraft()
        store.applyLaunchAtLogin(.needsApproval, failed: false)
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(store.launchAtLoginDetail, LaunchAtLoginStatus.approvalDetail)
        store.applyLaunchAtLogin(.disabled, failed: true)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertFalse(store.launchAtLoginNeedsApproval)
        XCTAssertEqual(store.launchAtLoginDetail, LaunchAtLoginStatus.registrationFailed)
        store.applyLaunchAtLogin(.enabled, failed: false)
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(store.launchAtLoginDetail, LaunchAtLoginStatus.standardDetail)
        store.applyLaunchAtLogin(.unsupported, failed: false)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(store.launchAtLoginDetail, LaunchAtLoginStatus.unsupportedDetail)
        if #available(macOS 13, *) {
            XCTAssertEqual(LaunchAtLoginStatus.resolve(.requiresApproval), .needsApproval)
            XCTAssertEqual(LaunchAtLoginStatus.resolve(.enabled), .enabled)
            XCTAssertEqual(LaunchAtLoginStatus.resolve(.notRegistered), .disabled)
            XCTAssertEqual(LaunchAtLoginStatus.resolve(.notFound), .disabled)
        }
    }

    func testDarkSettingsInkClearsTheDarkBackground() throws {
        let background = try XCTUnwrap(NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1).usingColorSpace(.sRGB))
        let card = try XCTUnwrap(NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1).usingColorSpace(.sRGB))
        let listening = try components(ClipFlowPalette.listeningStatus(for: .dark))
        let paused = try components(ClipFlowPalette.pausedStatus(for: .dark))
        XCTAssertGreaterThanOrEqual(contrast(listening, background), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(paused, background), 4.5)
        let selected = try components(ClipCategory.all.labelColor(for: .dark))
        XCTAssertGreaterThanOrEqual(contrast(selected, card), 4.5)
        let wash = try components(ClipCategory.all.tint)
        let highlight = NSColor(srgbRed: card.redComponent * 0.87 + wash.redComponent * 0.13,
            green: card.greenComponent * 0.87 + wash.greenComponent * 0.13,
            blue: card.blueComponent * 0.87 + wash.blueComponent * 0.13, alpha: 1)
        XCTAssertGreaterThanOrEqual(contrast(selected, highlight), 4.5)
        let cream = try XCTUnwrap(NSColor(srgbRed: 247.0 / 255, green: 246.0 / 255, blue: 244.0 / 255, alpha: 1).usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(contrast(try components(ClipFlowPalette.listeningStatus(for: .light)), cream), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(try components(ClipCategory.all.labelColor(for: .light)), NSColor.white), 4.5)
    }

    func testQuotedPathsStayTogetherAtEveryWidthThatSplitsTheRawCopy() {
        let raw = "将普通文本与图片历史镜像到“文稿/ClipFlow”。如果系统已开启 iCloud Drive 的“桌面与文稿文件夹”，这些内容会随系统同步。"
        let fixed = QuotedCopy.keepingQuotesIntact(raw)
        XCTAssertNotEqual(fixed, raw)
        XCTAssertEqual(fixed.replacingOccurrences(of: "\u{2060}", with: ""), raw)
        XCTAssertTrue(fixed.contains("稿\u{2060}/\u{2060}C"))
        XCTAssertTrue(fixed.contains("夹\u{2060}”"))
        XCTAssertEqual(QuotedCopy.keepingQuotesIntact("open “only"), "open “only")
        let longQuote = "“" + String(repeating: "文", count: QuotedCopy.maximumUnbrokenCount) + "”"
        XCTAssertEqual(QuotedCopy.keepingQuotesIntact(longQuote), longQuote)
        let ascii = QuotedCopy.keepingQuotesIntact("see \"docs/readme\" now")
        XCTAssertEqual(ascii.replacingOccurrences(of: "\u{2060}", with: ""), "see \"docs/readme\" now")
        XCTAssertTrue(ascii.contains("/\u{2060}r"))

        let font = NSFont.systemFont(ofSize: 11)
        let utf16 = fixed as NSString
        let quoteStart = utf16.range(of: "“").location
        let quoteEnd = utf16.range(of: "”").location
        XCTAssertLessThan(quoteStart, quoteEnd)
        var protected = false
        for width in stride(from: 80.0, to: 360.0, by: 8) {
            let breaks = lineBreakIndexes(fixed, width: width, font: font)
            let inside = breaks.contains { $0 > quoteStart && $0 < quoteEnd }
            XCTAssertFalse(inside, "Quoted path broke at width \(width)")
            let rawLines = lineFragments(raw, width: width, font: font)
            if rawLines.contains(where: { $0.contains("文稿/") && !$0.contains("ClipFlow") }) {
                protected = true
            }
        }
        XCTAssertTrue(protected, "Expected a width where the raw path splits after the slash")
    }

    func testLeavingSettingsDisarmsTheShortcutRecorder() throws {
        _ = NSApplication.shared
        let (store, _) = try makeDraft()
        store.registerShortcut = { _ in nil }
        store.suspendShortcut = {}
        let controller = MainWindowController(store: store, locale: Locale(identifier: "zh-Hans"), initialPage: .settings)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let button = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView), ShortcutRecorderButton.self).first)
        button.performClick(nil)
        XCTAssertTrue(store.isRecordingShortcut)
        XCTAssertTrue(button.isCapturing)
        controller.navigation.select(.history)
        XCTAssertFalse(store.isRecordingShortcut)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(button.isCapturing, "The hidden recorder must drop its key monitor when recording ends")
        controller.navigation.selectSettings(.general)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        button.performClick(nil)
        XCTAssertTrue(store.isRecordingShortcut)
        XCTAssertTrue(button.isCapturing)
        store.endShortcutRecording()
    }

    private var directory: URL!
    private var defaults: UserDefaults!

    private func makeDraft() throws -> (ClipFlowStore, SettingsDraft) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipFlowSettings.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [directory, defaults] in
            defaults?.removePersistentDomain(forName: suite)
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults)
        return (store, SettingsDraft(store: store))
    }

    private func lineBreakIndexes(_ text: String, width: CGFloat, font: NSFont) -> [Int] {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = (text as NSString).length
        var start = 0
        var indexes: [Int] = []
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { break }
            start += count
            if start < length { indexes.append(start) }
        }
        return indexes
    }

    private func lineFragments(_ text: String, width: CGFloat, font: NSFont) -> [String] {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let utf16 = text as NSString
        var start = 0
        var lines: [String] = []
        while start < utf16.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { break }
            lines.append(utf16.substring(with: NSRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    private func components(_ color: Color) throws -> NSColor {
        try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: NSColor) -> CGFloat {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent) + 0.0722 * channel(srgb.blueComponent)
        }
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
