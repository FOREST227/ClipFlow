import AppKit
import ImageIO
import SwiftUI

struct ZoomableDetailImage: View {
    let url: URL
    @StateObject private var pinch = DetailImagePinchBridge()
    @GestureState private var pinching = false
    var body: some View {
        DetailImageCanvasView(url: url, pinch: pinch)
            .contentShape(Rectangle())
            .simultaneousGesture(MagnificationGesture(minimumScaleDelta: 0.001)
                .updating($pinching) { _, active, _ in active = true }
                .onChanged { pinch.update(totalScale: $0) }
                .onEnded { _ in pinch.end() })
            .onChangeBackward(of: pinching) { if !pinching { pinch.end() } }
            .onChangeBackward(of: url) { pinch.end() }
            .onDisappear { pinch.end() }
    }
}
@MainActor
final class DetailImagePinchBridge: ObservableObject {
    weak var canvas: DetailImageCanvas?
    private var previousScale: CGFloat = 1
    private var anchor: CGPoint?
    func update(totalScale: CGFloat) {
        guard totalScale.isFinite, totalScale > 0, let canvas, canvas.isImageReady else { return }
        let point = anchor ?? canvas.window.map { canvas.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        anchor = point
        canvas.applyPinch(factor: totalScale / previousScale, anchor: point)
        previousScale = totalScale
    }
    func end() { previousScale = 1; anchor = nil }
}
private struct DetailImageCanvasView: NSViewRepresentable {
    let url: URL
    let pinch: DetailImagePinchBridge
    func makeNSView(context: Context) -> DetailImageCanvas {
        let view = DetailImageCanvas()
        pinch.canvas = view
        return view
    }
    func updateNSView(_ view: DetailImageCanvas, context: Context) { pinch.canvas = view; view.load(url) }
    static func dismantleNSView(_ view: DetailImageCanvas, coordinator: ()) { view.cancelLoading() }
}

/// Coordinates are in view points. Zoom is relative to the initial aspect-fit size.
struct ImageViewport {
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero

    mutating func reset() { zoom = 1; offset = .zero }
    mutating func scale(by factor: CGFloat, anchor: CGPoint, viewport: CGSize, fitted: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(12, max(1, zoom * factor))
        let ratio = next / zoom
        let relative = CGPoint(x: anchor.x - viewport.width / 2, y: anchor.y - viewport.height / 2)
        offset = CGPoint(x: relative.x - (relative.x - offset.x) * ratio,
                         y: relative.y - (relative.y - offset.y) * ratio)
        zoom = next
        clamp(viewport: viewport, fitted: fitted)
    }
    mutating func clamp(viewport: CGSize, fitted: CGSize) {
        let x = max(0, (fitted.width * zoom - viewport.width) / 2)
        let y = max(0, (fitted.height * zoom - viewport.height) / 2)
        offset.x = min(x, max(-x, offset.x))
        offset.y = min(y, max(-y, offset.y))
    }
}

@MainActor
final class DetailImageCanvas: NSView {
    private var image: NSImage?
    var isImageReady: Bool { image != nil }
    private var url: URL?
    private var loading: Task<Void, Never>?
    private var lastDragPoint: CGPoint?
    private var pinchMonitor: Any?
    var isPinchMonitorInstalled: Bool { pinchMonitor != nil }
    private(set) var viewport = ImageViewport()
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        toolTip = "滚轮或双指捏合缩放 · 拖动查看 · 双击恢复"
        setAccessibilityLabel("图片预览，滚轮或双指捏合缩放，拖动查看，双击恢复")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL) {
        guard self.url != url else { return }
        loading?.cancel()
        loading = nil
        self.url = url
        image = nil
        viewport.reset()
        needsDisplay = true
        loading = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled, let self, self.url == url else { return }
            if let decoded { self.image = NSImage(cgImage: decoded, size: .zero) }
            self.loading = nil
            self.needsDisplay = true
        }
    }
    func cancelLoading() { loading?.cancel(); loading = nil; removePinchMonitor() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removePinchMonitor()
        guard window != nil else { return }
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, self.handleMagnifyEvent(event) else { return event }
            return nil
        }
    }
    private func removePinchMonitor() {
        if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor) }
        pinchMonitor = nil
    }
    @discardableResult
    func handleMagnifyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .magnify, let window, event.windowNumber == window.windowNumber,
            !isHiddenOrHasHiddenAncestor, image != nil else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return false }
        applyPinch(factor: max(0.01, 1 + event.magnification), anchor: point)
        return true
    }

    private var fitted: CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(max(1, bounds.width - 16) / image.size.width,
                        max(1, bounds.height - 16) / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
    override func layout() {
        super.layout()
        viewport.clamp(viewport: bounds.size, fitted: fitted)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.1).setFill()
        bounds.fill()
        guard let image else {
            let message = loading == nil ? "图片不可用" : "正在加载图片…"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = (message as NSString).size(withAttributes: attributes)
            (message as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        let size = CGSize(width: fitted.width * viewport.zoom, height: fitted.height * viewport.zoom)
        let rect = NSRect(x: bounds.midX - size.width / 2 + viewport.offset.x,
                          y: bounds.midY - size.height / 2 + viewport.offset.y,
                          width: size.width, height: size.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    private func zoom(by factor: CGFloat, event: NSEvent) {
        guard image != nil else { return }
        viewport.scale(by: factor, anchor: convert(event.locationInWindow, from: nil),
                       viewport: bounds.size, fitted: fitted)
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        zoom(by: exp(event.scrollingDeltaY * sensitivity), event: event)
    }
    func applyPinch(factor: CGFloat, anchor: CGPoint) {
        guard image != nil else { return }
        viewport.scale(by: factor, anchor: anchor, viewport: bounds.size, fitted: fitted)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            viewport.reset()
            needsDisplay = true
            lastDragPoint = nil
        } else {
            lastDragPoint = convert(event.locationInWindow, from: nil)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let previous = lastDragPoint {
            viewport.offset.x += point.x - previous.x
            viewport.offset.y += point.y - previous.y
            viewport.clamp(viewport: bounds.size, fitted: fitted)
            needsDisplay = true
        }
        lastDragPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastDragPoint = nil }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "0" {
            viewport.reset()
            needsDisplay = true
        } else { super.keyDown(with: event) }
    }
}
