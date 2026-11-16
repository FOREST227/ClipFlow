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
        XCTAssertNil(DetailTextDocument.rendererVerificationError())
    }

    func testMissingSwiftPMBundleReturnsNilInsteadOfTrapping() throws {
        let missing = try temporaryDirectory()
        XCTAssertNil(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: missing,
            mainBundleURL: missing,
            anchorResourceURL: missing,
            executableURL: missing.appendingPathComponent("ClipFlowApp"),
            environment: [:]
        ))
    }

    func testInstalledRendererLayoutLoadsWithoutSwiftPMBundle() throws {
        let resources = try temporaryDirectory()
        let renderer = resources.appendingPathComponent("Renderer", isDirectory: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try "/*! Highlight.js packaged */".write(
            to: renderer.appendingPathComponent("highlight.min.js"),
            atomically: true,
            encoding: .utf8
        )
        let executable = resources.appendingPathComponent("Contents/MacOS/ClipFlowApp")
        XCTAssertNil(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: resources,
            mainBundleURL: resources,
            anchorResourceURL: resources,
            executableURL: executable,
            environment: ["PACKAGE_RESOURCE_BUNDLE_PATH": resources.path]
        ))
        XCTAssertEqual(
            DetailTextDocument.load(
                name: "highlight.min.js",
                installedRoot: resources,
                moduleRoot: DetailTextDocument.moduleResourceRoot(
                    mainResourceURL: resources,
                    mainBundleURL: resources,
                    anchorResourceURL: resources,
                    executableURL: executable,
                    environment: [:]
                )
            ),
            "/*! Highlight.js packaged */"
        )
    }

    func testModuleResourceRootFindsBundleWithoutTrapping() throws {
        let directory = try temporaryDirectory()
        let bundle = try writeSwiftPMBundle(in: directory, script: "next-to-executable")
        let executable = directory.appendingPathComponent("ClipFlowApp")
        let besideExecutable = try XCTUnwrap(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: nil,
            mainBundleURL: nil,
            anchorResourceURL: nil,
            executableURL: executable,
            environment: [:]
        ))
        XCTAssertEqual(
            DetailTextDocument.load(name: "highlight.min.js", installedRoot: nil, moduleRoot: besideExecutable),
            "next-to-executable"
        )

        let fromResources = try XCTUnwrap(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: directory,
            mainBundleURL: nil,
            anchorResourceURL: nil,
            executableURL: nil,
            environment: [:]
        ))
        XCTAssertEqual(
            DetailTextDocument.load(name: "highlight.min.js", installedRoot: nil, moduleRoot: fromResources),
            "next-to-executable"
        )

        let products = try temporaryDirectory()
        _ = try writeSwiftPMBundle(in: products, script: "beside-xctest")
        let xctest = products.appendingPathComponent("ClipFlowPackageTests.xctest")
        let besideProduct = try XCTUnwrap(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: xctest.appendingPathComponent("Contents/Resources"),
            mainBundleURL: xctest,
            anchorResourceURL: xctest.appendingPathComponent("Contents/Resources"),
            executableURL: xctest.appendingPathComponent("Contents/MacOS/ClipFlowPackageTests"),
            environment: [:]
        ))
        XCTAssertEqual(
            DetailTextDocument.load(name: "highlight.min.js", installedRoot: nil, moduleRoot: besideProduct),
            "beside-xctest"
        )

        let symlinked = try temporaryDirectory()
        let symlinkedBundle = try writeSwiftPMBundle(in: symlinked, script: "symlinked-renderer")
        let resources = symlinkedBundle.appendingPathComponent("Contents/Resources")
        let renderer = resources.appendingPathComponent("Renderer")
        let relocated = symlinked.appendingPathComponent("relocated-renderer")
        try FileManager.default.moveItem(at: renderer, to: relocated)
        try FileManager.default.createSymbolicLink(at: renderer, withDestinationURL: relocated)
        let symlinkedRoot = try XCTUnwrap(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: symlinked,
            mainBundleURL: nil,
            anchorResourceURL: nil,
            executableURL: nil,
            environment: [:]
        ))
        XCTAssertEqual(
            DetailTextDocument.load(name: "highlight.min.js", installedRoot: nil, moduleRoot: symlinkedRoot),
            "symlinked-renderer"
        )

        let fromOverride = try XCTUnwrap(DetailTextDocument.moduleResourceRoot(
            mainResourceURL: nil,
            mainBundleURL: nil,
            anchorResourceURL: nil,
            executableURL: nil,
            environment: ["PACKAGE_RESOURCE_BUNDLE_PATH": bundle.path]
        ))
        XCTAssertEqual(
            DetailTextDocument.load(name: "highlight.min.js", installedRoot: nil, moduleRoot: fromOverride),
            "next-to-executable"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipflow-renderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeSwiftPMBundle(in directory: URL, script: String) throws -> URL {
        let bundle = directory.appendingPathComponent(DetailTextDocument.swiftPMBundleName + ".bundle", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let renderer = contents.appendingPathComponent("Resources/Renderer", isDirectory: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>test.clipflow.resources</string>
          <key>CFBundleName</key><string>\(DetailTextDocument.swiftPMBundleName)</string>
          <key>CFBundlePackageType</key><string>BNDL</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try script.write(to: renderer.appendingPathComponent("highlight.min.js"), atomically: true, encoding: .utf8)
        return bundle
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
