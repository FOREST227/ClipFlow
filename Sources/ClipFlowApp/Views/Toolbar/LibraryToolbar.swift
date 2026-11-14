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

/// Horizontal scroller with 12pt edge fades. The fade is an AppKit mask, so measuring
/// overflow does not publish SwiftUI state or rebuild the history list.
private struct CategoryFilterScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .fixedSize(horizontal: true, vertical: false)
                .background(FilterScrollProbe())
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

private struct FilterScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.attachIfNeeded() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        private weak var observed: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachIfNeeded() }
        override func layout() { super.layout(); updateMask() }
        func disconnect() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observed?.layer?.mask = nil
            observed = nil
        }
        func attachIfNeeded() {
            guard let scroll = enclosingScrollView else { return }
            guard observed !== scroll else { updateMask(); return }
            disconnect()
            observed = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView),
                                  (NSView.frameDidChangeNotification, scroll.documentView ?? scroll.contentView)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMask() }
                })
            }
            updateMask()
        }
        private func updateMask() {
            guard let scroll = observed else { return }
            let fade = FilterEdgeFade.resolve(
                offset: max(0, scroll.contentView.bounds.minX),
                contentWidth: scroll.documentView?.bounds.width ?? 0,
                viewportWidth: scroll.contentView.bounds.width,
                depth: ClipFlowLayout.space12)
            scroll.wantsLayer = true
            guard scroll.bounds.width > 1, fade.leading > 0.01 || fade.trailing > 0.01 else {
                scroll.layer?.mask = nil
                return
            }
            let mask = CAGradientLayer()
            mask.frame = scroll.bounds
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            let edge = min(0.33, ClipFlowLayout.space12 / scroll.bounds.width)
            mask.colors = [
                NSColor.black.withAlphaComponent(1 - fade.leading).cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.black.withAlphaComponent(1 - fade.trailing).cgColor
            ]
            mask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
            scroll.layer?.mask = mask
        }
    }
}

