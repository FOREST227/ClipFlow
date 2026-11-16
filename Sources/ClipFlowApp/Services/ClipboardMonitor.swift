import AppKit

@MainActor
final class ClipboardMonitor {
    private let store: ClipFlowStore
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    /// `.distantPast` so the first poll still sweeps items that expired while the app was closed.
    var lastPurgeAt = Date.distantPast
    /// Tests advance this instead of waiting for wall-clock expiry.
    var now: () -> Date = { Date() }
    private var captureGeneration = 0
    private var captureInFlight = false
    /// PNG decode, encode, and hash. Tests replace this to pause that work.
    var encodeImage: @Sendable (ClipboardImageEncoder.Source) -> EncodedClipboardImage? = { source in
        ClipboardImageEncoder.encode(source)
    }

    init(store: ClipFlowStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: ClipFlowMotion.clipboardPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        timer.tolerance = ClipFlowMotion.clipboardPollTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func ignoreCurrentPasteboardUpdate() {
        captureGeneration += 1
        captureInFlight = false
        lastChangeCount = pasteboard.changeCount
    }

    func poll(sourceApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        if captureInFlight { return }

        let changeCount = pasteboard.changeCount
        let changed = changeCount != lastChangeCount
        let current = now()
        if changed || current.timeIntervalSince(lastPurgeAt) >= ClipFlowMotion.clipboardPurgeInterval {
            store.purgeExpired(at: current)
            lastPurgeAt = current
        }

        if store.capturePaused {
            lastChangeCount = changeCount
            return
        }

        guard changed else { return }

        let sourceBundleID = sourceApplication?.bundleIdentifier
        if (sourceBundleID != nil && sourceBundleID == Bundle.main.bundleIdentifier) || store.isExcluded(bundleID: sourceBundleID) {
            lastChangeCount = changeCount
            return
        }

        if SensitivePasteboard.containsMarker(pasteboard) {
            lastChangeCount = changeCount
            return
        }

        guard let choice = ClipboardCapture.choose(from: pasteboard) else {
            guard pasteboard.changeCount == changeCount else { return }
            lastChangeCount = changeCount
            return
        }
        guard pasteboard.changeCount == changeCount else { return }

        let sourceApp = sourceApplication?.localizedName ?? "未知应用"
        switch choice {
        case .text(let text):
            let richContent = ClipboardRepresentations.capture(from: pasteboard)
            guard pasteboard.changeCount == changeCount else { return }
            lastChangeCount = changeCount
            store.ingestCopiedText(
                text,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID,
                richContent: richContent
            )
        case .image(let source):
            startImageCapture(
                source: source,
                changeCount: changeCount,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID
            )
        }
    }

    private func startImageCapture(
        source: ClipboardImageEncoder.Source,
        changeCount: Int,
        sourceApp: String,
        sourceBundleID: String?
    ) {
        captureInFlight = true
        let generation = captureGeneration
        let encode = encodeImage
        Task { @MainActor [weak self] in
            let encoded = await Task.detached(priority: .userInitiated) {
                encode(source)
            }.value
            self?.finishImageCapture(
                encoded,
                generation: generation,
                changeCount: changeCount,
                sourceApp: sourceApp,
                sourceBundleID: sourceBundleID
            )
        }
    }

    private func finishImageCapture(
        _ encoded: EncodedClipboardImage?,
        generation: Int,
        changeCount: Int,
        sourceApp: String,
        sourceBundleID: String?
    ) {
        guard generation == captureGeneration else { return }
        captureInFlight = false
        guard pasteboard.changeCount == changeCount else {
            poll()
            return
        }

        lastChangeCount = changeCount
        guard let encoded else { return }
        store.ingestCopiedImage(
            encoded.pngData,
            size: encoded.size,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            signature: encoded.signature
        )
    }
}
