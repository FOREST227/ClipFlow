import AppKit
import SwiftUI

struct ScrollEdgeFade: Equatable {
    let top: Double
    let bottom: Double

    init(content: CGRect, viewportHeight: CGFloat, depth: CGFloat = 24) {
        guard viewportHeight > 0, content.height > viewportHeight, depth > 0 else {
            top = 0
            bottom = 0
            return
        }
        top = Double(min(1, max(0, -content.minY / depth)))
        bottom = Double(min(1, max(0, (content.maxY - viewportHeight) / depth)))
    }
}

/// The content stays sharp; only the viewport edges receive a masked material.
/// This view owns the viewport metrics. Edge bands read the published frame;
/// the scrolled content does not.
struct SoftEdgeScrollView<Content: View>: View {
    var showsEdgeEffects = true
    @ViewBuilder let content: Content
    @StateObject private var metrics = ScrollViewportState()

    var body: some View {
        GeometryReader { viewport in
            let height = viewport.size.height
            ScrollView(showsIndicators: true) {
                content.frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScrollViewportProbe(metrics: metrics))
            }
            .frame(width: viewport.size.width, height: height)
            .overlay(alignment: .top) {
                if showsEdgeEffects {
                    ScrollEdgeBand(metrics: metrics, top: true, viewportHeight: height)
                }
            }
            .overlay(alignment: .bottom) {
                if showsEdgeEffects {
                    ScrollEdgeBand(metrics: metrics, top: false, viewportHeight: height)
                }
            }
            .mask {
                if showsEdgeEffects {
                    ScrollEdgeMask(metrics: metrics, viewportHeight: height)
                } else {
                    Rectangle()
                }
            }
        }
    }
}

private struct ScrollEdgeBand: View {
    @ObservedObject var metrics: ScrollViewportState
    let top: Bool
    let viewportHeight: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let fade = ScrollEdgeFade(content: metrics.frame, viewportHeight: viewportHeight)
        let strength = top ? fade.top : fade.bottom
        if !reduceTransparency {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: top ? [.black, .clear] : [.clear, .black],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: 28)
                .opacity(strength)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ScrollEdgeMask: View {
    @ObservedObject var metrics: ScrollViewportState
    let viewportHeight: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let fade = ScrollEdgeFade(content: metrics.frame, viewportHeight: viewportHeight)
        if reduceTransparency || viewportHeight <= 0 {
            Rectangle()
        } else {
            let fraction = min(CGFloat(28) / viewportHeight, 0.33)
            LinearGradient(stops: [
                .init(color: .black.opacity(1 - fade.top), location: 0),
                .init(color: .black, location: fraction),
                .init(color: .black, location: 1 - fraction),
                .init(color: .black.opacity(1 - fade.bottom), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

@MainActor
final class ScrollViewportState: ObservableObject {
    @Published var frame = CGRect.zero
    weak var scrollView: NSScrollView?
    private var pendingFrame: CGRect?
    func refresh() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let next = CGRect(x: 0, y: -scrollView.contentView.bounds.minY,
            width: document.bounds.width, height: document.bounds.height)
        guard next != frame, next != pendingFrame else { return }
        pendingFrame = next
        // Bounds notifications arrive inside the layout pass. Publishing there
        // rebuilds whatever view owns this object.
        DispatchQueue.main.async { [weak self] in
            guard let self, let pending = self.pendingFrame else { return }
            self.pendingFrame = nil
            if pending != self.frame { self.frame = pending }
        }
    }
    func scroll(to offset: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let y = min(max(0, offset), max(0, document.bounds.height - scrollView.contentView.bounds.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refresh()
    }
}

private struct ScrollViewportProbe: NSViewRepresentable {
    let metrics: ScrollViewportState
    func makeNSView(context: Context) -> Probe { Probe(metrics: metrics) }
    func updateNSView(_ view: Probe, context: Context) { view.scheduleConfiguration() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        let metrics: ScrollViewportState
        private weak var observedScroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var notingBounds = false
        init(metrics: ScrollViewportState) { self.metrics = metrics; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleConfiguration() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleConfiguration() }
        func disconnect() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observedScroll = nil
            metrics.scrollView = nil
        }
        func noteBoundsChanged() {
            guard !notingBounds else { return }
            notingBounds = true
            metrics.refresh()
            notingBounds = false
        }

        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                if self.observedScroll !== scroll {
                    self.disconnect()
                    self.observedScroll = scroll
                    self.metrics.scrollView = scroll
                    scroll.contentView.postsBoundsChangedNotifications = true
                    scroll.documentView?.postsFrameChangedNotifications = true
                    for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView),
                                          (NSView.frameDidChangeNotification, scroll.documentView ?? scroll.contentView)] {
                        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                            MainActor.assumeIsolated { self?.noteBoundsChanged() }
                        })
                    }
                }
                self.noteBoundsChanged()
            }
        }
    }
}
