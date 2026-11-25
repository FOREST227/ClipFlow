import AppKit
import SwiftUI

struct FolioHeaderBar: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette
    var reservesTrafficLights = false
    var showsInlineCategoryStrip = false
    var onToggleEdgeDock: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modeNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if reservesTrafficLights {
                    // Leaves breathing room for native red/yellow/green window controls on the same horizontal band.
                    Spacer().frame(width: 60)
                }

                // Borderless calm search field with ⌘F keycap
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))

                    TextField("搜索叠卡、来源或标签…", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: ClipFlowType.body))

                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("清除搜索")
                    } else {
                        TactileKeycap(label: "⌘F")
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 30)
                .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                )

                // [❐ 叠卡 | ☰ 清单] Segmented View Mode Switcher
                HStack(spacing: 2) {
                    ForEach(LibraryViewMode.allCases, id: \.self) { mode in
                        let selected = store.libraryViewMode == mode
                        Button {
                            guard store.libraryViewMode != mode else { return }
                            withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                                store.libraryViewMode = mode
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(mode.label)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            }
                            .foregroundStyle(selected ? Color.primary : ClipFlowPalette.secondaryText(for: colorScheme))
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(FolioTheme.deckCardFill(depth: 0, for: colorScheme))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                                        )
                                        .matchedGeometryEffect(id: "folioViewMode", in: modeNamespace)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(mode.label)视图")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(3)
                .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                )

                if let onToggleEdgeDock {
                    Button(action: onToggleEdgeDock) {
                        Image(systemName: "sidebar.trailing")
                            .font(.system(size: ClipFlowType.meta, weight: .medium))
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    }
                    .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 30, horizontalPadding: 9, cornerRadius: 9))
                    .help("收起至屏幕右侧书签耳")
                    .accessibilityLabel("贴边收起活页夹")
                }
            }

            if showsInlineCategoryStrip {
                CategoryFilterBar(store: store)
            }
        }
    }
}

struct HeaderView: View {
    @ObservedObject var store: ClipFlowStore
    let palette: ClipFlowPalette

    var body: some View {
        FolioHeaderBar(store: store, palette: palette)
    }
}

/// Fallback horizontal filter bar when `ContentView` is hosted standalone without outer spine tabs.
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
