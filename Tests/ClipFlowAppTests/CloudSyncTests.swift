import XCTest
@testable import ClipFlowApp

final class CloudSyncTests: XCTestCase {
    func testUnchangedSyncDoesNotRewriteHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appendingPathComponent("localImages")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: images, documentsDirectoryURL: directory)
        let item = ClipboardClassifier.makeItem(text: "hello", sourceApp: "Editor",
            sourceBundleID: nil, autoProtectSecrets: true, existingItem: nil)
        _ = try coordinator.synchronize(localItems: [item], tombstones: [:], maxItems: 80)
        let historyURL = directory.appendingPathComponent("ClipFlow/history.json")
        let first = try Data(contentsOf: historyURL)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: historyURL.path)
        _ = try coordinator.synchronize(localItems: [item], tombstones: [:], maxItems: 80)
        XCTAssertEqual(try Data(contentsOf: historyURL), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: historyURL.path)[.modificationDate] as? Date, timestamp)
    }

    func testSensitiveItemsNeverSyncEvenWithExpiryOff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: directory, documentsDirectoryURL: directory)
        let item = ClipboardClassifier.makeItem(text: "private note", sourceApp: "Passwords",
            sourceBundleID: "com.apple.Passwords", autoProtectSecrets: true, existingItem: nil)
            .applyingExpirationPolicy(enabled: false)
        let result = try coordinator.synchronize(localItems: [item], tombstones: [:], maxItems: 80)
        XCTAssertTrue(result.cloudItems.isEmpty)
    }

    func testSyncPreservesRemoteImageThatArrivesBeforeItsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteImages = directory.appendingPathComponent("ClipFlow/images")
        try FileManager.default.createDirectory(at: remoteImages, withIntermediateDirectories: true)
        let incomingAsset = remoteImages.appendingPathComponent("other-device.png")
        let original = Data([1, 2, 3])
        try original.write(to: incomingAsset)
        let coordinator = ClipFlowCloudSyncCoordinator(localImagesDirectoryURL: directory, documentsDirectoryURL: directory)
        _ = try coordinator.synchronize(localItems: [], tombstones: [:], maxItems: 80)
        XCTAssertEqual(try Data(contentsOf: incomingAsset), original)
    }
}
