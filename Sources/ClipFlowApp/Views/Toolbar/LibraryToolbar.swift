import AppKit
import SwiftUI

struct HeaderView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容、来源或标签", text: $store.searchText).textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, ClipFlowLayout.space12)
            .frame(height: ClipFlowLayout.controlHeight)
            .background(palette.inputFill, in: RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ClipFlowLayout.controlRadius, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        }
    }
}

/// One row of filters. Extra pills scroll instead of being clipped by the 620pt window.
struct CategoryFilterBar: View {
    @ObservedObject var store: ClipFlowStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CategoryFilterScroll {
            HStack(spacing: ClipFlowLayout.space8) {
                ForEach(ClipCategory.allCases) { category in
                    Button {
                        withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                            store.selectedCategory = category
                        }
                    } label: {
                        CategoryPill(category: category, count: store.count(for: category),
                            isSelected: store.selectedCategory == category)
                    }
                    .buttonStyle(.plain)
                    .help(category.subtitle)
                }
            }
        }
        .frame(height: CategoryPill.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("内容筛选")
    }
}

/// Horizontal scroller with 12pt edge fades. Indicators stay off; this row is not the history list.
private struct CategoryFilterScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @StateObject private var metrics = FilterScrollMetrics()

    var body: some View {
        GeometryReader { viewport in
            let fade = ScrollEdgeFade.horizontal(offset: metrics.offset,
                contentWidth: metrics.contentWidth, viewportWidth: viewport.size.width,
                depth: ClipFlowLayout.space12)
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .fixedSize(horizontal: true, vertical: false)
                    .background(FilterScrollProbe(metrics: metrics))
            }
            .mask {
                if viewport.size.width <= 0 {
                    Rectangle()
                } else {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(1 - fade.leading), .black],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: ClipFlowLayout.space12)
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(1 - fade.trailing)],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: ClipFlowLayout.space12)
                    }
                }
            }
        }
    }
}

enum FilterEdgeFade: Equatable {
    static func resolve(offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat, depth: CGFloat) -> (leading: Double, trailing: Double) {
        guard viewportWidth > 0, contentWidth > viewportWidth + 1, depth > 0 else { return (0, 0) }
        let leading = Double(min(1, max(0, offset / depth)))
        let remaining = contentWidth - viewportWidth - max(0, offset)
        let trailing = Double(min(1, max(0, remaining / depth)))
        return (leading, trailing)
    }
}

private extension ScrollEdgeFade {
    static func horizontal(offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat, depth: CGFloat) -> (leading: Double, trailing: Double) {
        FilterEdgeFade.resolve(offset: offset, contentWidth: contentWidth, viewportWidth: viewportWidth, depth: depth)
    }
}

@MainActor
private final class FilterScrollMetrics: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var contentWidth: CGFloat = 0
    weak var scrollView: NSScrollView?
    func refresh() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let nextOffset = scrollView.contentView.bounds.minX
        let nextWidth = document.bounds.width
        if nextOffset != offset { offset = nextOffset }
        if nextWidth != contentWidth { contentWidth = nextWidth }
    }
}

private struct FilterScrollProbe: NSViewRepresentable {
    let metrics: FilterScrollMetrics
    func makeNSView(context: Context) -> Probe { Probe(metrics: metrics) }
    func updateNSView(_ view: Probe, context: Context) { view.schedule() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        let metrics: FilterScrollMetrics
        private weak var observed: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        init(metrics: FilterScrollMetrics) { self.metrics = metrics; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        func disconnect() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observed = nil
            metrics.scrollView = nil
        }
        func schedule() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                if self.observed !== scroll {
                    self.disconnect()
                    self.observed = scroll
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

