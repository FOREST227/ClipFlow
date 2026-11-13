import AppKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class RecordingAccessibilityTrust: AccessibilityTrustChecking {
    var trusted: Bool
    private(set) var prompts: [Bool] = []

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted(prompt: Bool) -> Bool {
        prompts.append(prompt)
        return trusted
    }
}

@MainActor
final class AccessibilityPromptTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClipFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults)
    }

    private func makeStore(trusted: Bool) throws -> (ClipFlowStore, RecordingAccessibilityTrust) {
        let (directory, defaults) = try fixture()
        let trust = RecordingAccessibilityTrust(trusted: trusted)
        let store = ClipFlowStore(storageDirectory: directory, defaults: defaults, accessibility: trust)
        store.autoProtectSecrets = false
        return (store, trust)
    }

    func testLaunchDoesNotPromptAndFirstPasteDoes() throws {
        let (store, trust) = try makeStore(trusted: false)
        store.start()
        XCTAssertEqual(trust.prompts, [false])
        XCTAssertEqual(store.accessibilityTrusted, false)
        XCTAssertEqual(store.startupPermissionReport?.title, "启动时发现权限未完整")
        XCTAssertTrue(store.startupPermissionReport?.message.contains("静默") == true)
        XCTAssertTrue(store.startupPermissionReport?.items.contains {
            $0.title == "辅助功能" && $0.detail.contains("系统设置 → 隐私与安全性 → 辅助功能")
        } == true)

        store.ingestCopiedText("hello clipboard", sourceApp: "Editor", sourceBundleID: nil)
        XCTAssertEqual(trust.prompts, [false])
        let item = try XCTUnwrap(store.items.first)
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        var committed = 0
        let service = PasteService(store: store, pasteboard: pasteboard, commitPaste: { _ in committed += 1 })

        service.paste(item, preferredTarget: nil)

        XCTAssertEqual(trust.prompts, [false, true])
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello clipboard")
        XCTAssertTrue(store.lastCaptureStatus.contains("剪贴板"))
        XCTAssertEqual(store.startupPermissionReport?.title, "自动粘贴需要辅助功能")
        XCTAssertEqual(store.accessibilityTrusted, false)
        XCTAssertTrue(service.copyToClipboard(item))
        XCTAssertEqual(trust.prompts, [false, true])
    }

    func testTrustedPasteStillPromptsCheckWithoutDegrading() throws {
        let (store, trust) = try makeStore(trusted: true)
        store.start()
        XCTAssertEqual(trust.prompts, [false])
        XCTAssertEqual(store.accessibilityTrusted, true)
        XCTAssertNil(store.startupPermissionReport)

        store.ingestCopiedText("hello clipboard", sourceApp: "Editor", sourceBundleID: nil)
        let item = try XCTUnwrap(store.items.first)
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        var committed = 0
        let service = PasteService(store: store, pasteboard: pasteboard, commitPaste: { _ in committed += 1 })

        service.paste(item, preferredTarget: nil)

        XCTAssertEqual(trust.prompts, [false, true])
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello clipboard")
        XCTAssertTrue(store.lastCaptureStatus.hasPrefix("已粘贴"))
        XCTAssertNil(store.startupPermissionReport)
    }

    func testExplicitAccessibilityRequestPromptsAndRefreshStaysSilent() throws {
        let (store, trust) = try makeStore(trusted: false)
        store.start()
        XCTAssertEqual(trust.prompts, [false])

        store.requestAccessibilityPermissionPrompt()

        XCTAssertEqual(trust.prompts, [false, true, false])
        XCTAssertEqual(store.accessibilityTrusted, false)
    }

    func testOpenAccessibilitySettingsUsesPrivacyPaneAndStopsAfterSuccess() {
        let urls = AccessibilityTrust.settingsURLs()
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains("Privacy_Accessibility") })

        var opened: [URL] = []
        XCTAssertTrue(AccessibilityTrust.openSystemSettings { url in
            opened.append(url)
            return true
        })
        XCTAssertEqual(opened, [urls[0]])
    }

    func testOpenAccessibilitySettingsTriesTheNextPaneWhenTheFirstFails() {
        let urls = AccessibilityTrust.settingsURLs()
        var opened: [URL] = []
        XCTAssertTrue(AccessibilityTrust.openSystemSettings { url in
            opened.append(url)
            return opened.count == urls.count
        })
        XCTAssertEqual(opened, urls)
    }
}
