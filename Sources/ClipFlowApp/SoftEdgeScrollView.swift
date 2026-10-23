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
struct SoftEdgeScrollView<Content: View>: View {
    var showsEdgeEffects = true
    @ViewBuilder let content: Content
    @StateObject private var metrics = ScrollViewportState()
    @ViewState private var hovered = false
    @ViewState private var scrolling = false
    @ViewState private var dragOrigin: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
            let height = viewport.size.height
            let fade = ScrollEdgeFade(content: metrics.frame, viewportHeight: height)
            let thumbHeight = min(height, max(28, height * height / max(height, metrics.frame.height)))
            let range = max(1, metrics.frame.height - height)
            let progress = min(1, max(0, -metrics.frame.minY / range))
            ScrollView(showsIndicators: false) {
                content.frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScrollViewportProbe(metrics: metrics))
            }
            .frame(width: viewport.size.width, height: height)
            .overlay(alignment: .top) { edge(top: true, strength: fade.top) }
            .overlay(alignment: .bottom) { edge(top: false, strength: fade.bottom) }
            .mask {
                if !showsEdgeEffects || reduceTransparency || height <= 0 {
                    Rectangle()
                } else {
                    let fraction = min(CGFloat(28) / height, 0.33)
                    LinearGradient(stops: [
                        .init(color: .black.opacity(1 - fade.top), location: 0),
                        .init(color: .black, location: fraction),
                        .init(color: .black, location: 1 - fraction),
                        .init(color: .black.opacity(1 - fade.bottom), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .overlay(alignment: .topTrailing) {
                if metrics.frame.height > height + 1 && height > 0 {
                    Capsule().fill(Color.primary.opacity(0.28))
                        .frame(width: 4, height: thumbHeight)
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                        .offset(y: progress * (height - thumbHeight))
                        .opacity(hovered || scrolling || dragOrigin != nil ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragOrigin == nil { dragOrigin = -metrics.frame.minY }
                            metrics.scroll(to: (dragOrigin ?? 0) + value.translation.height * range / max(1, height - thumbHeight))
                        }.onEnded { _ in dragOrigin = nil })
                        .accessibilityHidden(true)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: scrolling || hovered)
                }
            }
            .onHover { hovered = $0 }
            .task(id: metrics.frame.minY) {
                scrolling = true
                do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
                scrolling = false
            }
        }
    }

    @ViewBuilder private func edge(top: Bool, strength: Double) -> some View {
        if showsEdgeEffects && !reduceTransparency {
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

@MainActor
final class ScrollViewportState: ObservableObject {
    @Published var frame = CGRect.zero
    weak var scrollView: NSScrollView?
    func refresh() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let next = CGRect(x: 0, y: -scrollView.contentView.bounds.minY,
            width: document.bounds.width, height: document.bounds.height)
        if next != frame { frame = next }
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
                        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.metrics.refresh() }
                        })
                    }
                }
                self.metrics.refresh()
            }
        }
    }
}
