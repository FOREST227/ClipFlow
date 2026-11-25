import AppKit
import SwiftUI

/// Dedicated observable hover state so pointer movement across the 5-card carousel
/// NEVER invalidates `QuickPastePanelView`, search filtering, or window monitors.
@MainActor
final class CarouselHoverState: ObservableObject {
    @Published var hoveredID: UUID?
}

/// Dedicated continuous scroll progress model (`0.0 ... items.count - 1`).
/// Drives 1:1 finger tracking during MacBook trackpad swipes + velocity-continuous analytical
/// critically-damped spring settling at native display refresh rate (zero dead-pause, zero SwiftUI chord jump).
@MainActor
final class CarouselScrollModel: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var isInteracting = false

    private var velocity: CGFloat = 0 // cards per second
    private var lastDeltaTimestamp: TimeInterval = 0
    private var targetIndex: CGFloat?
    private var maxIndex: Int = 0
    private var settleCallback: ((Int) -> Void)?
    private let displayLink = DisplayLinkDriver()
    private var lastFrameTimestamp: TimeInterval = 0
    private var autoSnapWorkItem: DispatchWorkItem?
    private(set) var ignoringMomentumTail = false

    var nearestIndex: Int {
        Int(round(progress))
    }

    func beginNewTouch() {
        ignoringMomentumTail = false
        stopSpring()
        cancelAutoSnap()
        velocity = 0
        lastDeltaTimestamp = 0
    }

    func jump(to index: Int) {
        ignoringMomentumTail = false
        stopSpring()
        cancelAutoSnap()
        isInteracting = false
        velocity = 0
        progress = CGFloat(index)
    }

    /// Continuous 1:1 fractional scrubbing (e.g. dragging the right-side Folio Time Dial).
    /// Updates `progress` smoothly at 120Hz without triggering discrete store broadcasts or spring snaps mid-drag.
    func scrub(to targetProgress: CGFloat, maxIndex: Int) {
        ignoringMomentumTail = false
        stopSpring()
        cancelAutoSnap()
        guard maxIndex > 0 else { return }

        let clamped = min(max(0, targetProgress), CGFloat(maxIndex))
        let now = ProcessInfo.processInfo.systemUptime
        if lastDeltaTimestamp > 0 {
            let dt = max(0.004, min(0.05, now - lastDeltaTimestamp))
            let instantVel = (clamped - progress) / CGFloat(dt)
            velocity = velocity * 0.55 + instantVel * 0.45
        } else {
            velocity = 0
        }
        lastDeltaTimestamp = now
        self.maxIndex = maxIndex
        isInteracting = true

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = clamped
        }
    }

    /// Settles a continuous scrub smoothly onto the nearest card with critically-damped spring physics.
    func finishScrub(maxIndex: Int, reduceMotion: Bool, onSettle: @escaping (Int) -> Void) {
        lastDeltaTimestamp = 0
        let target = min(max(0, Int(round(progress))), max(0, maxIndex))
        velocity = min(max(velocity, -5.0), 5.0)
        animateTo(index: target, maxIndex: maxIndex, reduceMotion: reduceMotion, preserveVelocity: true, onCommit: onSettle)
    }

    /// Smoothly glides from current `progress` (preserving existing velocity!) to `index` via
    /// an exact analytical critically-damped spring ticking at native refresh rate.
    func animateTo(index: Int, maxIndex: Int, reduceMotion: Bool, preserveVelocity: Bool = false, onCommit: ((Int) -> Void)? = nil) {
        cancelAutoSnap()
        let clamped = min(max(0, index), max(0, maxIndex))
        self.maxIndex = max(0, maxIndex)

        if reduceMotion {
            stopSpring()
            isInteracting = false
            velocity = 0
            progress = CGFloat(clamped)
            onCommit?(clamped)
            return
        }

        let target = CGFloat(clamped)
        if !displayLink.isRunning && abs(progress - target) < 0.001 && (!preserveVelocity || abs(velocity) < 0.02) {
            isInteracting = false
            velocity = 0
            progress = target
            onCommit?(clamped)
            return
        }

        if !preserveVelocity {
            // Keep existing spring velocity if interrupting an in-flight keyboard/wheel glide!
            if !displayLink.isRunning { velocity = 0 }
        }
        targetIndex = target
        settleCallback = onCommit
        isInteracting = true
        startSpringLoop()
    }

    /// Continuous 1:1 delta feed from precise trackpad gestures (including macOS momentum phase).
    func applyContinuousDelta(
        _ deltaCards: CGFloat,
        isMomentum: Bool,
        maxIndex: Int,
        reduceMotion: Bool,
        onSettle: @escaping (Int) -> Void
    ) {
        if isMomentum && ignoringMomentumTail { return }
        stopSpring()
        cancelAutoSnap()
        guard maxIndex > 0 else { return }

        let upper = CGFloat(maxIndex)
        let next = min(max(0, progress + deltaCards), upper)

        // Already resting at the top (0) or bottom (maxIndex) boundary and scrolling further past it:
        // stay completely still with zero twitching, zero rubber-band oscillation, and zero fast-preview flash.
        if abs(next - progress) < 0.0001 {
            if isMomentum {
                ignoringMomentumTail = true
            }
            velocity = 0
            if isInteracting {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    isInteracting = false
                }
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if lastDeltaTimestamp > 0 {
            let dt = max(0.004, min(0.05, now - lastDeltaTimestamp))
            let instantVel = (next - progress) / CGFloat(dt)
            // Exponentially smooth velocity estimate so handoff is noise-free
            velocity = velocity * 0.55 + instantVel * 0.45
        }
        lastDeltaTimestamp = now
        self.maxIndex = maxIndex
        isInteracting = true

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = next
        }

        let atBoundary = next <= 0.0001 || next >= upper - 0.0001
        if atBoundary && isMomentum {
            ignoringMomentumTail = true
            velocity = 0
            let settled = Int(round(next))
            withTransaction(transaction) {
                progress = CGFloat(settled)
                isInteracting = false
            }
            onSettle(settled)
            return
        }

        // Smooth early handoff during slow momentum tail so cards NEVER crawl to a dead stop before snapping.
        if isMomentum && abs(velocity) < 1.35 {
            ignoringMomentumTail = true
            handoffToSnap(maxIndex: maxIndex, reduceMotion: reduceMotion, onSettle: onSettle)
            return
        }

        scheduleAutoSnap(maxIndex: maxIndex, delay: 0.14, reduceMotion: reduceMotion, onSettle: onSettle)
    }

    func finishGesture(maxIndex: Int, reduceMotion: Bool, onSettle: @escaping (Int) -> Void) {
        guard !displayLink.isRunning else { return }
        ignoringMomentumTail = true
        handoffToSnap(maxIndex: maxIndex, reduceMotion: reduceMotion, onSettle: onSettle)
    }

    private func handoffToSnap(maxIndex: Int, reduceMotion: Bool, onSettle: @escaping (Int) -> Void) {
        // Project slightly along current travel direction so the snap never jolts backwards against your flick.
        let projection = min(max(velocity * 0.055, -0.32), 0.32)
        let target = min(max(0, Int(round(progress + projection))), max(0, maxIndex))
        // Clamp velocity slightly for gentle, weighted settling
        velocity = min(max(velocity, -6.5), 6.5)
        animateTo(index: target, maxIndex: maxIndex, reduceMotion: reduceMotion, preserveVelocity: true, onCommit: onSettle)
    }

    private func startSpringLoop() {
        guard !displayLink.isRunning else { return }
        lastFrameTimestamp = ProcessInfo.processInfo.systemUptime
        displayLink.start { [weak self] in
            self?.stepSpring()
        }
    }

    private func stepSpring() {
        guard let target = targetIndex else {
            stopSpring()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(max(now - lastFrameTimestamp, 0.001), 0.033))
        lastFrameTimestamp = now

        // Exact analytical critically-damped spring (zero overshoot, unconditionally stable at any FPS)
        let omega: CGFloat = 16.5
        let disp = progress - target
        let decay = exp(-omega * dt)
        let c2 = velocity + omega * disp
        let newDisp = (disp + c2 * dt) * decay
        let newVel = (velocity - omega * c2 * dt) * decay

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = target + newDisp
        }
        velocity = newVel

        if abs(newDisp) < 0.002 && abs(newVel) < 0.025 {
            let finalIndex = Int(round(target))
            let callback = settleCallback
            stopSpring()
            withTransaction(transaction) {
                progress = target
                isInteracting = false
            }
            velocity = 0
            callback?(finalIndex)
        }
    }

    private func scheduleAutoSnap(maxIndex: Int, delay: TimeInterval, reduceMotion: Bool, onSettle: @escaping (Int) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finishGesture(maxIndex: maxIndex, reduceMotion: reduceMotion, onSettle: onSettle)
        }
        autoSnapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopSpring() {
        displayLink.stop()
        targetIndex = nil
        settleCallback = nil
    }

    func cancelAutoSnap() {
        autoSnapWorkItem?.cancel()
        autoSnapWorkItem = nil
    }

    deinit {
        MainActor.assumeIsolated {
            displayLink.stop()
            autoSnapWorkItem?.cancel()
        }
    }
}

/// Shell-less 5-Card Floating Arc Carousel shown inside Quick Paste (`⌥V`).
/// - Continuous 1:1 trackpad scrolling + native inertia + smooth spring settle.
/// - Dynamic Focus Wave: whichever card is focused blooms into the upright Big Focus Card.
/// - Zero-blur per-frame cost: card chrome + soft shadow are baked into each Metal `.drawingGroup()` tile.
struct QuickPasteFanDeckView: View {
    let items: [ClipboardItem]
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var selection: HistorySelection
    @ObservedObject var pasteStack: PasteStackState
    @ObservedObject var hoverState: CarouselHoverState
    let isSearchActive: Bool
    var isBlocked: Bool = false
    let onSelectCenter: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onInspect: (ClipboardItem) -> Void
    let onOpenLibrary: () -> Void
    let onToggleSearch: () -> Void
    var onSwitchToList: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var scrollModel = CarouselScrollModel()

    private var selectionIndex: Int {
        if let id = selection.itemID, let idx = items.firstIndex(where: { $0.id == id }) {
            return idx
        }
        return 0
    }

    private var activeCenterIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(0, scrollModel.nearestIndex), items.count - 1)
    }

    /// Continuous focus position: tracks hovered card when idle, or tracks `scrollModel.progress` during scroll.
    private var continuousFocusPos: CGFloat {
        if !scrollModel.isInteracting,
           let hovered = hoverState.hoveredID,
           let idx = items.firstIndex(where: { $0.id == hovered }) {
            return CGFloat(idx)
        }
        return scrollModel.progress
    }

    private var discreteFocusedIndex: Int {
        if !scrollModel.isInteracting,
           let hovered = hoverState.hoveredID,
           let idx = items.firstIndex(where: { $0.id == hovered }) {
            return idx
        }
        return activeCenterIndex
    }

    private struct WindowEntry: Identifiable {
        let index: Int
        let item: ClipboardItem
        var id: UUID { item.id }
    }

    /// Pre-mount [-4, +4] around active center so incoming cards are already Metal-cached before entering view.
    private var visibleEntries: [WindowEntry] {
        guard !items.isEmpty else { return [] }
        let anchor = activeCenterIndex
        let low = max(0, anchor - 4)
        let high = min(items.count - 1, anchor + 4)
        return (low...high).map { WindowEntry(index: $0, item: items[$0]) }
    }

    private static let focusWaveAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let cardWidth: CGFloat = min(188, max(168, proxy.size.width * 0.30))
                let cardHeight: CGFloat = min(256, max(214, proxy.size.height - 46))
                let innerOffset = cardWidth * 0.625 // ~118pt
                let outerOffset = cardWidth * 1.035 // ~195pt
                let progress = scrollModel.progress
                let focusPos = continuousFocusPos
                let focusedIdx = discreteFocusedIndex

                ZStack {
                    ForEach(visibleEntries) { entry in
                        let slotDelta = CGFloat(entry.index) - progress
                        let absSlot = abs(slotDelta)
                        let focusDelta = CGFloat(entry.index) - focusPos
                        let focusDist = abs(focusDelta)
                        // Continuous focus bloom (0...1) so focus border & Paste pill glide in smoothly as card centers!
                        let focusEmphasis: Double = max(0, min(1, Double(1.0 - focusDist * 2.8)))
                        let isInteractiveFocus = entry.index == focusedIdx && focusDist < 0.35

                        let xOffset = Self.interpolatedX(slotDelta: slotDelta, inner: innerOffset, outer: outerOffset)
                        let yOffset = reduceMotion ? 0 : Self.interpolatedY(focusDist: focusDist)
                        let arcAngle = reduceMotion ? 0 : Self.interpolatedAngle(focusDelta: focusDelta)
                        let cardScale = Self.interpolatedScale(focusDist: focusDist)
                        let cardVisibleOpacity = Self.interpolatedVisibility(absSlot: absSlot)
                        let zOrder = 60.0 - Double(focusDist) * 10.0

                        FloatingCarouselCard(
                            item: entry.item,
                            index: entry.index,
                            focusDist: focusDist,
                            focusEmphasis: focusEmphasis,
                            isInteractiveFocus: isInteractiveFocus,
                            isQueued: pasteStack.contains(entry.item.id),
                            isRevealed: store.isRevealed(entry.item),
                            previewText: cardPreviewText(for: entry.item),
                            store: store,
                            width: cardWidth,
                            height: cardHeight,
                            onToggleQueue: {
                                withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                                    pasteStack.toggle(entry.item.id)
                                }
                            },
                            onPaste: { onPaste(entry.item) },
                            onInspect: { onInspect(entry.item) },
                            onCopy: { _ = ClipFlowRuntime.shared.copyToClipboard(entry.item) }
                        )
                        .scaleEffect(cardScale)
                        .rotationEffect(.degrees(arcAngle), anchor: .bottom)
                        .opacity(cardVisibleOpacity)
                        .offset(x: xOffset, y: yOffset)
                        .zIndex(zOrder)
                        .allowsHitTesting(absSlot <= 2.35 && !scrollModel.isInteracting)
                        .animation(
                            (reduceMotion || scrollModel.isInteracting) ? nil : Self.focusWaveAnimation,
                            value: hoverState.hoveredID
                        )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                .background(
                    CarouselPointerMonitor(
                        stageSize: proxy.size,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight,
                        innerOffset: innerOffset,
                        outerOffset: outerOffset,
                        reduceMotion: reduceMotion,
                        focusedSlotDelta: (scrollModel.isInteracting || isBlocked) ? 0 : (CGFloat(focusedIdx) - progress),
                        hoveredID: hoverState.hoveredID,
                        isInteracting: scrollModel.isInteracting,
                        isBlocked: isBlocked,
                        targets: (scrollModel.isInteracting || isBlocked) ? [] : visibleEntries.compactMap { entry in
                            let delta = CGFloat(entry.index) - progress
                            guard abs(delta) <= 2.35 else { return nil }
                            return CarouselHitTarget(id: entry.item.id, delta: delta)
                        },
                        onHoverChanged: { nextID in
                            guard !isBlocked, !scrollModel.isInteracting else { return }
                            if hoverState.hoveredID != nextID {
                                hoverState.hoveredID = nextID
                            }
                        },
                        onScrollBegan: {
                            scrollModel.beginNewTouch()
                        },
                        onContinuousScroll: { deltaPixels, isMomentum in
                            guard items.count > 1 else { return }
                            if hoverState.hoveredID != nil {
                                hoverState.hoveredID = nil
                            }
                            let deltaCards = -deltaPixels / (innerOffset * 0.92)
                            scrollModel.applyContinuousDelta(
                                deltaCards,
                                isMomentum: isMomentum,
                                maxIndex: items.count - 1,
                                reduceMotion: reduceMotion
                            ) { settled in
                                commitCenter(index: settled)
                            }
                        },
                        onScrollEnded: {
                            guard items.count > 1 else { return }
                            scrollModel.finishGesture(
                                maxIndex: items.count - 1,
                                reduceMotion: reduceMotion
                            ) { settled in
                                commitCenter(index: settled)
                            }
                        },
                        onDiscreteStep: { step in
                            stepCenter(by: step)
                        }
                    )
                )
            }

            floatingControlDock
        }
        .onAppear {
            scrollModel.jump(to: selectionIndex)
            store.prewarmQuickPasteAssets(around: selectionIndex, limit: 24)
        }
        .onChangeBackward(of: activeCenterIndex) {
            store.prewarmQuickPasteAssets(around: activeCenterIndex, limit: 16)
        }
        .onChangeBackward(of: isBlocked) {
            if isBlocked, scrollModel.isInteracting {
                let settled = activeCenterIndex
                scrollModel.jump(to: settled)
                commitCenter(index: settled)
            }
        }
        .onChangeBackward(of: selection.itemID) {
            let idx = selectionIndex
            if !scrollModel.isInteracting, Int(round(scrollModel.progress)) != idx {
                scrollModel.animateTo(index: idx, maxIndex: max(0, items.count - 1), reduceMotion: reduceMotion)
            }
        }
        .onChangeBackward(of: items.count) {
            let clamped = min(max(0, selectionIndex), max(0, items.count - 1))
            scrollModel.jump(to: clamped)
        }
    }

    // MARK: - Smooth Continuous Interpolation Curves

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * min(max(t, 0), 1)
    }

    static func interpolatedX(slotDelta d: CGFloat, inner: CGFloat, outer: CGFloat) -> CGFloat {
        let sign: CGFloat = d >= 0 ? 1 : -1
        let a = abs(d)
        if a <= 1 {
            return sign * lerp(0, inner, a)
        } else if a <= 2 {
            return sign * lerp(inner, outer, a - 1)
        } else {
            // Physically tuck cards beyond ±2 inward behind the solid ±2 wing card
            // so cards NEVER turn semi-transparent in open air while scrolling!
            return sign * lerp(outer, inner * 0.88, min(a - 2, 1))
        }
    }

    static func interpolatedY(focusDist d: CGFloat) -> CGFloat {
        if d <= 1 {
            return lerp(-10, 10, d)
        } else if d <= 2 {
            return lerp(10, 24, d - 1)
        } else {
            return lerp(24, 32, min(d - 2, 1))
        }
    }

    static func interpolatedScale(focusDist d: CGFloat) -> CGFloat {
        if d <= 1 {
            return lerp(1.0, 0.90, d)
        } else if d <= 2 {
            return lerp(0.90, 0.83, d - 1)
        } else {
            return lerp(0.83, 0.70, min(d - 2, 1))
        }
    }

    static func interpolatedAngle(focusDelta d: CGFloat) -> Double {
        let sign: Double = d >= 0 ? 1 : -1
        let a = Double(abs(d))
        if a <= 1 {
            return sign * (4.5 * a)
        } else if a <= 2 {
            return sign * (4.5 + 4.0 * (a - 1))
        } else {
            return sign * (8.5 - 2.0 * min(a - 2, 1))
        }
    }

    static func interpolatedVisibility(absSlot d: CGFloat) -> Double {
        // Keep every visible card 100% solid opaque; only hide once fully tucked behind the ±2 wing!
        d <= 2.65 ? 1.0 : 0.0
    }

    static func interpolatedContentOpacity(focusDist d: CGFloat) -> Double {
        if d <= 1 {
            return Double(lerp(1.0, 0.84, d))
        } else if d <= 2 {
            return Double(lerp(0.84, 0.70, d - 1))
        } else {
            return 0.62
        }
    }

    private func cardPreviewText(for item: ClipboardItem) -> String {
        guard !item.isImage else { return "" }
        if item.isSensitive && !store.isRevealed(item) {
            return store.displaySnippet(for: item)
        }
        return String(store.displayFullText(for: item).prefix(320))
    }

    private func commitCenter(index: Int) {
        guard items.indices.contains(index) else { return }
        if selection.itemID != items[index].id {
            onSelectCenter(items[index])
        }
    }

    private func stepCenter(by delta: Int) {
        guard !items.isEmpty else { return }
        let base = scrollModel.isInteracting ? Int(round(scrollModel.progress)) : activeCenterIndex
        let next = min(max(0, base + delta), items.count - 1)
        guard next != base || scrollModel.isInteracting else { return }
        hoverState.hoveredID = nil
        scrollModel.animateTo(index: next, maxIndex: items.count - 1, reduceMotion: reduceMotion) { settled in
            commitCenter(index: settled)
        }
    }

    private var floatingControlDock: some View {
        HStack(spacing: 8) {
            FloatingDockIconButton(
                systemName: "magnifyingglass",
                isActive: isSearchActive,
                accessibilityLabel: "搜索剪贴记录",
                helpText: "搜索剪贴记录 (⌘F)",
                action: onToggleSearch
            )

            if items.count > 1 {
                floatingPagerPill
            }

            if let onSwitchToList {
                FloatingDockIconButton(
                    systemName: "text.quote",
                    isActive: false,
                    accessibilityLabel: "常用片段与列表",
                    helpText: "常用片段与列表视图 (⌃→)",
                    action: onSwitchToList
                )
            }

            FloatingDockIconButton(
                systemName: "rectangle.stack",
                isActive: false,
                accessibilityLabel: "打开活页夹",
                helpText: "打开活页夹 (⌘L)",
                action: onOpenLibrary
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var floatingPagerPill: some View {
        let accent = FolioTheme.primaryAccent(for: colorScheme)
        let currentIdx = activeCenterIndex
        let dotCount = min(items.count, 7)
        let activeDot = items.count <= 7
            ? currentIdx
            : Int(round(Double(currentIdx) / Double(max(items.count - 1, 1)) * Double(dotCount - 1)))

        return HStack(spacing: 8) {
            Button {
                stepCenter(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: ClipFlowType.mono, weight: .semibold))
                    .foregroundStyle(currentIdx == 0 ? Color.secondary.opacity(0.35) : ClipFlowPalette.secondaryText(for: colorScheme))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(currentIdx == 0)
            .help("上一张 (←)")

            HStack(spacing: 4) {
                ForEach(0..<dotCount, id: \.self) { dot in
                    Capsule()
                        .fill(dot == activeDot ? accent : FolioTheme.strongHairline(for: colorScheme).opacity(0.55))
                        .frame(width: dot == activeDot ? 12 : 4.5, height: 4.5)
                }
            }
            .animation(reduceMotion ? nil : ClipFlowMotion.selection, value: activeDot)

            Text(String(format: "%02d / %02d", currentIdx + 1, items.count))
                .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                .fixedSize()

            Button {
                stepCenter(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: ClipFlowType.mono, weight: .semibold))
                    .foregroundStyle(currentIdx >= items.count - 1 ? Color.secondary.opacity(0.35) : ClipFlowPalette.secondaryText(for: colorScheme))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(currentIdx >= items.count - 1)
            .help("下一张 (→)")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule(style: .continuous)
                .fill(FolioTheme.folioPage(for: colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.95))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.09), radius: 6, y: 2)
    }
}

// MARK: - Equatable Metal-Cached Card Tile (Baked ONCE on Mount, ZERO Re-Bakes During Scroll/Hover!)

private struct BakedCarouselCardShell: View, Equatable {
    let item: ClipboardItem
    let shortcutIndex: Int
    let isRevealed: Bool
    let previewText: String
    let width: CGFloat
    let height: CGFloat
    let colorScheme: ColorScheme
    let store: ClipFlowStore

    static let shadowPad: CGFloat = 14

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.shortcutIndex == rhs.shortcutIndex
            && lhs.isRevealed == rhs.isRevealed
            && lhs.previewText == rhs.previewText
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
        let cardFill = FolioTheme.deckCardFill(depth: 0, for: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                AppIconBadgeView(item: item, size: 16)
                Text(item.sourceApp)
                    .font(.system(size: ClipFlowType.mono, weight: .medium))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    .lineLimit(1)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: ClipFlowType.mono))
                        .foregroundStyle(ClipCategory.pinned.labelColor(for: colorScheme))
                }
                Spacer(minLength: 2)
                if shortcutIndex < 9 {
                    TactileKeycap(label: "⌘\(shortcutIndex + 1)")
                }
            }

            HStack(spacing: 5) {
                Text(item.isSensitive && !isRevealed ? "受保护敏感记录" : item.title)
                    .font(.system(size: ClipFlowType.body, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(item.kind.label)
                    .font(.system(size: ClipFlowType.mono, weight: .semibold))
                    .foregroundStyle(item.kind.labelColor(for: colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(item.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize()
            }

            if item.isImage {
                ClipThumbnailView(
                    store: store,
                    item: item,
                    height: max(84, height - 118),
                    cornerRadius: 8,
                    expandsToContainer: false,
                    showsDimensionLabel: false,
                    contentMode: .fit,
                    insetPreview: false
                )
                .frame(width: max(70, width - 24), height: max(84, height - 118))
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Text(previewText)
                    .font(.system(size: item.kind == .code ? ClipFlowType.mono : ClipFlowType.meta,
                                  weight: .regular,
                                  design: item.kind == .code ? .monospaced : .default))
                    .foregroundStyle(Color.primary.opacity(0.84))
                    .lineSpacing(3)
                    .lineLimit(9)
                    .multilineTextAlignment(.leading)
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        FolioTheme.recessedWell(for: colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.45),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

            // Reserve exact footer height inside the baked card shell
            Spacer().frame(height: 24)
        }
        .padding(12)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(shape.fill(cardFill))
        .overlay(shape.strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))
        // Bake soft shadow ONCE inside the Metal texture -> zero per-frame blur cost at 120Hz!
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.34 : 0.13),
            radius: 8,
            y: 4
        )
        .padding(Self.shadowPad)
        .drawingGroup(opaque: false)
    }
}

// MARK: - Individual Floating Card (Baked Metal Shell + GPU Tint/Border + Live Interactive Footer)

private struct FloatingCarouselCard: View {
    let item: ClipboardItem
    let index: Int
    let focusDist: CGFloat
    let focusEmphasis: Double
    let isInteractiveFocus: Bool
    let isQueued: Bool
    let isRevealed: Bool
    let previewText: String
    let store: ClipFlowStore
    let width: CGFloat
    let height: CGFloat
    let onToggleQueue: () -> Void
    let onPaste: () -> Void
    let onInspect: () -> Void
    let onCopy: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
        let accent = FolioTheme.primaryAccent(for: colorScheme)
        let depthShade = min(Double(focusDist), 2.0) * (colorScheme == .dark ? 0.16 : 0.055)

        ZStack(alignment: .bottom) {
            BakedCarouselCardShell(
                item: item,
                shortcutIndex: index,
                isRevealed: isRevealed,
                previewText: previewText,
                width: width,
                height: height,
                colorScheme: colorScheme,
                store: store
            )
            .equatable()
            .frame(width: width, height: height)

            // Lightweight GPU depth tint + continuous focus border bloom (zero pop!)
            shape
                .fill(colorScheme == .dark ? Color.black.opacity(depthShade) : Color(red: 0.36, green: 0.31, blue: 0.22).opacity(depthShade))
                .frame(width: width, height: height)
                .allowsHitTesting(false)

            shape
                .strokeBorder(accent, lineWidth: 1.5)
                .frame(width: width, height: height)
                .opacity(focusEmphasis)
                .allowsHitTesting(false)

            // Interactive Card Footer overlaid cleanly on bottom 24pt slot
            HStack(spacing: 5) {
                if item.autoExpire && item.expiresAt != nil {
                    ExpiryCountdownRing(item: item, compact: true)
                } else {
                    Text(item.timeLabel)
                        .font(.system(size: ClipFlowType.mono, design: .monospaced))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                HStack(spacing: 4) {
                    Button(action: onToggleQueue) {
                        Image(systemName: isQueued ? "checkmark" : "plus")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .foregroundStyle(isQueued ? FolioTheme.sageAccent(for: colorScheme) : Color.primary.opacity(0.80))
                            .frame(width: 24, height: 24)
                            .background(
                                isQueued
                                    ? FolioTheme.sageAccent(for: colorScheme).opacity(0.14)
                                    : FolioTheme.recessedWell(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(isQueued ? "移出顺序粘贴" : "加入顺序粘贴")

                    Button(action: onPaste) {
                        HStack(spacing: 2) {
                            Text("粘贴")
                            Text("↩").font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                        }
                        .font(.system(size: ClipFlowType.mono, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .opacity(focusEmphasis)
                .allowsHitTesting(isInteractiveFocus)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(width: width)
        }
        .frame(width: width, height: height)
        .contentShape(shape)
        .onTapGesture { onPaste() }
        .contextMenu {
            Button("粘贴") { onPaste() }
            Button("查看详情 (空格)") { onInspect() }
            Button("复制") { onCopy() }
            Button(isQueued ? "移出顺序粘贴" : "加入顺序粘贴") { onToggleQueue() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.sourceApp)，\(item.title)，第 \(index + 1) 张")
    }
}

private struct FloatingDockIconButton: View {
    let systemName: String
    let isActive: Bool
    let accessibilityLabel: String
    let helpText: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let accent = FolioTheme.primaryAccent(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: ClipFlowType.meta, weight: .semibold))
                .foregroundStyle(isActive ? .white : (isHovered ? Color.primary : ClipFlowPalette.secondaryText(for: colorScheme)))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(
                            isActive
                                ? accent
                                : FolioTheme.folioPage(for: colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.96)
                        )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isActive ? accent : (isHovered ? FolioTheme.strongHairline(for: colorScheme) : FolioTheme.hairline(for: colorScheme)),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.09), radius: 6, y: 2)
                .offset(y: reduceMotion ? 0 : (isHovered ? -1 : 0))
                .contentShape(Circle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Global-Coordinate Hover Hit-Testing + Continuous Trackpad/Wheel Scroll Driver

private struct CarouselHitTarget: Equatable {
    let id: UUID
    let delta: CGFloat
}

private struct CarouselPointerMonitor: NSViewRepresentable {
    let stageSize: CGSize
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let innerOffset: CGFloat
    let outerOffset: CGFloat
    let reduceMotion: Bool
    let focusedSlotDelta: CGFloat
    let hoveredID: UUID?
    let isInteracting: Bool
    let isBlocked: Bool
    let targets: [CarouselHitTarget]
    let onHoverChanged: (UUID?) -> Void
    let onScrollBegan: () -> Void
    let onContinuousScroll: (CGFloat, Bool) -> Void
    let onScrollEnded: () -> Void
    let onDiscreteStep: (Int) -> Void

    func makeNSView(context: Context) -> CarouselPointerMonitorView {
        let view = CarouselPointerMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CarouselPointerMonitorView, context: Context) {
        view.stageSize = stageSize
        view.cardWidth = cardWidth
        view.cardHeight = cardHeight
        view.innerOffset = innerOffset
        view.outerOffset = outerOffset
        view.reduceMotion = reduceMotion
        view.focusedSlotDelta = focusedSlotDelta
        view.currentHoveredID = hoveredID
        view.isInteracting = isInteracting
        view.isBlocked = isBlocked
        view.targets = targets
        view.onHoverChanged = onHoverChanged
        view.onScrollBegan = onScrollBegan
        view.onContinuousScroll = onContinuousScroll
        view.onScrollEnded = onScrollEnded
        view.onDiscreteStep = onDiscreteStep
    }

    static func dismantleNSView(_ view: CarouselPointerMonitorView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class CarouselPointerMonitorView: NSView {
    var stageSize: CGSize = .zero
    var cardWidth: CGFloat = 188
    var cardHeight: CGFloat = 256
    var innerOffset: CGFloat = 118
    var outerOffset: CGFloat = 195
    var reduceMotion = false
    var focusedSlotDelta: CGFloat = 0
    var currentHoveredID: UUID?
    var isInteracting = false
    var isBlocked = false {
        didSet {
            if isBlocked {
                pendingExitWork?.cancel()
                pendingExitWork = nil
            }
        }
    }
    fileprivate var targets: [CarouselHitTarget] = []
    var onHoverChanged: (UUID?) -> Void = { _ in }
    var onScrollBegan: () -> Void = {}
    var onContinuousScroll: (CGFloat, Bool) -> Void = { _, _ in }
    var onScrollEnded: () -> Void = {}
    var onDiscreteStep: (Int) -> Void = { _ in }

    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var pendingExitWork: DispatchWorkItem?
    private var lastDiscreteTime: TimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        scheduleExitClear()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved {
                self.evaluatePointerLocation()
                return event
            }
            return self.handleScroll(event) ? nil : event
        }
    }

    private func evaluatePointerLocation() {
        guard !isBlocked, !isInteracting, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else {
            scheduleExitClear()
            return
        }

        let point = CGPoint(x: local.x, y: bounds.height - local.y)
        if let hitID = hitTestCard(at: point) {
            pendingExitWork?.cancel()
            pendingExitWork = nil
            if hitID != currentHoveredID {
                onHoverChanged(hitID)
            }
        } else {
            scheduleExitClear()
        }
    }

    private func scheduleExitClear() {
        guard currentHoveredID != nil, pendingExitWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingExitWork = nil
            self.onHoverChanged(nil)
        }
        pendingExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func hitTestCard(at point: CGPoint) -> UUID? {
        guard stageSize.width > 0, stageSize.height > 0 else { return nil }
        let ordered = targets.sorted { lhs, rhs in
            abs(lhs.delta - focusedSlotDelta) < abs(rhs.delta - focusedSlotDelta)
        }
        for target in ordered {
            if pointHits(point, target: target) {
                return target.id
            }
        }
        return nil
    }

    private func pointHits(_ point: CGPoint, target: CarouselHitTarget) -> Bool {
        let slotDelta = target.delta
        let focusDelta = slotDelta - focusedSlotDelta
        let focusDist = abs(focusDelta)

        let xOffset = QuickPasteFanDeckView.interpolatedX(slotDelta: slotDelta, inner: innerOffset, outer: outerOffset)
        let yOffset = reduceMotion ? 0 : QuickPasteFanDeckView.interpolatedY(focusDist: focusDist)
        let scale = QuickPasteFanDeckView.interpolatedScale(focusDist: focusDist)
        let angleDeg = reduceMotion ? 0 : QuickPasteFanDeckView.interpolatedAngle(focusDelta: focusDelta)

        let w = cardWidth * scale
        let h = cardHeight * scale
        let centerX = stageSize.width / 2 + xOffset
        let centerY = stageSize.height / 2 + yOffset

        let pivotX = centerX
        let pivotY = centerY + h / 2

        let dx = point.x - pivotX
        let dy = point.y - pivotY
        let radians = -angleDeg * .pi / 180.0
        let cosA = CGFloat(cos(radians))
        let sinA = CGFloat(sin(radians))
        let rx = dx * cosA - dy * sinA
        let ry = dx * sinA + dy * cosA

        return abs(rx) <= (w / 2 + 3) && ry >= -(h + 3) && ry <= 3
    }

    @discardableResult
    func handleScroll(_ event: NSEvent) -> Bool {
        // Yield all wheel/trackpad events to the active card detail overlay (scrolling text/code, zooming images).
        guard !isBlocked, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else { return false }

        // Discrete notched mouse wheel
        if !event.hasPreciseScrollingDeltas {
            let dominantDelta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY
            guard abs(dominantDelta) > 0.1 else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastDiscreteTime >= 0.065 else { return true }
            lastDiscreteTime = now
            onDiscreteStep(dominantDelta < 0 ? 1 : -1)
            return true
        }

        // Precise trackpad / Magic Mouse: 1:1 continuous finger tracking + velocity-continuous spring handoff!
        if event.phase == .mayBegin || event.phase == .began {
            onScrollBegan()
        }

        if event.momentumPhase == .ended || event.phase == .cancelled {
            onScrollEnded()
            return true
        }

        let dominantDelta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        let isMomentum = event.momentumPhase != []

        if abs(dominantDelta) > 0.05 {
            let gain: CGFloat = isMomentum ? 0.78 : 1.0
            onContinuousScroll(dominantDelta * gain, isMomentum)
            return true
        }

        if event.phase == .ended && !isMomentum {
            onScrollEnded()
            return true
        }

        return true
    }

    func stop() {
        pendingExitWork?.cancel()
        pendingExitWork = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}

// MARK: - Type-to-Search & Floating Shortcut Trigger (⌘F / ⌘L / Blind Typing)

struct FloatingQuickPasteKeyMonitor: NSViewRepresentable {
    let isSearchActive: Bool
    let isBlocked: Bool
    let onStartSearch: (String?) -> Void
    let onDismissSearch: () -> Void
    let onOpenLibrary: () -> Void

    func makeNSView(context: Context) -> FloatingQuickPasteKeyView {
        let view = FloatingQuickPasteKeyView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FloatingQuickPasteKeyView, context: Context) {
        view.isSearchActive = isSearchActive
        view.isBlocked = isBlocked
        view.onStartSearch = onStartSearch
        view.onDismissSearch = onDismissSearch
        view.onOpenLibrary = onOpenLibrary
    }

    static func dismantleNSView(_ view: FloatingQuickPasteKeyView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class FloatingQuickPasteKeyView: NSView {
    var isSearchActive = false
    var isBlocked = false
    var onStartSearch: (String?) -> Void = { _ in }
    var onDismissSearch: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !isBlocked, let window, window.isVisible, event.windowNumber == window.windowNumber,
              !isHiddenOrHasHiddenAncestor else { return false }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            onStartSearch(nil)
            return true
        }
        if mods == .command, let ch = event.charactersIgnoringModifiers?.lowercased(), ch == "l" || ch == "o" {
            onOpenLibrary()
            return true
        }
        if event.keyCode == 53, isSearchActive {
            onDismissSearch()
            return true
        }

        guard !isSearchActive else { return false }
        let isEditing = window.firstResponder is NSTextView
        guard !isEditing else { return false }
        guard mods.isEmpty || mods == .shift else { return false }

        let reservedKeyCodes: Set<UInt16> = [36, 48, 49, 51, 53, 76, 117, 123, 124, 125, 126]
        guard !reservedKeyCodes.contains(event.keyCode) else { return false }

        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
            return false
        }

        onStartSearch(chars)
        return true
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}
