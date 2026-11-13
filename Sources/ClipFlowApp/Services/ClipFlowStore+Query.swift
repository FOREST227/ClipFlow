import SwiftUI

extension ClipFlowStore {
    var filteredItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = sortedItems.filter(matchesSelectedCategory)

        guard !query.isEmpty else {
            return base
        }

        return base.filter { ClipboardSearch.matches($0, query: query) }
    }

    var selectedItem: ClipboardItem? {
        if let selectedItemID,
           let selected = filteredItems.first(where: { $0.id == selectedItemID }) {
            return selected
        }

        return filteredItems.first
    }

    var metrics: [FlowMetric] {
        let protectedCount = items.filter(\.isSensitive).count
        let codeCount = items.filter { $0.kind == .code }.count
        let stackCount = Set(items.flatMap(\.labels)).count

        return [
            FlowMetric(
                value: "\(items.count)",
                title: "当前条目",
                detail: "仅保存在这台 Mac 上的最近剪贴内容",
                icon: "waveform.path.ecg.rectangle",
                tint: ClipCategory.pinned.tint
            ),
            FlowMetric(
                value: "\(max(stackCount, 1))",
                title: "智能信号",
                detail: "结合内容类型、来源应用与复用行为生成",
                icon: "square.3.layers.3d.top.filled",
                tint: ClipCategory.images.tint
            ),
            FlowMetric(
                value: "\(max(protectedCount, codeCount))",
                title: "重点内容",
                detail: "高价值代码或敏感内容会被优先显示",
                icon: "lock.badge.clock",
                tint: ClipCategory.protected.tint
            )
        ]
    }

    var recentItems: [ClipboardItem] {
        Array(sortedItems.prefix(50))
    }

    var quickPasteItems: [ClipboardItem] {
        let pins = sortedItems.filter(\.pinned)
        let recent = sortedItems.filter { !$0.pinned }
        return Array((pins + recent).prefix(50))
    }

    func count(for category: ClipCategory) -> Int {
        sortedItems.filter { matchesSelectedCategory($0, category: category) }.count
    }

    func item(withID id: UUID) -> ClipboardItem? {
        items.first { $0.id == id && !$0.isExpired() }
    }

    func select(_ item: ClipboardItem) {
        guard selectedItemID != item.id else { return }
        selectedItemID = item.id
    }

    func toggleReveal(_ itemID: UUID) {
        if revealedItemIDs.contains(itemID) {
            revealedItemIDs.remove(itemID)
            lastCaptureStatus = "敏感内容已隐藏"
        } else {
            revealedItemIDs.insert(itemID)
            lastCaptureStatus = "敏感内容已显示"
        }
    }

    func isRevealed(_ item: ClipboardItem) -> Bool {
        item.privacy == .standard || revealedItemIDs.contains(item.id)
    }

    func displaySnippet(for item: ClipboardItem) -> String {
        guard !item.isExpired() else { return "内容已过期" }
        if item.secretPayloadUnavailable == true {
            return SensitivePayloadStore.unreadableStatus
        }
        if item.isImage && !isRevealed(item) {
            return "图片预览已隐藏"
        }
        return isRevealed(item) ? item.snippet : masked(text: item.snippet)
    }

    func displayFullText(for item: ClipboardItem) -> String {
        guard !item.isExpired() else { return "内容已过期" }
        if item.secretPayloadUnavailable == true {
            return SensitivePayloadStore.unreadableStatus
        }
        if item.isImage && !isRevealed(item) {
            return "图片预览已隐藏"
        }
        if item.isImage {
            return item.snippet
        }
        return isRevealed(item) ? item.fullText : masked(text: item.fullText)
    }

    func hudItems(matching query: String) -> [ClipboardItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = quickPasteItems.isEmpty ? recentItems : quickPasteItems

        guard !normalized.isEmpty else {
            return base
        }

        return base.filter { ClipboardSearch.matches($0, query: normalized) }
    }

    var protectedCount: Int {
        items.filter(\.isSensitive).count
    }

    var excludedAppCount: Int {
        effectiveExcludedBundleIDs.count
    }

    var statusSummary: String {
        capturePaused ? "已暂停剪贴监听" : lastCaptureStatus
    }

    private var sortedItems: [ClipboardItem] {
        sortItems(items.filter { !$0.isExpired() })
    }

    private func masked(text: String) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(repeating: "•", count: max(8, min(compact.count, 28)))
    }

    func ensureSelectionStillValid() {
        guard let selectedItemID else {
            self.selectedItemID = filteredItems.first?.id
            return
        }

        if !filteredItems.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = filteredItems.first?.id
        }
    }

    private func matchesSelectedCategory(_ item: ClipboardItem) -> Bool {
        matchesSelectedCategory(item, category: selectedCategory)
    }

    private func matchesSelectedCategory(_ item: ClipboardItem, category: ClipCategory) -> Bool {
        switch category {
        case .all:
            return true
        case .pinned:
            return item.pinned
        case .text:
            return item.kind == .text
        case .code:
            return item.kind == .code
        case .links:
            return item.kind == .link
        case .images:
            return item.kind == .image
        case .protected:
            return item.isSensitive
        }
    }
}
