import AppKit
import SwiftUI

/// Native-refresh-rate two-stage physical card extraction driver for the Archival Filing Box.
/// Stage 1 (`0.0 -> 0.45`): Card pulls straight UP out of its slot while STILL behind front folders & box lip.
/// Stage 2 (`0.45 -> 1.0`): Card clears the front lip, flips to top z-order (`300`), and expands to fill the card box column.
/// Dismissing plays the exact physical reverse (contract -> flip behind front folders -> slide back down into slot).
@MainActor
final class CardExtractionModel: ObservableObject {
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var targetItemID: UUID?

    private var animatingTo: CGFloat = 0
    private let displayLink = DisplayLinkDriver()
    private var lastTimestamp: TimeInterval = 0
    private var onComplete: (() -> Void)?

    var isActive: Bool { targetItemID != nil || progress > 0.001 }
    var isExpanded: Bool { animatingTo > 0.5 && targetItemID != nil }

    func isExtracting(_ id: UUID) -> Bool {
        targetItemID == id && (progress > 0.001 || animatingTo > 0.5)
    }

    func toggle(itemID: UUID, reduceMotion: Bool) {
        if targetItemID == itemID && animatingTo > 0.5 {
            collapse(reduceMotion: reduceMotion)
        } else {
            expand(itemID: itemID, reduceMotion: reduceMotion)
        }
    }

    func expand(itemID: UUID, reduceMotion: Bool) {
        targetItemID = itemID
        animatingTo = 1
        onComplete = nil
        if reduceMotion {
            stopTimer()
            progress = 1
            return
        }
        startLoop()
    }

    func collapse(reduceMotion: Bool, onComplete: (() -> Void)? = nil) {
        guard isActive else {
            onComplete?()
            return
        }
        animatingTo = 0
        self.onComplete = onComplete
        if reduceMotion {
            stopTimer()
            progress = 0
            targetItemID = nil
            let cb = self.onComplete
            self.onComplete = nil
            cb?()
            return
        }
        startLoop()
    }

    func reset() {
        stopTimer()
        progress = 0
        animatingTo = 0
        targetItemID = nil
        onComplete = nil
    }

    private func startLoop() {
        guard !displayLink.isRunning else { return }
        lastTimestamp = ProcessInfo.processInfo.systemUptime
        displayLink.start { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.001, min(0.033, now - lastTimestamp))
        lastTimestamp = now

        let duration: CGFloat = animatingTo > 0.5 ? 0.28 : 0.24
        let step = CGFloat(dt) / duration
        let next: CGFloat
        if animatingTo > progress {
            next = min(animatingTo, progress + step)
        } else {
            next = max(animatingTo, progress - step)
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = next
        }

        if abs(next - animatingTo) < 0.0005 {
            stopTimer()
            progress = animatingTo
            if animatingTo < 0.5 {
                targetItemID = nil
            }
            let cb = onComplete
            onComplete = nil
            cb?()
        }
    }

    private func stopTimer() {
        displayLink.stop()
    }

    deinit {
        MainActor.assumeIsolated {
            stopTimer()
        }
    }
}

struct FolioTimeDeckView: View {
    let items: [ClipboardItem]
    @ObservedObject var store: ClipFlowStore
    @ObservedObject var selection: HistorySelection
    @ObservedObject var pasteStack: PasteStackState
    @ObservedObject var extraction: CardExtractionModel
    let palette: ClipFlowPalette
    var onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)? = nil
    let onInspectOverlay: (ClipboardItem) -> Void
    let onPasteItem: (ClipboardItem) -> Void

    init(
        items: [ClipboardItem],
        store: ClipFlowStore,
        selection: HistorySelection,
        pasteStack: PasteStackState,
        extraction: CardExtractionModel = CardExtractionModel(),
        palette: ClipFlowPalette,
        onInspectFrom: ((ClipboardItem, InspectorSourceAnchor) -> Void)? = nil,
        onInspectOverlay: @escaping (ClipboardItem) -> Void,
        onPasteItem: @escaping (ClipboardItem) -> Void
    ) {
        self.items = items
        self.store = store
        self.selection = selection
        self.pasteStack = pasteStack
        self.extraction = extraction
        self.palette = palette
        self.onInspectFrom = onInspectFrom
        self.onInspectOverlay = onInspectOverlay
        self.onPasteItem = onPasteItem
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var scrollModel = CarouselScrollModel()
    @ViewState private var showsMarkdownPreview = false
    @ViewState private var codeLanguage = "自动识别"
    @ViewState private var copiedItemID: UUID?
    @ViewState private var hoveredPeekIndex: Int?
    @ViewState private var activeCardRectInWindow: CGRect = .zero
    @ViewState private var isDialScrubbing = false
    @ViewState private var isLongGliding = false
    @ViewState private var pendingDeleteItem: ClipboardItem? = nil

    private var selectedIndex: Int {
        if let id = selection.itemID, let idx = items.firstIndex(where: { $0.id == id }) {
            return idx
        }
        return 0
    }

    private var activeCenterIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(0, scrollModel.nearestIndex), items.count - 1)
    }

    private var activeItem: ClipboardItem? {
        guard !items.isEmpty, items.indices.contains(activeCenterIndex) else { return items.first }
        return items[activeCenterIndex]
    }

    private struct DeckWindowEntry: Identifiable {
        let index: Int
        let item: ClipboardItem
        var id: UUID { item.id }
    }

    /// Mount up to 6 rear cards above (`index < anchor`, slotDelta +1...+6) and 5 front cards below
    /// (`index > anchor`, slotDelta -1...-5) so the top-to-bottom filing box shows 5 rear + 1 risen + 4 front = 10 visible.
    private var visibleEntries: [DeckWindowEntry] {
        guard !items.isEmpty else { return [] }
        let anchor = activeCenterIndex
        let low = max(0, anchor - 6)
        let high = min(items.count - 1, anchor + 5)
        return (low...high).map { DeckWindowEntry(index: $0, item: items[$0]) }
    }

    var body: some View {
        let activeLineCount: Int = {
            guard !scrollModel.isInteracting, let item = activeItem, !item.isImage else { return 0 }
            return Self.fastLineCount(of: item.fullText)
        }()

        HStack(alignment: .center, spacing: 10) {
            if !items.isEmpty {
                deckStage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if items.count > 1 {
                FolioTimeDialView(
                    items: items,
                    progress: scrollModel.progress,
                    selectedIndex: activeCenterIndex,
                    isScrolling: scrollModel.isInteracting || isLongGliding,
                    onClickRatio: { ratio in
                        let target = min(max(0, Int(round(ratio * CGFloat(items.count - 1)))), items.count - 1)
                        if extraction.isActive {
                            extraction.collapse(reduceMotion: reduceMotion) {
                                glideTo(index: target)
                            }
                        } else {
                            glideTo(index: target)
                        }
                    },
                    onScrubRatio: { ratio in
                        if !isDialScrubbing { isDialScrubbing = true }
                        if extraction.isActive {
                            extraction.collapse(reduceMotion: reduceMotion)
                        }
                        scrollModel.scrub(to: ratio * CGFloat(items.count - 1), maxIndex: items.count - 1)
                    },
                    onScrubEnd: {
                        isDialScrubbing = false
                        scrollModel.finishScrub(maxIndex: items.count - 1, reduceMotion: reduceMotion) { settled in
                            commitCenter(index: settled)
                        }
                    }
                )
                .frame(width: 64)
                .frame(maxHeight: .infinity)
            }
        }
        .background(
            FolioDeckScrollMonitor(
                activeWebContentMayOverflow: activeLineCount > 18,
                isBlocked: !isEnabled || extraction.isActive,
                onScrollBegan: {
                    scrollModel.beginNewTouch()
                },
                onContinuousScroll: { deltaPixels, isMomentum in
                    guard items.count > 1 else { return }
                    let deltaCards = -deltaPixels / 92.0
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
                onStep: { delta in
                    stepDeck(by: delta)
                }
            )
        )
        .onAppear {
            scrollModel.jump(to: selectedIndex)
            store.prewarmQuickPasteAssets(around: selectedIndex, limit: 80, in: items)
        }
        .onChangeBackward(of: scrollModel.isInteracting) {
            if !scrollModel.isInteracting {
                isLongGliding = false
                showsMarkdownPreview = false
                codeLanguage = "自动识别"
                store.prewarmQuickPasteAssets(around: activeCenterIndex, limit: 24, in: items)
            }
        }
        .onChangeBackward(of: activeCenterIndex) {
            if !scrollModel.isInteracting {
                showsMarkdownPreview = false
                codeLanguage = "自动识别"
            }
        }
        .onChangeBackward(of: selection.itemID) {
            let idx = selectedIndex
            if !scrollModel.isInteracting, Int(round(scrollModel.progress)) != idx {
                scrollModel.animateTo(index: idx, maxIndex: max(0, items.count - 1), reduceMotion: reduceMotion)
            }
        }
        .onChangeBackward(of: items.count) {
            let clamped = min(max(0, selectedIndex), max(0, items.count - 1))
            scrollModel.jump(to: clamped)
            if let expandedID = extraction.targetItemID, !items.contains(where: { $0.id == expandedID }) {
                extraction.reset()
            }
        }
        .onChangeBackward(of: isEnabled) {
            if !isEnabled, scrollModel.isInteracting {
                let settled = activeCenterIndex
                scrollModel.jump(to: settled)
                commitCenter(index: settled)
            }
        }
        .confirmationDialog(
            "删除这条剪贴卡片？",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteItem
        ) { target in
            Button("删除卡片", role: .destructive) {
                if extraction.targetItemID == target.id {
                    extraction.reset()
                }
                store.delete(target.id)
                pendingDeleteItem = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: { target in
            Text("「\(peekingTitle(for: target))」将被永久移除，此操作不能撤销。")
        }
    }

    private func commitCenter(index: Int) {
        guard items.indices.contains(index) else { return }
        if selection.itemID != items[index].id {
            store.select(items[index])
        }
    }

    private func stepDeck(by delta: Int) {
        guard !items.isEmpty else { return }
        let base = scrollModel.isInteracting ? activeCenterIndex : selectedIndex
        let next = min(max(0, base + delta), items.count - 1)
        guard items.indices.contains(next) else { return }
        scrollModel.animateTo(index: next, maxIndex: items.count - 1, reduceMotion: reduceMotion) { settled in
            commitCenter(index: settled)
        }
    }

    private func selectCard(at index: Int) {
        guard items.indices.contains(index) else { return }
        hoveredPeekIndex = nil
        glideTo(index: index)
    }

    /// Glides smoothly to any target card while capping visual cascade travel to 8 cards so
    /// jumping across 70+ items stays locked at 120fps instead of mounting 70 intermediate views.
    private func glideTo(index target: Int) {
        guard items.indices.contains(target) else { return }
        // Immediately prewarm target + neighbors at high priority BEFORE the cascade arrives!
        store.prewarmQuickPasteAssets(around: target, limit: 12, in: items, priority: .userInitiated)
        let current = scrollModel.progress
        let distance = CGFloat(target) - current
        let isLongJump = abs(distance) > 3
        if isLongJump {
            isLongGliding = true
        }
        if !reduceMotion && abs(distance) > 10 {
            let launch = CGFloat(target) - (distance > 0 ? 8 : -8)
            scrollModel.scrub(to: launch, maxIndex: items.count - 1)
        }
        scrollModel.animateTo(index: target, maxIndex: items.count - 1, reduceMotion: reduceMotion) { settled in
            isLongGliding = false
            commitCenter(index: settled)
        }
    }

    private func openCardDetail(_ item: ClipboardItem) {
        if scrollModel.isInteracting {
            let settled = activeCenterIndex
            scrollModel.jump(to: settled)
            commitCenter(index: settled)
        }
        extraction.toggle(itemID: item.id, reduceMotion: reduceMotion)
    }

    /// Physical archival filing-box stage (Top = #01 newest -> Bottom = #N oldest) with Two-Stage Card Extraction:
    /// - Rear folders (`slotDelta > 0`, i.e. newer `index < progress`, up to 5) sit tucked above the selected card.
    /// - Selected card (`slotDelta == 0`) sits prominently in focus; on detail toggle, it pulls straight UP out of
    ///   the slot, flips to top z-order (`300`), and expands to fill the entire card box column.
    /// - Front folders (`slotDelta < 0`, i.e. older `index > progress`, up to 4) sit IN FRONT OF the selected card's
    ///   lower margin (higher z-order), anchored dynamically above the archival box front lip.
    private func deckStage() -> some View {
        GeometryReader { proxy in
            let rearCount = 5
            let frontCount = 4
            let topMargin: CGFloat = 4
            let rearStep: CGFloat = 20
            let frontStep: CGFloat = 28
            let frontBaseHeight: CGFloat = 52
            let boxLipHeight: CGFloat = 40
            let progress = scrollModel.progress
            let visibleRearSpan = min(CGFloat(rearCount), max(0, progress))
            let extractedTopY: CGFloat = topMargin + rearStep * visibleRearSpan
            let remainingFront = max(0, CGFloat(max(0, items.count - 1)) - progress)
            let visibleFrontSpan = min(CGFloat(frontCount), max(1.0, remainingFront))
            let hasFrontCards = remainingFront > 0.02
            let frontStartY = max(
                extractedTopY + 150,
                proxy.size.height - boxLipHeight - frontBaseHeight - (visibleFrontSpan - 1) * frontStep
            )
            // Fixed card height (sized for the fully-risen position) so scrolling only translates cards and never reflows content.
            let cardHeight = max(250, proxy.size.height - (topMargin + rearStep * CGFloat(rearCount)) - 10)
            let bodyBottomClearance = hasFrontCards
                ? (boxLipHeight + frontBaseHeight + (visibleFrontSpan - 1) * frontStep - 10)
                : (boxLipHeight + 14)

            // Fluid overlapping extraction curves (zero mechanical pause!):
            // - Pull-up starts immediately (0.0 -> 0.72) in one smooth ease-out arc.
            // - Forward flip (zIndex -> 300) triggers early at ep > 0.24 once the card starts rising out,
            //   and expansion (0.22 -> 1.0) overlaps smoothly right into the same continuous upward motion!
            let ep = extraction.progress
            let rawPull = min(1, max(0, ep / 0.72))
            let pullEase = 1 - pow(1 - rawPull, 3)
            let rawExpand = min(1, max(0, (ep - 0.22) / 0.78))
            let expandEase = 1 - pow(1 - rawExpand, 3)
            let boxClearShift: CGFloat = reduceMotion ? 0 : (12 * pullEase)
            let backgroundDimOpacity: Double = max(0, 1.0 - Double(expandEase) * 1.18)

            let hoveredRearIndex: Int? = {
                guard !scrollModel.isInteracting, !extraction.isActive, let h = hoveredPeekIndex else { return nil }
                return (progress - CGFloat(h)) >= 0.72 ? h : nil
            }()

            ZStack(alignment: .top) {
                ForEach(visibleEntries) { entry in
                    // Top-to-bottom filing order: newer cards (index < progress) tuck above (slotDelta > 0);
                    // older cards (index > progress) stack in front below (slotDelta < 0).
                    let slotDelta = progress - CGFloat(entry.index)
                    let absSlot = abs(slotDelta)
                    let isExtractingCard = extraction.isExtracting(entry.item.id)
                    let isRearOrFrontTab = !isExtractingCard && absSlot >= 0.72
                    let isPeekHovered = !scrollModel.isInteracting && !extraction.isActive && hoveredPeekIndex == entry.index && isRearOrFrontTab
                    // Continuous depth & smooth focus ramp that reaches 0.0 cleanly at absSlot == 0.72 (ZERO flash!)
                    let continuousDepth: CGFloat = isExtractingCard ? 0 : min(3.0, absSlot * 0.65)
                    let focusEmphasis: Double = isExtractingCard ? 1.0 : max(0, min(1, Double(1.0 - absSlot / 0.72)))
                    let baseWidthScale = Self.interpolatedWidthScale(slotDelta: slotDelta)
                    let baseTopY = Self.interpolatedTopY(
                        slotDelta: slotDelta,
                        rearCount: rearCount,
                        frontCount: frontCount,
                        rearStep: rearStep,
                        frontStep: frontStep,
                        extractedTopY: extractedTopY,
                        frontStartY: frontStartY
                    )

                    // Physical in-slot pull-out (preserves true filing-box z-order, width & height!):
                    // - Hovered front (bottom) card pulls partway UP inside its own slot while cards in front keep covering its bottom.
                    // - Hovered rear (top) card pulls slightly UP while cards in front of it (including the active card) gently part DOWN,
                    //   opening a real physical gap inside its slot to reveal the top of its content box.
                    let isPartedBelowHoveredRear: Bool = {
                        guard let hr = hoveredRearIndex else { return false }
                        return entry.index > hr && slotDelta > -0.72
                    }()
                    let topY: CGFloat = {
                        if isExtractingCard {
                            return baseTopY * (1 - pullEase)
                        }
                        if slotDelta < 0 {
                            let pullUp: CGFloat = isPeekHovered ? Self.hoverPeekPull : 0
                            return baseTopY - pullUp + boxClearShift
                        }
                        if isPeekHovered {
                            return max(2, baseTopY - 8)
                        }
                        if isPartedBelowHoveredRear {
                            return baseTopY + Self.hoverRearPartShift
                        }
                        return baseTopY
                    }()
                    let cardWidth: CGFloat = {
                        let normalW = max(180, proxy.size.width * baseWidthScale)
                        guard isExtractingCard else { return normalW }
                        return normalW + (proxy.size.width - normalW) * expandEase
                    }()
                    let resolvedHeight: CGFloat = {
                        guard isExtractingCard else { return cardHeight }
                        return cardHeight + (proxy.size.height - cardHeight) * expandEase
                    }()
                    let resolvedBottomClearance: CGFloat = isExtractingCard
                        ? (bodyBottomClearance * (1 - expandEase))
                        : bodyBottomClearance

                    let cardOpacity: Double = {
                        let base = Self.interpolatedVisibility(slotDelta: slotDelta)
                        if isExtractingCard { return 1.0 }
                        return base * backgroundDimOpacity
                    }()

                    // True physical filing-box z-order: hovered cards stay INSIDE their own slot (never pop out to front!).
                    // Only full detail extraction (ep > 0.24) flips in front to zIndex = 300.
                    let zOrder: Double = {
                        if isExtractingCard && ep > 0.24 {
                            return 300.0
                        }
                        return slotDelta >= 0
                            ? (80.0 - Double(slotDelta) * 10.0)
                            : (80.0 + Double(-slotDelta) * 20.0)
                    }()

                    Group {
                        if !isRearOrFrontTab {
                            frontFocusCard(
                                item: entry.item,
                                index: entry.index,
                                continuousDepth: continuousDepth,
                                focusEmphasis: focusEmphasis,
                                bottomClearance: resolvedBottomClearance,
                                isFastPreview: (scrollModel.isInteracting || isDialScrubbing || isLongGliding) && !isExtractingCard,
                                isExtractedDetail: isExtractingCard && extraction.isExpanded,
                                metadataReveal: isExtractingCard ? Double(expandEase) : 0
                            )
                        } else {
                            PeekingFolderCardView(
                                item: entry.item,
                                store: store,
                                colorScheme: colorScheme,
                                depthStep: Int((continuousDepth * 24).rounded()),
                                shortcutIndex: entry.index,
                                isFrontFolder: slotDelta < 0,
                                isHovered: isPeekHovered,
                                isRevealed: store.isRevealed(entry.item),
                                wellColor: unifiedContentWellColor
                            ) {
                                selectCard(at: entry.index)
                            }
                            .equatable()
                        }
                    }
                    .frame(width: cardWidth, height: resolvedHeight)
                    .offset(y: topY)
                    .opacity(cardOpacity)
                    .zIndex(zOrder)
                    .allowsHitTesting(
                        isExtractingCard
                            ? true
                            : (!extraction.isActive && !scrollModel.isInteracting && slotDelta >= -4.35 && slotDelta <= 5.35)
                    )
                    .animation(
                        (reduceMotion || scrollModel.isInteracting) ? nil : .spring(response: 0.24, dampingFraction: 0.86),
                        value: hoveredPeekIndex
                    )
                }

                // Archival Box Front Pocket Lip (anchored at bottom; stays IN FRONT during Stage 1, behind during Stage 2!)
                archivalBoxFrontLip(height: boxLipHeight)
                    .frame(width: proxy.size.width, height: boxLipHeight)
                    .offset(y: max(0, proxy.size.height - boxLipHeight) + boxClearShift)
                    .opacity(backgroundDimOpacity)
                    .allowsHitTesting(!extraction.isActive)
                    .zIndex(220)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .circular))
            .overlay(DeckHoverTracker(onMove: { y in
                // Geometry-based hover matching each card's CURRENT visual exposed strip
                // (accounting for in-slot front pull-up and rear parting shift).
                guard let y, !extraction.isActive, !scrollModel.isInteracting else {
                    if hoveredPeekIndex != nil { hoveredPeekIndex = nil }
                    return
                }
                var tabs: [(index: Int, baseTop: CGFloat, isFront: Bool)] = []
                for e in visibleEntries {
                    let sd = progress - CGFloat(e.index)
                    if abs(sd) < 0.72 { continue }
                    let top = Self.interpolatedTopY(
                        slotDelta: sd, rearCount: rearCount, frontCount: frontCount,
                        rearStep: rearStep, frontStep: frontStep,
                        extractedTopY: extractedTopY, frontStartY: frontStartY
                    )
                    tabs.append((e.index, top, sd < 0))
                }
                tabs.sort { $0.baseTop < $1.baseTop }
                let lipTop = proxy.size.height - boxLipHeight
                let curRear = hoveredRearIndex
                let curHovered = hoveredPeekIndex

                func visualTop(of tab: (index: Int, baseTop: CGFloat, isFront: Bool)) -> CGFloat {
                    if tab.isFront {
                        return (curHovered == tab.index) ? (tab.baseTop - Self.hoverPeekPull) : tab.baseTop
                    } else {
                        if curHovered == tab.index {
                            return max(2, tab.baseTop - 8)
                        }
                        if let hr = curRear, tab.index > hr {
                            return tab.baseTop + Self.hoverRearPartShift
                        }
                        return tab.baseTop
                    }
                }

                let activeVisualTop = curRear != nil ? (extractedTopY + Self.hoverRearPartShift) : extractedTopY

                var found: Int?
                for i in tabs.indices {
                    let tab = tabs[i]
                    let start = visualTop(of: tab)
                    let end: CGFloat = {
                        if tab.isFront {
                            return i + 1 < tabs.count ? visualTop(of: tabs[i + 1]) : lipTop
                        } else {
                            let nextRearTop = (i + 1 < tabs.count && !tabs[i + 1].isFront)
                                ? visualTop(of: tabs[i + 1])
                                : activeVisualTop
                            return min(nextRearTop, activeVisualTop)
                        }
                    }()
                    if y >= start && y < end {
                        found = tab.index
                        break
                    }
                }
                if hoveredPeekIndex != found { hoveredPeekIndex = found }
            }))
        }
    }

    nonisolated static let hoverPeekPull: CGFloat = 56
    nonisolated static let hoverRearPartShift: CGFloat = 52

    static func interpolatedTopY(
        slotDelta: CGFloat,
        rearCount: Int,
        frontCount: Int,
        rearStep: CGFloat,
        frontStep: CGFloat,
        extractedTopY: CGFloat,
        frontStartY: CGFloat
    ) -> CGFloat {
        let maxRear = CGFloat(rearCount)
        let maxFront = CGFloat(frontCount)
        if slotDelta >= 0 {
            if slotDelta <= maxRear {
                return extractedTopY - rearStep * slotDelta
            } else {
                // Physically tuck behind the +5 card while keeping full opacity until concealed.
                return (extractedTopY - rearStep * maxRear) + (slotDelta - maxRear) * 14
            }
        } else {
            let f = -slotDelta
            if f <= 1 {
                // Smoothly rise up from the front folder slot into focus (or drop back down!)
                let eased = f // linear: constant velocity, no stop-start pulses
                return extractedTopY + (frontStartY - extractedTopY) * eased
            } else if f <= maxFront {
                return frontStartY + frontStep * (f - 1)
            } else {
                // Physically tuck behind the archival box front lip while staying solid opaque until concealed.
                return frontStartY + frontStep * (maxFront - 1) + (f - maxFront) * 24
            }
        }
    }

    static func interpolatedWidthScale(slotDelta: CGFloat) -> CGFloat {
        if slotDelta >= 0 {
            // 5 rear cards recede gently narrower into the back of the box (97.5% -> 83.5%).
            if slotDelta <= 5 {
                return 0.975 - slotDelta * 0.028
            }
            return 0.83
        } else {
            // 4 front cards expand gently wider toward the front of the box (97.5% -> 100%).
            let f = min(4, -slotDelta)
            return 0.975 + f * 0.00625
        }
    }

    static func interpolatedVisibility(slotDelta: CGFloat) -> Double {
        (slotDelta >= -4.55 && slotDelta <= 5.55) ? 1.0 : 0.0
    }

    private func archivalBoxFrontLip(height: CGFloat) -> some View {
        let shape = ArchivalBoxLipShape(cornerRadius: 14, notchWidth: 68, notchDepth: 6)
        let boxFill = colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.145, green: 0.155, blue: 0.175, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.935, green: 0.925, blue: 0.900, alpha: 1))

        return ZStack {
            shape
                .fill(boxFill)
                .overlay(
                    shape.strokeBorder(FolioTheme.strongHairline(for: colorScheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.36 : 0.09), radius: 8, y: -3)

            HStack(spacing: 10) {
                if activeCenterIndex < 9 {
                    TactileKeycap(label: "⌘\(activeCenterIndex + 1)")
                } else {
                    Color.clear.frame(width: 24, height: 18)
                }

                Spacer(minLength: 8)

                // Recessed Brass/Paper Index Label Plate (`13 / 78` + `↑ ↓`)
                HStack(spacing: 6) {
                    Button {
                        stepDeck(by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(activeCenterIndex == 0)
                    .foregroundStyle(activeCenterIndex == 0 ? Color.secondary.opacity(0.35) : ClipFlowPalette.secondaryText(for: colorScheme))
                    .help("上一张卡片 (↑)")

                    Text(String(format: "%02d / %02d", activeCenterIndex + 1, max(1, items.count)))
                        .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.84))
                        .fixedSize()

                    Button {
                        stepDeck(by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(activeCenterIndex + 1 >= items.count)
                    .foregroundStyle(activeCenterIndex + 1 >= items.count ? Color.secondary.opacity(0.35) : ClipFlowPalette.secondaryText(for: colorScheme))
                    .help("下一张卡片 (↓)")
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(FolioTheme.deckCardFill(depth: 0, for: colorScheme), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1))

                Spacer(minLength: 8)

                Text("空格 详情")
                    .font(.system(size: ClipFlowType.mono, weight: .medium))
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme).opacity(0.75))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 5)
        }
        .frame(height: height)
    }

    private func frontFocusCard(
        item: ClipboardItem,
        index: Int,
        continuousDepth: CGFloat,
        focusEmphasis: Double,
        bottomClearance: CGFloat,
        isFastPreview: Bool,
        isExtractedDetail: Bool,
        metadataReveal: Double
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let markdownAvailable = !isFastPreview
            && (!item.isSensitive || store.isRevealed(item))
            && DetailTextFormat.isMarkdown(store.displayFullText(for: item))
        let isQueued = pasteStack.contains(item.id)
        let justCopied = copiedItemID == item.id

        return VStack(alignment: .leading, spacing: 10) {
            // Card Header: Metadata on left + Complete Action Group on right (unobstructed above front folders)
            HStack(alignment: .center, spacing: 8) {
                AppIconBadgeView(item: item, size: 26)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(frontTitle(for: item))
                            .font(.system(size: ClipFlowType.cardTitle, weight: .semibold))
                            .lineLimit(1)
                        Text(item.kind.label)
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .foregroundStyle(item.kind.labelColor(for: colorScheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(item.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        if item.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: ClipFlowType.mono))
                                .foregroundStyle(ClipCategory.pinned.labelColor(for: colorScheme))
                        }
                    }

                    Text(cardMetadata(for: item))
                        .font(.system(size: ClipFlowType.meta))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        .lineLimit(1)
                }
                .layoutPriority(-1)

                Spacer(minLength: 4)

                if item.autoExpire && item.expiresAt != nil {
                    ExpiryCountdownRing(item: item, compact: true)
                }

                // Compact Action Icon Group
                HStack(spacing: 4) {
                    if item.privacy != .standard {
                        Button {
                            store.toggleReveal(item.id)
                        } label: {
                            Image(systemName: store.isRevealed(item) ? "eye.slash" : "eye")
                                .font(.system(size: ClipFlowType.mono, weight: .semibold))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 26, horizontalPadding: 0, cornerRadius: 7))
                        .help(store.isRevealed(item) ? "隐藏敏感内容" : "显示敏感内容")
                    }

                    Button {
                        withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                            pasteStack.toggle(item.id)
                        }
                    } label: {
                        Image(systemName: isQueued ? "checkmark" : "plus")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(FolioButtonStyle(prominence: isQueued ? .tonalAccent : .secondary, height: 26, horizontalPadding: 0, cornerRadius: 7))
                    .help(isQueued ? "移出顺序粘贴" : "加入顺序粘贴")

                    Button {
                        if ClipFlowRuntime.shared.copyToClipboard(item) {
                            withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                                copiedItemID = item.id
                            }
                            let currentID = item.id
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                if copiedItemID == currentID {
                                    withAnimation(reduceMotion ? nil : ClipFlowMotion.fade) {
                                        copiedItemID = nil
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(FolioButtonStyle(prominence: justCopied ? .tonalAccent : .secondary, height: 26, horizontalPadding: 0, cornerRadius: 7))
                    .help(justCopied ? "已复制到剪贴板" : "复制")

                    Button {
                        withAnimation(reduceMotion ? nil : ClipFlowMotion.selection) {
                            store.togglePin(item.id)
                        }
                    } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .foregroundStyle(item.pinned ? ClipCategory.pinned.labelColor(for: colorScheme) : Color.primary.opacity(0.78))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 26, horizontalPadding: 0, cornerRadius: 7))
                    .help(item.pinned ? "取消置顶" : "置顶卡片")

                    Button {
                        openCardDetail(item)
                    } label: {
                        Image(systemName: isExtractedDetail ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(FolioButtonStyle(prominence: isExtractedDetail ? .tonalAccent : .secondary, height: 26, horizontalPadding: 0, cornerRadius: 7))
                    .help(isExtractedDetail ? "放回归档盒 (Esc)" : "抽出卡片查看详情 (空格)")
                    .accessibilityLabel(isExtractedDetail ? "放回归档盒" : "抽出卡片查看详情")

                    // Single Primary Action Button
                    Button {
                        onPasteItem(item)
                    } label: {
                        HStack(spacing: 3) {
                            Text("粘贴")
                            Text("↩").font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                        }
                    }
                    .buttonStyle(FolioButtonStyle(prominence: .primary, height: 26, horizontalPadding: 10, cornerRadius: 7))

                    Button {
                        pendingDeleteItem = item
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: ClipFlowType.mono, weight: .semibold))
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(FolioButtonStyle(prominence: .secondary, height: 26, horizontalPadding: 0, cornerRadius: 7))
                    .help("删除此卡片")
                    .accessibilityLabel("删除此卡片")
                }
            }

            Divider().overlay(FolioTheme.hairline(for: colorScheme))

            // Pure Rich Body Canvas (stays steady in height; bottom smoothly reveals archival metadata instead of stretching!)
            let metadataFooterHeight: CGFloat = 118
            frontBody(item: item, markdownAvailable: markdownAvailable, isFastPreview: isFastPreview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.bottom, max(0, bottomClearance - metadataFooterHeight * CGFloat(metadataReveal)))

            if metadataReveal > 0.01 {
                extractedCardMetadataFooter(item: item)
                    .frame(height: metadataFooterHeight * CGFloat(metadataReveal), alignment: .top)
                    .clipped()
                    .opacity(metadataReveal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(shape.fill(FolioTheme.deckCardFill(continuousDepth: continuousDepth, for: colorScheme)))
        .overlay(
            shape.strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
        )
        .overlay(
            shape.strokeBorder(
                FolioTheme.primaryAccent(for: colorScheme).opacity(0.46 * focusEmphasis),
                lineWidth: 1.25
            )
        )
        .shadow(
            color: .black.opacity((colorScheme == .dark ? 0.28 : 0.07) * focusEmphasis),
            radius: 10,
            y: 3
        )
    }

    /// Archival metadata footer revealed at the bottom of the card once extracted from the filing box.
    private func extractedCardMetadataFooter(item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(FolioTheme.hairline(for: colorScheme))

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: ClipFlowType.mono, weight: .semibold))
                Text("更多信息")
                    .font(.system(size: ClipFlowType.meta, weight: .semibold))
            }
            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))

            VStack(spacing: 7) {
                metadataRow(label: "隐私级别", value: item.privacy.label)
                metadataRow(label: "存储方式", value: item.localOnly ? "仅本地保存" : "普通本地历史")
                metadataRow(label: "保留策略", value: item.autoExpire ? "复制 5 分钟后删除" : "手动清理")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FolioTheme.recessedWell(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.bottom, 4)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: ClipFlowType.meta, weight: .medium))
                .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: ClipFlowType.meta, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.88))
        }
    }

    private var unifiedContentWellColor: Color {
        colorScheme == .dark
            ? Color(red: 0.110, green: 0.122, blue: 0.153) // #1C1F27 (exact match to ClipFlowSyntax dark)
            : Color(red: 0.965, green: 0.957, blue: 0.933) // #F6F4EE (exact match to ClipFlowSyntax light)
    }

    private var unifiedContentWellNSColor: NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 0.110, green: 0.122, blue: 0.153, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1)
    }

    @ViewBuilder
    private func frontBody(item: ClipboardItem, markdownAvailable: Bool, isFastPreview: Bool) -> some View {
        let wellColor = unifiedContentWellColor
        let displayText = item.isImage ? "" : store.displayFullText(for: item)
        let preRendered: PreRenderedCode? = (!item.isImage && (!item.isSensitive || store.isRevealed(item)))
            ? DetailTextPrewarmer.shared.cached(for: item, text: displayText, language: codeLanguage)
            : nil

        if isFastPreview {
            // Zero-WebView, zero-disk-decode O(1) RAM preview while scrubbing/gliding at 120Hz —
            // already uses pre-rendered Code syntax highlighting & Markdown/Table blocks so styles NEVER pop after scroll!
            if item.isImage {
                if (!item.isSensitive || store.isRevealed(item)), let cached = store.cachedImagePreview(for: item) {
                    Image(nsImage: cached)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                        .background(wellColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(wellColor)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: item.isSensitive && !store.isRevealed(item) ? "lock.fill" : "photo")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                                Text(item.imageDimensionText ?? item.title)
                                    .font(.system(size: ClipFlowType.meta, weight: .medium))
                                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            }
                        )
                }
            } else if let preRendered, preRendered.isMarkdown, let blocks = preRendered.markdownBlocks, !blocks.isEmpty {
                NativeMarkdownDocumentView(blocks: blocks, dark: colorScheme == .dark)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(wellColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipped()
            } else if let preRendered, item.kind == .code {
                Text(colorScheme == .dark ? preRendered.dark : preRendered.light)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .background(wellColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipped()
            } else {
                Text(String(displayText.prefix(800)))
                    .font(.system(
                        size: item.kind == .code ? 12 : ClipFlowType.cardTitle,
                        weight: .regular,
                        design: item.kind == .code ? .monospaced : .default
                    ))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .background(wellColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipped()
            }
        } else if item.isImage {
            GeometryReader { geo in
                if (!item.isSensitive || store.isRevealed(item)), let url = store.imageURL(for: item) {
                    ZoomableDetailImage(
                        url: url,
                        placeholder: store.cachedImagePreview(for: item),
                        canvasBackground: unifiedContentWellNSColor
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ClipThumbnailView(
                        store: store,
                        item: item,
                        height: max(80, geo.size.height),
                        cornerRadius: 10,
                        showsDimensionLabel: true,
                        contentMode: .fit,
                        insetPreview: true
                    )
                }
            }
        } else if let preRendered, preRendered.isMarkdown, let blocks = preRendered.markdownBlocks, !blocks.isEmpty {
            // Instant 0ms native Markdown & Table card (identical to fast-preview, zero WKWebView boot delay!)
            SoftEdgeScrollView(showsEdgeEffects: false) {
                NativeMarkdownDocumentView(blocks: blocks, dark: colorScheme == .dark)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(wellColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let preRendered, item.kind == .code {
            // Instant 0ms pre-highlighted native Code card (identical during scroll & at rest!)
            SoftEdgeScrollView(showsEdgeEffects: false) {
                Text(colorScheme == .dark ? preRendered.dark : preRendered.light)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(wellColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if item.kind == .code || markdownAvailable {
            let instantText = String(displayText.prefix(1200))
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Instant 0ms native fallback underneath WKWebView if pre-render hasn't finished yet
                    Text(instantText)
                        .font(.system(
                            size: item.kind == .code ? 12 : ClipFlowType.cardTitle,
                            weight: .regular,
                            design: item.kind == .code ? .monospaced : .default
                        ))
                        .lineSpacing(4)
                        .foregroundStyle(Color.primary.opacity(0.86))
                        .frame(width: geo.size.width, height: max(80, geo.size.height), alignment: .topLeading)
                        .padding(14)
                        .background(wellColor)

                    DetailTextRenderer(
                        text: displayText,
                        markdown: showsMarkdownPreview,
                        language: markdownAvailable && item.kind != .code && codeLanguage == "自动识别" ? "markdown" : codeLanguage,
                        dark: colorScheme == .dark
                    )
                    .frame(width: geo.size.width, height: max(80, geo.size.height))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if (!item.isSensitive || store.isRevealed(item)), let swatch = HexSwatchParser.parse(from: displayText) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(swatch.color)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 1))
                        Text("色值 \(swatch.hex)")
                            .font(.system(size: ClipFlowType.meta, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                        Spacer()
                    }
                    .padding(8)
                    .background(wellColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                SoftEdgeScrollView(showsEdgeEffects: false) {
                    Text(displayText)
                        .font(.system(size: ClipFlowType.cardTitle, weight: .regular))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    wellColor,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        }
    }

    /// Fast zero-regex first-line extraction for 120Hz folder headers (avoids 3,000+ regex passes/sec).
    static func fastFirstLine(of text: String) -> String {
        let prefix = text.prefix(180)
        for line in prefix.split(whereSeparator: \.isNewline) {
            var trimmed = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "#" || $0 == ">" || $0 == "-" || $0 == "*" })
            trimmed = trimmed.drop(while: { $0 == " " || $0 == "\t" })
            if !trimmed.isEmpty {
                return String(trimmed)
            }
        }
        return ""
    }

    /// Zero-allocation UTF-8 newline counter for metadata & scroll overflow checks.
    private static func fastLineCount(of text: String) -> Int {
        var count = 1
        for byte in text.utf8.prefix(16_384) where byte == 0x0A {
            count += 1
        }
        return count
    }

    private func peekingTitle(for item: ClipboardItem) -> String {
        if item.isSensitive && !store.isRevealed(item) {
            return "受保护敏感内容 •••"
        }
        if item.isImage {
            return item.title
        }
        let summary = Self.fastFirstLine(of: store.displayFullText(for: item))
        return summary.isEmpty ? item.title : summary
    }

    private func frontTitle(for item: ClipboardItem) -> String {
        if item.isSensitive && !store.isRevealed(item) {
            return "受保护的敏感记录"
        }
        if item.isImage {
            return item.title
        }
        let summary = Self.fastFirstLine(of: store.displayFullText(for: item))
        return summary.isEmpty ? item.title : summary
    }

    private func cardMetadata(for item: ClipboardItem) -> String {
        var parts = [item.sourceApp, item.timeLabel]
        if let dim = item.imageDimensionText {
            parts.append(dim)
        } else if !item.isImage {
            let lineCount = Self.fastLineCount(of: item.fullText)
            if lineCount > 1 {
                parts.append("\(lineCount) 行")
            }
        }
        if item.localOnly {
            parts.append("仅存本机")
        }
        return parts.joined(separator: " · ")
    }
}

/// Equatable peeking folder card: skips SwiftUI body re-evaluation on every 120Hz scroll frame
/// when only its translation (`offset(y:)`) or `zIndex` changes.
private struct PeekingFolderCardView: View, Equatable {
    let item: ClipboardItem
    let store: ClipFlowStore
    let colorScheme: ColorScheme
    let depthStep: Int
    let shortcutIndex: Int
    let isFrontFolder: Bool
    let isHovered: Bool
    let isRevealed: Bool
    let wellColor: Color
    let action: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.pinned == rhs.item.pinned
            && lhs.item.autoExpire == rhs.item.autoExpire
            && lhs.item.expiresAt == rhs.item.expiresAt
            && lhs.colorScheme == rhs.colorScheme
            && lhs.depthStep == rhs.depthStep
            && lhs.shortcutIndex == rhs.shortcutIndex
            && lhs.isFrontFolder == rhs.isFrontFolder
            && lhs.isHovered == rhs.isHovered
            && lhs.isRevealed == rhs.isRevealed
    }

    private var titleText: String {
        if item.isSensitive && !isRevealed {
            return "受保护敏感内容 •••"
        }
        if item.isImage {
            return item.title
        }
        let summary = FolioTimeDeckView.fastFirstLine(of: store.displayFullText(for: item))
        return summary.isEmpty ? item.title : summary
    }

    var body: some View {
        let continuousDepth = CGFloat(depthStep) / 24.0
        let shape = RoundedRectangle(cornerRadius: ClipFlowLayout.rowRadius, style: .continuous)
        let titleOpacity = isHovered ? 0.96 : (isFrontFolder ? 0.84 : max(0.58, 0.90 - Double(continuousDepth) * 0.10))

        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    AppIconBadgeView(item: item, size: 14)
                    Text(titleText)
                        .font(.system(size: ClipFlowType.meta, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(titleOpacity))
                        .lineLimit(1)

                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: ClipFlowType.mono))
                            .foregroundStyle(ClipCategory.pinned.labelColor(for: colorScheme))
                    }

                    Spacer(minLength: 6)

                    if item.autoExpire && item.expiresAt != nil {
                        ExpiryCountdownRing(item: item, compact: true)
                    } else {
                        Text(item.timeLabel)
                            .font(.system(size: ClipFlowType.mono, weight: .regular, design: .monospaced))
                            .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }

                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: ClipFlowType.mono, weight: .medium))
                        .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                }
                .padding(.horizontal, 12)
                .frame(height: 25)

                // Always mounted inside the card body so the content box translates rigidly 1:1 with the card.
                let previewLine = item.isImage
                    ? (item.imageDimensionText ?? "图片内容")
                    : (item.isSensitive && !isRevealed ? "••••••••" : store.displaySnippet(for: item))
                Group {
                    if item.isImage, let thumb = store.cachedImagePreview(for: item) {
                        // Use Color.clear.overlay so ultra-wide panoramic images (e.g. 1174x188) NEVER
                        // expand the card's VStack horizontally beyond cardWidth.
                        Color.clear
                            .overlay(
                                Image(nsImage: thumb)
                                    .resizable()
                                    .interpolation(.medium)
                                    .aspectRatio(contentMode: .fit)
                                    .padding(4)
                            )
                            .clipped()
                    } else {
                        let previewText: String = {
                            guard !item.isImage, !(item.isSensitive && !isRevealed) else { return previewLine }
                            return String(store.displayFullText(for: item).prefix(320))
                        }()
                        Text(previewText)
                            .font(.system(size: ClipFlowType.mono, weight: .regular, design: item.kind == .code ? .monospaced : .default))
                            .foregroundStyle(Color.primary.opacity(isHovered ? 0.86 : 0.72))
                            .lineLimit(5)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(wellColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(FolioTheme.hairline(for: colorScheme), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 3)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(shape.fill(FolioTheme.deckCardFill(continuousDepth: continuousDepth, for: colorScheme)))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    isHovered ? FolioTheme.strongHairline(for: colorScheme) : FolioTheme.hairline(for: colorScheme),
                    lineWidth: 1
                )
            )
            .shadow(
                color: isFrontFolder ? .black.opacity(colorScheme == .dark ? 0.24 : 0.05) : .clear,
                radius: isFrontFolder ? 5 : 0,
                y: isFrontFolder ? -1 : 0
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换到第 \(shortcutIndex + 1) 张卡片：\(titleText)")
    }
}

/// Front pocket lip of the archival filing box with a subtle concave thumb-notch along its top edge.
/// Conforms to `InsettableShape` with true circular bottom arcs matching `RoundedRectangle(cornerRadius: 14, style: .circular)`
/// so `strokeBorder` stays 100% crisp and unclipped along the bottom and corners.
private struct ArchivalBoxLipShape: InsettableShape {
    var cornerRadius: CGFloat = 14
    var topCornerRadius: CGFloat = 8
    var notchWidth: CGFloat = 68
    var notchDepth: CGFloat = 6
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rawRect: CGRect) -> Path {
        let rect = rawRect.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 1, rect.height > 1 else { return Path() }
        let br = max(0, min(cornerRadius - insetAmount, rect.height / 2, rect.width / 2))
        let tr = max(0, min(topCornerRadius - insetAmount, rect.height / 3, rect.width / 4))
        let midX = rect.midX
        let halfNotch = min(notchWidth / 2, rect.width / 4)
        let nd = min(notchDepth, rect.height * 0.25)

        var path = Path()
        // Top-left corner
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + tr))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + tr, y: rect.minY),
            radius: tr
        )
        // Top edge to notch start
        path.addLine(to: CGPoint(x: midX - halfNotch, y: rect.minY))
        // Smooth concave archival thumb-notch
        path.addCurve(
            to: CGPoint(x: midX, y: rect.minY + nd),
            control1: CGPoint(x: midX - halfNotch * 0.45, y: rect.minY),
            control2: CGPoint(x: midX - halfNotch * 0.35, y: rect.minY + nd)
        )
        path.addCurve(
            to: CGPoint(x: midX + halfNotch, y: rect.minY),
            control1: CGPoint(x: midX + halfNotch * 0.35, y: rect.minY + nd),
            control2: CGPoint(x: midX + halfNotch * 0.45, y: rect.minY)
        )
        // Top edge to top-right corner
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr),
            radius: tr
        )
        // Right edge to bottom-right circular corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY),
            radius: br
        )
        // Bottom edge to bottom-left circular corner
        path.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - br),
            radius: br
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Right Inner Margin Vertical Time-Tick Scrubber (Concept 3)

struct FolioTimeDialView: View {
    let items: [ClipboardItem]
    let progress: CGFloat
    let selectedIndex: Int
    var isScrolling: Bool = false
    let onClickRatio: (CGFloat) -> Void
    let onScrubRatio: (CGFloat) -> Void
    let onScrubEnd: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrubbing = false
    @State private var isBeadHovered = false
    @State private var showsScrollBadge = false
    @State private var hideBadgeWorkItem: DispatchWorkItem?
    @State private var cachedAnchors: [TimeAnchor] = []

    struct TimeAnchor: Equatable {
        let fraction: CGFloat
        let index: Int
        let label: String
    }

    /// Deduplicates adjacent identical relative-time strings (e.g. repeated "2秒前") by
    /// falling back to ordinal index markers (`#4`, `#7`) so every tick anchor adds clarity.
    static func buildAnchors(for items: [ClipboardItem]) -> [TimeAnchor] {
        guard items.count > 1 else {
            return [TimeAnchor(fraction: 0, index: 0, label: "现在")]
        }
        let maxIdx = items.count - 1
        let rawIndices = [0, max(1, items.count / 3), max(1, (items.count * 2) / 3), maxIdx]
        var uniqueIndices: [Int] = []
        for idx in rawIndices {
            let clamped = min(max(0, idx), maxIdx)
            if !uniqueIndices.contains(clamped) {
                uniqueIndices.append(clamped)
            }
        }

        var result: [TimeAnchor] = []
        var usedLabels: Set<String> = []
        for (pos, idx) in uniqueIndices.enumerated() {
            let fraction = CGFloat(idx) / CGFloat(maxIdx)
            let label: String
            if pos == 0 {
                label = "现在"
                usedLabels.insert("现在")
                usedLabels.insert("刚刚")
            } else {
                let candidate = items[idx].timeLabel
                if !candidate.isEmpty && !usedLabels.contains(candidate) {
                    label = candidate
                    usedLabels.insert(candidate)
                } else {
                    label = "#\(idx + 1)"
                }
            }
            result.append(TimeAnchor(fraction: fraction, index: idx, label: label))
        }
        return result
    }

    private var anchors: [TimeAnchor] {
        cachedAnchors.isEmpty ? Self.buildAnchors(for: items) : cachedAnchors
    }

    private func refreshAnchors() {
        cachedAnchors = Self.buildAnchors(for: items)
    }

    var body: some View {
        GeometryReader { proxy in
            let insetY: CGFloat = 18
            let trackHeight = max(1, proxy.size.height - insetY * 2)
            let normalizedProgress = items.count > 1
                ? min(1, max(0, progress / CGFloat(items.count - 1)))
                : 0
            // Top = newest ("现在", #01); Bottom = oldest (#N).
            // Matches downward finger/wheel motion pulling rear cards down & moving the bead down in unison!
            let beadY = insetY + normalizedProgress * trackHeight
            let accent = FolioTheme.sageAccent(for: colorScheme)
            let showsBadge = isScrubbing || showsScrollBadge || isBeadHovered

            ZStack(alignment: .topLeading) {
                // Ruler ticks drawn cleanly on Canvas
                Canvas { context, size in
                    let tickCount = 28
                    let usable = max(1, size.height - insetY * 2)
                    let tickColor = colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.18)
                    let majorColor = colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.35)

                    var spinePath = Path()
                    spinePath.move(to: CGPoint(x: 9, y: insetY))
                    spinePath.addLine(to: CGPoint(x: 9, y: size.height - insetY))
                    context.stroke(spinePath, with: .color(tickColor), lineWidth: 1)

                    for i in 0...tickCount {
                        let f = CGFloat(i) / CGFloat(tickCount)
                        let y = insetY + f * usable
                        let isMajor = i % 7 == 0
                        var tick = Path()
                        tick.move(to: CGPoint(x: isMajor ? 3 : 6, y: y))
                        tick.addLine(to: CGPoint(x: isMajor ? 15 : 12, y: y))
                        context.stroke(tick, with: .color(isMajor ? majorColor : tickColor), lineWidth: isMajor ? 1.2 : 1)
                    }
                }

                // Flush-right deduplicated Time Anchor Labels matching outer container edge
                ForEach(Array(anchors.enumerated()), id: \.offset) { _, anchor in
                    let isNearActive = abs(anchor.index - selectedIndex) == 0
                    Text(anchor.label)
                        .font(.system(size: ClipFlowType.mono, weight: isNearActive ? .semibold : .medium, design: anchor.label.hasPrefix("#") ? .monospaced : .default))
                        .foregroundStyle(isNearActive ? accent : ClipFlowPalette.secondaryText(for: colorScheme))
                        .lineLimit(1)
                        .frame(width: proxy.size.width - 18, alignment: .trailing)
                        .position(x: 18 + (proxy.size.width - 18) / 2, y: insetY + anchor.fraction * trackHeight)
                        .opacity(showsBadge ? 0.36 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsBadge)
                }

                // Floating rank badge beside the green bead: visible while scrolling/scrubbing or hovering the green bead,
                // and auto-hides smoothly once scrolling settles.
                Text(String(format: "#%02d", selectedIndex + 1))
                    .font(.system(size: ClipFlowType.mono, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent, in: Capsule(style: .continuous))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 3, y: 1)
                    .position(x: 18 + (proxy.size.width - 18) / 2, y: beadY)
                    .opacity(showsBadge ? 1 : 0)
                    .scaleEffect(showsBadge ? 1.0 : 0.88)
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsBadge)

                // Active Bead Indicator
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.88), lineWidth: 1.5))
                    .scaleEffect((isScrubbing || isBeadHovered) ? 1.25 : 1.0)
                    .position(x: 9, y: beadY)
                    .animation(reduceMotion ? nil : ClipFlowMotion.selection, value: isScrubbing || isBeadHovered)

                // Native AppKit scrub surface with `mouseDownCanMoveWindow = false` so dragging
                // scrubs the time dial at 120Hz (and clicking animates smoothly!) without dragging the window.
                TimeDialScrubOverlay(
                    insetY: insetY,
                    beadCenter: CGPoint(x: 9, y: beadY),
                    onClick: { ratio in
                        isScrubbing = false
                        onClickRatio(ratio)
                    },
                    onScrub: { ratio in
                        if !isScrubbing { isScrubbing = true }
                        onScrubRatio(ratio)
                    },
                    onEnd: {
                        isScrubbing = false
                        onScrubEnd()
                    },
                    onBeadHoverChange: { hovered in
                        if isBeadHovered != hovered {
                            isBeadHovered = hovered
                        }
                    }
                )
            }
            .help("拖动或点击时间尺快速定位卡片")
        }
        .padding(.vertical, 6)
        .onAppear {
            refreshAnchors()
        }
        .onChangeBackward(of: items.count) {
            refreshAnchors()
        }
        .onChangeBackward(of: items.first?.id) {
            refreshAnchors()
        }
        .onChangeBackward(of: isScrolling) {
            updateScrollBadgeVisibility(scrolling: isScrolling)
        }
        .onChangeBackward(of: selectedIndex) {
            // Also flash briefly when stepping via keyboard, clicking a card, or discrete wheel clicks.
            if !isScrubbing {
                updateScrollBadgeVisibility(scrolling: true)
                if !isScrolling {
                    updateScrollBadgeVisibility(scrolling: false)
                }
            }
        }
        .onDisappear {
            hideBadgeWorkItem?.cancel()
            hideBadgeWorkItem = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间刻度拨尺")
        .accessibilityValue("第 \(selectedIndex + 1) 张，共 \(items.count) 张")
    }

    private func updateScrollBadgeVisibility(scrolling: Bool) {
        hideBadgeWorkItem?.cancel()
        hideBadgeWorkItem = nil
        if scrolling {
            if !showsScrollBadge {
                showsScrollBadge = true
            }
        } else if showsScrollBadge {
            let work = DispatchWorkItem {
                showsScrollBadge = false
            }
            hideBadgeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }
}

private struct TimeDialScrubOverlay: NSViewRepresentable {
    let insetY: CGFloat
    let beadCenter: CGPoint
    let onClick: (CGFloat) -> Void
    let onScrub: (CGFloat) -> Void
    let onEnd: () -> Void
    let onBeadHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> TimeDialScrubNSView {
        let view = TimeDialScrubNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TimeDialScrubNSView, context: Context) {
        view.insetY = insetY
        view.beadCenter = beadCenter
        view.onClick = onClick
        view.onScrub = onScrub
        view.onEnd = onEnd
        view.onBeadHoverChange = onBeadHoverChange
    }
}

@MainActor
final class TimeDialScrubNSView: NSView {
    static let beadHoverRadius: CGFloat = 15

    var insetY: CGFloat = 18
    var beadCenter: CGPoint = CGPoint(x: 9, y: 18) {
        didSet {
            if oldValue != beadCenter, let lastHoverPoint {
                let hovered = Self.isPointNearBead(lastHoverPoint, beadCenter: beadCenter)
                if hovered != isBeadHovered {
                    isBeadHovered = hovered
                    let callback = onBeadHoverChange
                    DispatchQueue.main.async {
                        callback(hovered)
                    }
                }
            }
        }
    }
    var onClick: (CGFloat) -> Void = { _ in }
    var onScrub: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onBeadHoverChange: (Bool) -> Void = { _ in }

    private var downPoint: NSPoint?
    private var didDrag = false
    private var trackingAreaRef: NSTrackingArea?
    private var lastHoverPoint: NSPoint?
    private var isBeadHovered = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func isPointNearBead(_ point: CGPoint, beadCenter: CGPoint) -> Bool {
        hypot(point.x - beadCenter.x, point.y - beadCenter.y) <= beadHoverRadius
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        lastHoverPoint = local
        updateBeadHover(at: local)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        lastHoverPoint = local
        updateBeadHover(at: local)
    }

    override func mouseExited(with event: NSEvent) {
        lastHoverPoint = nil
        if isBeadHovered {
            isBeadHovered = false
            onBeadHoverChange(false)
        }
    }

    private func updateBeadHover(at local: NSPoint) {
        let hovered = Self.isPointNearBead(local, beadCenter: beadCenter)
        if hovered != isBeadHovered {
            isBeadHovered = hovered
            onBeadHoverChange(hovered)
        }
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !didDrag, let start = downPoint, hypot(local.x - start.x, local.y - start.y) >= 2 {
            didDrag = true
        }
        if didDrag {
            onScrub(ratio(for: local))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let r = ratio(for: local)
        if didDrag {
            onScrub(r)
            onEnd()
        } else {
            onClick(r)
        }
        downPoint = nil
        didDrag = false
    }

    private func ratio(for local: NSPoint) -> CGFloat {
        let trackHeight = max(1, bounds.height - insetY * 2)
        let clampedY = min(max(local.y - insetY, 0), trackHeight)
        return clampedY / trackHeight
    }
}

// MARK: - Subtle Hex Color Swatch Detector

enum HexSwatchParser {
    static func parse(from text: String) -> (hex: String, color: Color)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 64 else { return nil }
        guard let range = trimmed.range(of: #"#[0-9A-Fa-f]{6}\b"#, options: .regularExpression) else {
            return nil
        }
        let hexString = String(trimmed[range]).uppercased()
        let digits = hexString.dropFirst()
        guard let rgb = UInt64(digits, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return (hexString, Color(red: r, green: g, blue: b))
    }
}

// MARK: - Smart Trackpad & Mouse Wheel Deck Flipping

private struct FolioDeckScrollMonitor: NSViewRepresentable {
    let activeWebContentMayOverflow: Bool
    let isBlocked: Bool
    let onScrollBegan: () -> Void
    let onContinuousScroll: (CGFloat, Bool) -> Void
    let onScrollEnded: () -> Void
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> FolioDeckScrollMonitorView {
        let view = FolioDeckScrollMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FolioDeckScrollMonitorView, context: Context) {
        view.activeWebContentMayOverflow = activeWebContentMayOverflow
        view.isBlocked = isBlocked
        view.onScrollBegan = onScrollBegan
        view.onContinuousScroll = onContinuousScroll
        view.onScrollEnded = onScrollEnded
        view.onStep = onStep
    }

    static func dismantleNSView(_ view: FolioDeckScrollMonitorView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class FolioDeckScrollMonitorView: NSView {
    var activeWebContentMayOverflow = false
    var isBlocked = false
    var onScrollBegan: () -> Void = {}
    var onContinuousScroll: (CGFloat, Bool) -> Void = { _, _ in }
    var onScrollEnded: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }
    private var monitor: Any?
    private var lastStepTime: TimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        // Yield all wheel/trackpad events when a detail inspector or modal overlay is active.
        guard !isBlocked, let window, window.isVisible, event.windowNumber == window.windowNumber,
              !isHiddenOrHasHiddenAncestor else { return false }

        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return false }

        let isHorizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let dominantDelta = isHorizontalGesture ? event.scrollingDeltaX : event.scrollingDeltaY

        // Yield vertical scroll to an overflowing inner text/code scroll container or zoomed image.
        if !isHorizontalGesture, shouldYieldToInnerScroll(at: event.locationInWindow, deltaY: event.scrollingDeltaY, in: window) {
            return false
        }

        // Discrete notched mouse wheel (aligned with top-to-bottom filing box & time dial:
        // scroll up -> newer card at top (-1); scroll down -> older card below (+1)).
        if !event.hasPreciseScrollingDeltas {
            guard abs(dominantDelta) > 0.1 else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastStepTime >= 0.065 else { return true }
            lastStepTime = now
            onStep(dominantDelta > 0 ? -1 : 1)
            return true
        }

        // Precise trackpad / Magic Mouse: 1:1 continuous finger tracking + smooth spring handoff
        if event.phase == .mayBegin || event.phase == .began {
            onScrollBegan()
        }

        if event.momentumPhase == .ended || event.phase == .cancelled {
            onScrollEnded()
            return true
        }

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

    private func shouldYieldToInnerScroll(at windowPoint: NSPoint, deltaY: CGFloat, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView,
              let hit = contentView.hitTest(contentView.convert(windowPoint, from: nil)) else {
            return false
        }

        var cursor: NSView? = hit
        while let view = cursor {
            if let canvas = view as? DetailImageCanvas, canvas.viewport.zoom > 1.01 {
                return true
            }
            if String(describing: type(of: view)).contains("WKWebView") {
                return activeWebContentMayOverflow
            }
            if let scrollView = view as? NSScrollView, let document = scrollView.documentView {
                let clipHeight = scrollView.contentView.bounds.height
                let docHeight = document.bounds.height
                guard docHeight > clipHeight + 2 else { return false }
                let minY = scrollView.contentView.bounds.minY
                let maxY = scrollView.contentView.bounds.maxY
                let canScrollUp = minY > 1
                let canScrollDown = maxY < docHeight - 1
                if deltaY > 0 && canScrollUp { return true }
                if deltaY < 0 && canScrollDown { return true }
                return false
            }
            cursor = view.superview
        }
        return false
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


// MARK: - Geometry hover tracker (click-through)

private struct DeckHoverTracker: NSViewRepresentable {
    let onMove: (CGFloat?) -> Void

    func makeNSView(context: Context) -> DeckHoverTrackerView {
        let v = DeckHoverTrackerView()
        v.onMove = onMove
        return v
    }

    func updateNSView(_ view: DeckHoverTrackerView, context: Context) {
        view.onMove = onMove
    }
}

@MainActor
final class DeckHoverTrackerView: NSView {
    var onMove: (CGFloat?) -> Void = { _ in }
    private var area: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(new)
        area = new
    }

    override func mouseMoved(with event: NSEvent) {
        onMove(convert(event.locationInWindow, from: nil).y)
    }

    override func mouseEntered(with event: NSEvent) {
        onMove(convert(event.locationInWindow, from: nil).y)
    }

    override func mouseExited(with event: NSEvent) {
        onMove(nil)
    }
}
