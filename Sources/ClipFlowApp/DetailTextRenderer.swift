import AppKit
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

enum DetailTextDocument {
    static func resource(_ name: String) -> String {
        let installed = Bundle.main.resourceURL?.appendingPathComponent("Renderer").appendingPathComponent(name)
        if let installed, let value = try? String(contentsOf: installed, encoding: .utf8) { return value }
        let url = Bundle.module.resourceURL!.appendingPathComponent("Renderer").appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    static let scripts: String = {
        let names = ["highlight.min.js", "markdown-it.min.js"] +
            ["powershell", "swift", "objectivec", "kotlin", "dart", "scala", "perl", "r",
             "dockerfile", "makefile", "shell", "diff", "lua"].map { "lang-\($0).js" }
        return names.map(resource).joined(separator: "\n").replacingOccurrences(of: "</script", with: "<\\/script")
    }()

    static func html(text: String, markdown: Bool, language: String, dark: Bool) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        let chosen = language == "自动识别" ? (DetailTextFormat.languageHint(text) ?? "") : language
        let safeLanguage = DetailTextFormat.languages.contains(chosen) ? chosen : ""
        let nonce = UUID().uuidString
        let background = dark ? "#262b34" : "#f7f9fc"
        let foreground = dark ? "#d9e0eb" : "#263244"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; img-src 'none'; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style nonce="\(nonce)">
        :root{color-scheme:\(dark ? "dark" : "light")}*{box-sizing:border-box}
        body{margin:0;padding:12px;background:\(background);color:\(foreground);font:13px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}
        pre{margin:0;tab-size:4;overflow:auto;white-space:pre}code,pre{font:12px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace}
        article pre{padding:12px;background:\(dark ? "#1e222a" : "#edf1f7");border-radius:8px;margin:12px 0}
        article :first-child{margin-top:0}article :last-child{margin-bottom:0}
        h1{font-size:22px}h2{font-size:19px}h3{font-size:16px}h1,h2,h3{line-height:1.35}
        a{color:\(dark ? "#91b8ff" : "#3569c8")}blockquote{margin:12px 0;padding-left:12px;border-left:3px solid #819ac1;color:\(dark ? "#aab6c7" : "#61718a")}
        table{border-collapse:collapse;display:block;overflow:auto}th,td{border:1px solid #8291a44d;padding:6px 10px}
        hr{border:0;border-top:1px solid #8291a44d}ul,ol{padding-left:22px}
        .hljs-keyword,.hljs-selector-tag,.hljs-literal{color:\(dark ? "#c4a0ff" : "#8554b5")}
        .hljs-string,.hljs-regexp,.hljs-addition{color:\(dark ? "#9ad5ad" : "#327b53")}
        .hljs-comment,.hljs-quote{color:\(dark ? "#8e9bab" : "#7b8796");font-style:italic}
        .hljs-number,.hljs-symbol,.hljs-bullet{color:\(dark ? "#efbb86" : "#ad6431")}
        .hljs-title,.hljs-function,.hljs-section{color:\(dark ? "#91b8ff" : "#3569c8")}
        .hljs-attr,.hljs-attribute,.hljs-variable,.hljs-params{color:\(dark ? "#8ed2d2" : "#287d85")}
        .hljs-type,.hljs-built_in{color:\(dark ? "#e6c482" : "#92701e")}
        .hljs-meta,.hljs-deletion{color:\(dark ? "#f399a4" : "#bc5263")}
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
        web.setAccessibilityLabel(markdown ? "Markdown 预览" : "代码内容")
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let key = RenderKey(text: text, markdown: markdown, language: language, dark: dark)
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
