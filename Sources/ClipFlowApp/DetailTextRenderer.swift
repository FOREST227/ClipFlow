import AppKit
import os
import SwiftUI
import WebKit

enum DetailTextFormat {
    static func isMarkdown(_ text: String) -> Bool {
        let patterns = [
            #"(?m)^#{1,6}\s+\S"#, #"(?m)^\x60{3}"#, #"(?m)^>\s+\S"#,
            #"(?m)^[-*+]\s+\S"#, #"\[[^\]]+\]\([^)]+\)"#,
            #"\*\*[^*\n]+\*\*"#, #"(?m)^\|?.+\|.+\n\|?\s*:?-{3,}"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    static let languages = [
        "自动识别", "powershell", "bash", "swift", "python", "javascript", "typescript",
        "c", "cpp", "csharp", "java", "kotlin", "go", "rust", "ruby", "php",
        "objectivec", "dart", "lua", "perl", "r", "scala", "sql", "json", "yaml",
        "xml", "css", "markdown", "dockerfile", "makefile", "shell", "diff", "plaintext"
    ]
    static func languageHint(_ text: String) -> String? {
        if text.range(of: #"(?im)^\s*(?:Get|Set|Write|New|Remove|Invoke|Start|Stop|Test|ForEach|Where)-[A-Za-z]|\$env:"#,
                      options: .regularExpression) != nil { return "powershell" }
        if text.range(of: #"(?m)^\s*(?:sudo|brew|launchctl|diskutil|plutil|osascript|xattr|pbcopy|pbpaste|export|curl|chmod|git|npm|cargo)\b"#,
                      options: .regularExpression) != nil { return "bash" }
        return nil
    }
}

/// Anchor for `Bundle(for:)`. The generated SwiftPM resource accessor is not
/// used: it aborts when `ClipFlow_ClipFlowApp.bundle` is missing, and the
/// packaged app ships `Contents/Resources/Renderer` instead of that bundle.
private final class RendererBundleAnchor: NSObject {}

enum DetailTextDocument {
    private static let logger = Logger(subsystem: "com.clipflow.app", category: "renderer")
    static let swiftPMBundleName = "ClipFlow_ClipFlowApp"
    static let scriptNames = ["highlight.min.js", "markdown-it.min.js"] +
        ["powershell", "swift", "objectivec", "kotlin", "dart", "scala", "perl", "r",
         "dockerfile", "makefile", "shell", "diff", "lua"].map { "lang-\($0).js" }

    static func resource(_ name: String) -> String {
        if let installedRoot = Bundle.main.resourceURL, let value = read(name, from: installedRoot) {
            return value
        }
        return load(name: name, installedRoot: nil, moduleRoot: resolvedModuleResourceRoot)
    }

    /// Reads a packaged renderer script. A missing bundle or file is logged and replaced
    /// with an empty script so the preview still shows plain text instead of crashing.
    static func load(
        name: String,
        installedRoot: URL?,
        moduleRoot: URL?,
        log: ((String) -> Void)? = nil
    ) -> String {
        if let installedRoot, let value = read(name, from: installedRoot) {
            return value
        }
        if let moduleRoot, let value = read(name, from: moduleRoot) {
            return value
        }
        let message = "Renderer resource \(name) is missing. Falling back to plain text."
        if let log {
            log(message)
        } else {
            logger.error("\(message, privacy: .public)")
        }
        return ""
    }

    private static func read(_ name: String, from root: URL) -> String? {
        let url = root.appendingPathComponent("Renderer").appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Directories SwiftPM searches for `ClipFlow_ClipFlowApp.bundle`, without the
    /// generated accessor's fatal error. Nil means the bundle is not installed.
    static func moduleResourceRoot(
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL? = Bundle.main.bundleURL,
        anchorResourceURL: URL? = Bundle(for: RendererBundleAnchor.self).resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(contentsOf: [mainResourceURL, anchorResourceURL, mainBundleURL].compactMap { $0 })
        if let executableURL {
            var directory = executableURL.deletingLastPathComponent()
            // .xctest/Contents/MacOS/<executable> and the products directory beside that bundle.
            for _ in 0..<4 {
                candidates.append(directory)
                directory = directory.deletingLastPathComponent()
            }
        }
        if let mainBundleURL {
            candidates.append(mainBundleURL.deletingLastPathComponent())
        }
        for candidate in candidates {
            if let root = swiftPMResourceRoot(at: candidate) {
                return root
            }
        }
        return nil
    }

    private static let resolvedModuleResourceRoot: URL? = moduleResourceRoot()

    private static func swiftPMResourceRoot(at candidate: URL) -> URL? {
        var bundleURLs = [candidate.appendingPathComponent(swiftPMBundleName + ".bundle")]
        if candidate.pathExtension.lowercased() == "bundle" {
            bundleURLs.append(candidate)
        }
        for bundleURL in bundleURLs {
            guard let resourceURL = Bundle(url: bundleURL)?.resourceURL else { continue }
            // Debug builds symlink Renderer into the bundle. fileExists reports
            // that link as a non-directory on some macOS versions, so resolve it first.
            let renderer = resourceURL.appendingPathComponent("Renderer").resolvingSymlinksInPath()
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: renderer.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            return resourceURL
        }
        return nil
    }

    static let scripts: String = {
        scriptNames.map(resource).joined(separator: "\n").replacingOccurrences(of: "</script", with: "<\\/script")
    }()

    static func html(text: String, markdown: Bool, language: String, dark: Bool) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        let chosen = language == "自动识别" ? (DetailTextFormat.languageHint(text) ?? "") : language
        let safeLanguage = DetailTextFormat.languages.contains(chosen) ? chosen : ""
        let nonce = UUID().uuidString
        let ink = ClipFlowSyntax.colors(dark: dark)
        let background = ink.background
        let foreground = ink.foreground
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; img-src 'none'; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style nonce="\(nonce)">
        :root{color-scheme:\(dark ? "dark" : "light")}*{box-sizing:border-box}
        body{margin:0;padding:12px;background:\(background);color:\(foreground);font:13px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}
        pre{margin:0;tab-size:4;overflow:auto;white-space:pre}code,pre{font:12px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace}
        article pre{padding:12px;background:\(dark ? "#1e222a" : "#ffffff");border-radius:8px;margin:12px 0}
        article :first-child{margin-top:0}article :last-child{margin-bottom:0}
        h1{font-size:22px}h2{font-size:19px}h3{font-size:16px}h1,h2,h3{line-height:1.35}
        a{color:\(ink.link)}blockquote{margin:12px 0;padding-left:12px;border-left:3px solid #819ac1;color:\(ink.quote)}
        table{border-collapse:collapse;display:block;overflow:auto}th,td{border:1px solid #8291a44d;padding:6px 10px}
        hr{border:0;border-top:1px solid #8291a44d}ul,ol{padding-left:22px}
        .hljs-keyword,.hljs-selector-tag,.hljs-literal{color:\(ink.keyword)}
        .hljs-string,.hljs-regexp,.hljs-addition{color:\(ink.string)}
        .hljs-comment,.hljs-quote{color:\(ink.comment);font-style:italic}
        .hljs-number,.hljs-symbol,.hljs-bullet{color:\(ink.number)}
        .hljs-title,.hljs-function,.hljs-section{color:\(ink.title)}
        .hljs-attr,.hljs-attribute,.hljs-variable,.hljs-params{color:\(ink.attribute)}
        .hljs-type,.hljs-built_in{color:\(ink.typeName)}
        .hljs-meta,.hljs-deletion{color:\(ink.meta)}
        ::-webkit-scrollbar{width:5px;height:5px}::-webkit-scrollbar-thumb{background:#8190a666;border-radius:5px}
        </style></head><body><main id="content"></main>
        <script nonce="\(nonce)">\(scripts)</script>
        <script nonce="\(nonce)">
        const raw = new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c=>c.charCodeAt(0)));
        const main=document.getElementById('content');
        const escapeText=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        function highlight(s,lang){
          if(s.length>120000)return escapeText(s);
          try {
            return lang && hljs.getLanguage(lang) ? hljs.highlight(s,{language:lang,ignoreIllegals:true}).value
                : hljs.highlightAuto(s).value;
          } catch (_) {return escapeText(s);}
        }
        if(\(markdown ? "true" : "false") && typeof markdownit!=='undefined'){
          const md=markdownit({html:false,linkify:false,typographer:false,highlight:highlight});
          md.renderer.rules.image=(tokens,index)=>'<span>'+escapeText(tokens[index].content || '图片')+'</span>';
          main.innerHTML='<article>'+md.render(raw)+'</article>';
        }else{
          main.innerHTML='<pre><code class="hljs">'+highlight(raw,'\(safeLanguage)')+'</code></pre>';
        }
        </script></body></html>
        """
    }

    /// Exercises the detail-view HTML path. A missing script is an error here so
    /// packaging can fail; the live preview still degrades to plain text.
    static func rendererVerificationError() -> String? {
        let missing = scriptNames.filter { resource($0).isEmpty }
        if !missing.isEmpty {
            return "Renderer resources missing (\(missing.joined(separator: ", "))). Detail preview would fall back to plain text."
        }
        let samples: [(text: String, markdown: Bool, language: String, dark: Bool)] = [
            ("plain clipboard text", false, "plaintext", false),
            ("let value = 1", false, "swift", true),
            ("# 标题\n\n一段说明", true, "自动识别", false)
        ]
        for sample in samples {
            let page = html(text: sample.text, markdown: sample.markdown, language: sample.language, dark: sample.dark)
            let payload = Data(sample.text.utf8).base64EncodedString()
            if !page.contains(payload) {
                return "Detail HTML omitted the \(sample.language) clipboard text."
            }
            if !page.contains("Highlight.js") || !page.contains("markdown-it") {
                return "Detail HTML for \(sample.language) did not include the packaged renderer scripts."
            }
            if sample.language == "swift", !page.contains("grammar compiled for Highlight.js") {
                return "Detail HTML did not include the Swift highlighter."
            }
        }
        return nil
    }
}

struct DetailTextRenderer: NSViewRepresentable {
    let text: String
    let markdown: Bool
    let language: String
    let dark: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.underPageBackgroundColor = .clear
        web.wantsLayer = true
        web.layer?.masksToBounds = true
        web.setAccessibilityLabel(markdown ? "Markdown 预览" : "代码内容")
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let key = RenderKey(text: text, markdown: markdown, language: language, dark: dark)
        web.wantsLayer = true
        web.layer?.masksToBounds = true
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        web.loadHTMLString(DetailTextDocument.html(text: text, markdown: markdown, language: language, dark: dark), baseURL: nil)
    }
    struct RenderKey: Equatable { let text: String; let markdown: Bool; let language: String; let dark: Bool }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var key: RenderKey?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            let internalDocument = navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            return internalDocument ? .allow : .cancel
        }
    }
}
