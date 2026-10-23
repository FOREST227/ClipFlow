import XCTest
@testable import ClipFlowApp

final class ClassifierAccuracyTests: XCTestCase {
    func testSwiftPrintDoesNotGetPythonLabel() {
        let labels = ClipboardClassifier.labels(for: "func greet() { print(\"Hello\") }",
            kind: .code, sourceApp: "Xcode", privacy: .standard)
        XCTAssertTrue(labels.contains("Swift"))
        XCTAssertFalse(labels.contains("Python"))
    }
    func testCommonCodeFragments() {
        let examples = [
            "Get-ChildItem -Path C:\\Users -Recurse",
            "Get-Process | Where-Object { $_.CPU -gt 10 }",
            "Write-Host \"Hello world\"",
            "$env:Path += \";C:\\Tools\"",
            "$files = Get-ChildItem",
            "[System.IO.File]::ReadAllText($path)",
            "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser",
            "sudo launchctl kickstart -k system/com.example.service",
            "open -a \"Visual Studio Code\" .",
            "xattr -dr com.apple.quarantine /Applications/Example.app",
            "launchctl list",
            "diskutil list",
            "plutil -lint Info.plist",
            "osascript -e 'tell application \"Finder\" to activate'",
            "echo \"hello\" | pbcopy",
            "print(\"hello\")",
            "console.log(\"hello\");",
            "document.querySelector('#app').classList.add('active');",
            "int count = 0;",
            "std::cout << value << std::endl;",
            "#include <stdio.h>",
            "using System;",
            "package main\nimport \"fmt\"",
            "let result = values.map { $0 * 2 }",
            "@State private var isVisible = false",
            ".padding(.horizontal, 12)\n.frame(maxWidth: .infinity)",
            "def greet(name):\n    return f\"Hello {name}\"",
            "items = [x * 2 for x in range(10)]",
            "<button class=\"primary\">保存</button>",
            ".card {\n  display: flex;\n  padding: 12px;\n}",
            "SELECT id, name FROM users WHERE active = 1;",
            "{\"name\": \"ClipFlow\", \"enabled\": true}",
            "services:\n  app:\n    image: nginx:latest\n    ports:\n      - \"8080:80\"",
            "export PATH=\"$HOME/bin:$PATH\"",
            "cargo build --release",
            "[view setNeedsDisplay:YES];"
        ]
        for text in examples {
            XCTAssertEqual(ClipboardClassifier.kind(for: text), .code, text)
        }
    }
    func testOrdinaryProseAndListsAreNotCode() {
        for text in [
            "Please return the book if you can.",
            "Select a file to continue",
            "Update your profile",
            "From London with love",
            "The public class starts tomorrow.\nPlease return before noon.",
            "任务：修改按钮\n状态：进行中\n负责人：小明",
            "Name: Alice\nStatus: Ready",
            "1. 打开设置\n2. 修改外观\n3. 点击保存",
            "你好，这是一段普通文字。",
            "今天讨论 func 和 class 的含义，并不包含实际代码。"
        ] {
            XCTAssertEqual(ClipboardClassifier.kind(for: text), .text, text)
        }
    }
    func testLinksAndSecretsStillTakeCorrectPrecedence() {
        XCTAssertEqual(ClipboardClassifier.kind(for: "https://example.com/path?q=1"), .link)
        XCTAssertEqual(ClipboardClassifier.kind(for: "请参考 https://example.com/help"), .link)
        XCTAssertEqual(ClipboardClassifier.kind(for: "fetch(\"https://example.com/api\");"), .code)
        XCTAssertEqual(ClipboardClassifier.kind(for: "const api_key = \"sk-abcdefghijklmnopqrstuvwx\";"), .secret)
        XCTAssertEqual(ClipboardClassifier.kind(for: "123456"), .secret)
    }
}
