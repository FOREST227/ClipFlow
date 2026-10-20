import XCTest
@testable import ClipFlowApp

final class ClipboardTests: XCTestCase {
    func testClassifierPreservesOriginalWhitespace() {
        let original = "    print(1)\n\n"
        let item = ClipboardClassifier.makeItem(
            text: original, sourceApp: "Editor", sourceBundleID: nil,
            autoProtectSecrets: true, existingItem: nil
        )
        XCTAssertEqual(item.fullText, original)
    }

    func testSensitiveTextExpiresAfterFiveMinutes() throws {
        let item = ClipboardClassifier.makeItem(
            text: "private note", sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords",
            autoProtectSecrets: true, existingItem: nil
        )
        XCTAssertTrue(item.autoExpire)
        let expiry = try XCTUnwrap(item.expiresAt)
        XCTAssertEqual(expiry.timeIntervalSince(item.createdAt), 300, accuracy: 0.01)
    }

    func testSensitiveImageExpiresAfterFiveMinutes() throws {
        let item = ClipboardClassifier.makeImageItem(
            imageFilename: "test.png", imageSignature: "test",
            imageSize: .init(width: 10, height: 10),
            sourceApp: "Passwords", sourceBundleID: "com.apple.Passwords", existingItem: nil
        )
        XCTAssertTrue(item.autoExpire)
        let expiry = try XCTUnwrap(item.expiresAt)
        XCTAssertEqual(expiry.timeIntervalSince(item.createdAt), 300, accuracy: 0.01)
    }
}
