import Foundation

extension ClipFlowStore {
    func snippets(matching query: String) -> [SavedSnippet] {
        SnippetLibrary.sorted(snippets).filter { SnippetLibrary.matches($0, query: query) }
    }

    func snippet(withID id: UUID) -> SavedSnippet? {
        snippets.first { $0.id == id }
    }

    @discardableResult
    func createSnippet(title: String, body: String, category: String?, localOnly: Bool = false) -> SavedSnippet? {
        guard SnippetLibrary.hasBody(body) else {
            lastCaptureStatus = SnippetLibrary.emptyBodyStatus
            return nil
        }
        let order = (snippets.map(\.order).min() ?? 1) - 1
        let snippet = SnippetLibrary.make(
            title: title,
            body: body,
            category: category,
            order: order,
            localOnly: localOnly
        )
        snippets.append(snippet)
        lastCaptureStatus = localOnly ? SnippetLibrary.savedSensitiveStatus : "已新建片段"
        return snippet
    }

    @discardableResult
    func updateSnippet(id: UUID, title: String, body: String, category: String?) -> Bool {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return false }
        guard SnippetLibrary.hasBody(body) else {
            lastCaptureStatus = SnippetLibrary.emptyBodyStatus
            return false
        }
        snippets[index].title = SnippetLibrary.normalizedTitle(title, body: body)
        snippets[index].body = body
        snippets[index].category = SnippetLibrary.normalizedCategory(category)
        snippets[index].updatedAt = Date()
        lastCaptureStatus = SnippetLibrary.updatedStatus
        return true
    }

    func deleteSnippet(_ id: UUID) {
        guard let snippet = snippets.first(where: { $0.id == id }) else { return }
        if !snippet.localOnly {
            snippetTombstones[id] = Date()
        }
        snippets.removeAll { $0.id == id }
        lastCaptureStatus = SnippetLibrary.deletedStatus
    }

    func moveSnippets(from offsets: IndexSet, to destination: Int) {
        snippets = SnippetLibrary.moving(snippets, from: offsets, to: destination, now: Date())
    }

    func moveSnippet(id: UUID, by direction: Int) {
        snippets = SnippetLibrary.moving(snippets, id: id, by: direction, now: Date())
    }

    /// Saves history text as a snippet. Sensitive items are refused until `confirmingSensitive` is true.
    func saveSnippet(from item: ClipboardItem, confirmingSensitive: Bool) -> SnippetSaveOutcome {
        guard let text = SnippetLibrary.plainText(for: item) else { return .unavailable }
        if item.isSensitive && !confirmingSensitive {
            return .needsSensitiveConfirmation
        }
        guard let snippet = createSnippet(
            title: SnippetLibrary.title(fromBody: text),
            body: text,
            category: nil,
            localOnly: item.isSensitive
        ) else {
            return .unavailable
        }
        if !item.isSensitive {
            lastCaptureStatus = SnippetLibrary.savedStatus
        }
        return .saved(snippet)
    }

    func requestSaveSnippet(fromItemID id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isExpired() else {
            lastCaptureStatus = SnippetLibrary.unavailableStatus
            return
        }
        switch saveSnippet(from: item, confirmingSensitive: false) {
        case .saved:
            break
        case .needsSensitiveConfirmation:
            sensitiveSnippetPrompt = SensitiveSnippetPrompt(itemID: item.id)
        case .unavailable:
            lastCaptureStatus = SnippetLibrary.unavailableStatus
        }
    }

    func confirmSensitiveSnippetSave() {
        guard let prompt = sensitiveSnippetPrompt,
              let item = items.first(where: { $0.id == prompt.itemID }),
              !item.isExpired() else {
            sensitiveSnippetPrompt = nil
            lastCaptureStatus = SnippetLibrary.unavailableStatus
            return
        }
        sensitiveSnippetPrompt = nil
        if case .unavailable = saveSnippet(from: item, confirmingSensitive: true) {
            lastCaptureStatus = SnippetLibrary.unavailableStatus
        }
    }

    func cancelSensitiveSnippetSave() {
        sensitiveSnippetPrompt = nil
    }

    func loadSnippets() -> [SavedSnippet] {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: snippetsURL)
            } catch CocoaError.fileReadNoSuchFile {
                return []
            }
            return try JSONDecoder().decode([SavedSnippet].self, from: data)
        } catch {
            snippetLoadError = "片段文件读取失败，已保留原文件。新片段暂存于内存，请恢复片段文件后重启应用。"
            lastCaptureStatus = snippetLoadError ?? "片段文件读取失败"
            return []
        }
    }

    func schedulePersistSnippets() {
        guard snippetLoadError == nil else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(snippets)
        } catch {
            lastCaptureStatus = "保存片段失败"
            return
        }
        pendingSnippetPersist?.cancel()
        let generation = snippetWriter.stage(data)
        let writer = snippetWriter
        let writerBlock: @Sendable () -> Void = {
            if writer.writeIfCurrent(generation) == .failed {
                Task { @MainActor in
                    ClipFlowStore.shared.lastCaptureStatus = "保存片段失败"
                }
            }
        }
        let workItem = DispatchWorkItem(qos: .utility, flags: .assignCurrentContext, block: writerBlock)
        pendingSnippetPersist = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func flushPendingSnippets() {
        pendingSnippetPersist?.cancel()
        pendingSnippetPersist = nil
        if snippetWriter.flush() == .failed {
            lastCaptureStatus = "保存片段失败"
        }
    }

    func persistSnippetTombstones() {
        guard let data = try? JSONEncoder().encode(snippetTombstones) else { return }
        defaults.set(data, forKey: Keys.snippetSyncTombstones)
    }

    var syncableSnippets: [SavedSnippet] {
        snippets.filter { !$0.localOnly }
    }

    func applyCloudSnippets(_ remote: [SavedSnippet], tombstones: [UUID: Date]) {
        let localOnly = snippets.filter(\.localOnly)
        let localOnlyIDs = Set(localOnly.map(\.id))
        let combined = SnippetLibrary.sorted(localOnly + remote.filter { !localOnlyIDs.contains($0.id) })
        if combined != SnippetLibrary.sorted(snippets) {
            isApplyingCloudSnapshot = true
            snippets = combined
            isApplyingCloudSnapshot = false
        }
        if snippetTombstones != tombstones {
            snippetTombstones = tombstones
        }
    }
}
