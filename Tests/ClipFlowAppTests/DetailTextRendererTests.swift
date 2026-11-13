import AppKit
import WebKit
import XCTest
@testable import ClipFlowApp

@MainActor
final class DetailTextRendererTests: XCTestCase {
    func testNavigationPolicyIsRegisteredWithWebKit() {
        let coordinator = DetailTextRenderer.Coordinator()
        XCTAssertTrue(coordinator.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
    }

    private func rendered(_ text: String, markdown: Bool, language: String = "自动识别") async throws -> WKWebView {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let navigation = DetailTextRenderer.Coordinator()
        web.navigationDelegate = navigation
        defer { withExtendedLifetime(navigation) {} }
        web.loadHTMLString(DetailTextDocument.html(text: text, markdown: markdown, language: language, dark: false), baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('content')?.textContent.length > 0")) as? Bool == true {
                return web
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Offline renderer did not produce content")
        return web
    }
    func testOfflineLanguagesAndPowerShellHighlight() async throws {
        let source = "Get-ChildItem -Path C:\\Users | Where-Object { $_.Length -gt 10 }"
        let web = try await rendered(source, markdown: false)
        let content = try await web.evaluateJavaScript("document.querySelector('pre code').textContent") as? String
        XCTAssertEqual(content, source)
        let spans = try await web.evaluateJavaScript("document.querySelectorAll('pre code span').length") as? Int
        XCTAssertGreaterThan(spans ?? 0, 0)
        let supported = try await web.evaluateJavaScript("hljs.listLanguages()") as? [String] ?? []
        for language in DetailTextFormat.languages where language != "自动识别" {
            let known = try await web.evaluateJavaScript("!!hljs.getLanguage('\(language)')") as? Bool
            XCTAssertEqual(known, true, "Missing \(language); installed: \(supported)")
        }
    }
    func testMarkdownPreviewAndUntrustedHTMLStaySafe() async throws {
        let fence = String(repeating: "\u{60}", count: 3)
        let source = "# 标题\n\n- 项目\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n<script>window.pwned=1</script>\n\n![remote](https://example.com/tracker.png)\n\n\(fence)swift\nlet value = 1\n\(fence)"
        let web = try await rendered(source, markdown: true)
        let heading = try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(heading, "标题")
        let table = try await web.evaluateJavaScript("document.querySelectorAll('table').length") as? Int
        XCTAssertEqual(table, 1)
        let injected = try await web.evaluateJavaScript("typeof window.pwned === 'undefined'") as? Bool
        XCTAssertEqual(injected, true)
        let images = try await web.evaluateJavaScript("document.querySelectorAll('img,iframe').length") as? Int
        XCTAssertEqual(images, 0)
    }
    func testMissingRendererResourceFallsBackAndLogs() throws {
        var messages: [String] = []
        XCTAssertEqual(
            DetailTextDocument.load(name: "missing.js", installedRoot: nil, moduleRoot: nil, log: { messages.append($0) }),
            ""
        )
        XCTAssertEqual(messages, ["Renderer resource missing.js is missing. Falling back to plain text."])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        messages.removeAll()
        XCTAssertEqual(
            DetailTextDocument.load(name: "missing.js", installedRoot: root, moduleRoot: root, log: { messages.append($0) }),
            ""
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("missing.js"))
    }

    func testInstalledRendererResourceIsPreferredWithoutLogging() throws {
        let installed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let moduleRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Renderer"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moduleRoot.appendingPathComponent("Renderer"), withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: installed)
            try? FileManager.default.removeItem(at: moduleRoot)
        }
        try "installed-script".write(to: installed.appendingPathComponent("Renderer/sample.js"), atomically: true, encoding: .utf8)
        try "module-script".write(to: moduleRoot.appendingPathComponent("Renderer/sample.js"), atomically: true, encoding: .utf8)

        var messages: [String] = []
        XCTAssertEqual(
            DetailTextDocument.load(name: "sample.js", installedRoot: installed, moduleRoot: moduleRoot, log: { messages.append($0) }),
            "installed-script"
        )
        XCTAssertEqual(
            DetailTextDocument.load(name: "sample.js", installedRoot: nil, moduleRoot: moduleRoot, log: { messages.append($0) }),
            "module-script"
        )
        XCTAssertTrue(messages.isEmpty)
    }

    func testBundledRendererResourceLoads() {
        let source = DetailTextDocument.resource("highlight.min.js")
        XCTAssertFalse(source.isEmpty)
    }

    func testSourceEscapingAndMarkdownDetection() async throws {
        let source = "</script><script>window.pwned=1</script>\nconst x = '<tag>';"
        let web = try await rendered(source, markdown: false, language: "javascript")
        let text = try await web.evaluateJavaScript("document.querySelector('pre code').textContent") as? String
        XCTAssertEqual(text, source)
        XCTAssertTrue(DetailTextFormat.isMarkdown("# 标题\n\n正文"))
        XCTAssertFalse(DetailTextFormat.isMarkdown("普通文字"))
    }
}
