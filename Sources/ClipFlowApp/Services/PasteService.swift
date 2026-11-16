import AppKit

@MainActor
final class PasteService {
    private let store: ClipFlowStore
    private let pasteboard: NSPasteboard
    private let commitPaste: @MainActor (NSRunningApplication?) -> Void
    weak var monitor: ClipboardMonitor?

    init(
        store: ClipFlowStore,
        pasteboard: NSPasteboard = .general,
        commitPaste: @escaping @MainActor (NSRunningApplication?) -> Void = PasteShortcutSender.commit
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.commitPaste = commitPaste
    }

    func paste(_ item: ClipboardItem, preferredTarget: NSRunningApplication?, plainText: Bool = false) {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return
        }
        if item.secretPayloadUnavailable == true {
            store.lastCaptureStatus = SensitivePayloadStore.unreadableStatus
            return
        }
        if plainText && !PlainTextPaste.canPasteAsPlainText(item) {
            store.lastCaptureStatus = "这项内容不能粘贴为纯文本"
            return
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        pasteboard.clearContents()
        guard restore(item, to: pasteboard, plainText: plainText) else {
            store.lastCaptureStatus = plainText
                ? "恢复纯文本失败"
                : (item.isImage ? "图片资源不可用，请重新复制一次" : "恢复剪贴内容失败")
            return
        }
        // Record the change before activating the target. Activation can spin the run loop,
        // and a poll in that window must not ingest this write as a new or reduced copy.
        notePasteboardWrite(of: item, plainText: plainText)

        // Ask only once the user actually pastes. Without trust, the clipboard copy stands.
        guard store.isAccessibilityTrusted(prompt: true) else {
            store.notePasteBlockedByAccessibility()
            return
        }

        let targetApp = preferredTarget ?? NSWorkspace.shared.frontmostApplication
        commitPaste(targetApp)
        let name = targetApp?.localizedName ?? "前台应用"
        store.lastCaptureStatus = plainText ? "已粘贴纯文本到 \(name)" : "已粘贴到 \(name)"
    }

    func pastePlainText(_ text: String, preferredTarget: NSRunningApplication?, announcingPlain: Bool = false) {
        guard SnippetLibrary.hasBody(text) else {
            store.lastCaptureStatus = SnippetLibrary.emptyBodyStatus
            return
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }
        guard PlainTextPaste.write(text, to: pasteboard) else {
            store.lastCaptureStatus = announcingPlain ? "恢复纯文本失败" : "恢复剪贴内容失败"
            return
        }
        guard store.isAccessibilityTrusted(prompt: true) else {
            store.notePasteBlockedByAccessibility()
            return
        }
        let targetApp = preferredTarget ?? NSWorkspace.shared.frontmostApplication
        commitPaste(targetApp)
        let name = targetApp?.localizedName ?? "前台应用"
        store.lastCaptureStatus = announcingPlain ? "已粘贴纯文本到 \(name)" : "已粘贴到 \(name)"
    }

    @discardableResult
    func copyPlainText(_ text: String) -> Bool {
        guard SnippetLibrary.hasBody(text) else {
            store.lastCaptureStatus = SnippetLibrary.emptyBodyStatus
            return false
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }
        guard PlainTextPaste.write(text, to: pasteboard) else {
            store.lastCaptureStatus = "复制到剪贴板失败"
            return false
        }
        store.lastCaptureStatus = "已复制到剪贴板，可在目标输入框中手动粘贴"
        return true
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem, plainText: Bool = false) -> Bool {
        store.purgeExpired()
        guard let item = store.item(withID: item.id) else {
            store.lastCaptureStatus = "内容已过期或已删除"
            return false
        }
        if item.secretPayloadUnavailable == true {
            store.lastCaptureStatus = SensitivePayloadStore.unreadableStatus
            return false
        }
        if plainText && !PlainTextPaste.canPasteAsPlainText(item) {
            store.lastCaptureStatus = "这项内容不能复制为纯文本"
            return false
        }
        defer { monitor?.ignoreCurrentPasteboardUpdate() }

        pasteboard.clearContents()
        guard restore(item, to: pasteboard, plainText: plainText) else {
            store.lastCaptureStatus = plainText
                ? "复制纯文本失败"
                : (item.isImage ? "图片资源不可用，请重新复制一次" : "复制到剪贴板失败")
            return false
        }
        notePasteboardWrite(of: item, plainText: plainText)

        store.lastCaptureStatus = plainText
            ? "已复制纯文本到剪贴板，可在目标输入框中手动粘贴"
            : "已复制到剪贴板，可在目标输入框中手动粘贴"
        return true
    }

    /// Puts the original representations back and does not send a paste keystroke.
    @discardableResult
    func copyOriginalToClipboard(_ item: ClipboardItem) -> Bool {
        guard copyToClipboard(item) else { return false }
        store.lastCaptureStatus = SpreadsheetClipboard.copyOnlyStatus
        return true
    }

    /// Inserts a matching block of cells in Excel, then pastes the original representations.
    /// If Excel refuses the Apple event, falls back to an ordinary paste.
    func insertIntoExcel(
        _ item: ClipboardItem,
        shift: SpreadsheetShift,
        runner: @MainActor (String) -> ExcelInsertOutcome = ExcelAppleScript.run
    ) {
        guard let grid = SpreadsheetInsertRange.measure(tsv: item.fullText) else {
            store.lastCaptureStatus = "这份内容没有可插入的表格范围"
            return
        }
        guard ExcelAvailability.isRunning() else {
            paste(item, preferredTarget: nil)
            store.lastCaptureStatus = "Excel 没有在运行，已改为普通粘贴。"
            return
        }
        let excel = ExcelAvailability.application()
        switch ExcelCellInserter.insert(rows: grid.rows, columns: grid.columns, shift: shift, runner: runner) {
        case .inserted:
            if excel != nil {
                guard restore(item, to: pasteboard) else {
                    store.lastCaptureStatus = "恢复剪贴内容失败"
                    return
                }
                monitor?.noteSpreadsheetPasteboardWrite()
                if ExcelAppleScript.run(SpreadsheetReplay.pasteScript) == .inserted {
                    let formats = SpreadsheetReplay.cells(in: item.extraTypes ?? [], htmlData: item.htmlData)
                    if let script = SpreadsheetReplay.formatScript(for: formats) {
                        _ = ExcelAppleScript.run(script)
                    }
                } else {
                    commitPaste(excel)
                }
            } else {
                paste(item, preferredTarget: excel)
            }
            store.lastCaptureStatus = "已在 Excel 中插入 \(grid.rows)×\(grid.columns) 个单元格（\(shift.statusWord)）并粘贴"
        case .notPermitted:
            paste(item, preferredTarget: excel)
            store.lastCaptureStatus = "未获得控制 Excel 的权限，已改为普通粘贴。"
        case .failed:
            paste(item, preferredTarget: excel)
            store.lastCaptureStatus = "无法在当前工作表插入单元格，已改为普通粘贴。"
        }
    }

    func restore(_ item: ClipboardItem, to pasteboard: NSPasteboard, plainText: Bool = false) -> Bool {
        if plainText {
            guard PlainTextPaste.canPasteAsPlainText(item) else { return false }
            return PlainTextPaste.write(item.fullText, to: pasteboard)
        }
        if item.isImage {
            guard let imageData = store.imageData(for: item),
                  let image = NSImage(data: imageData) else {
                return false
            }

            if pasteboard.writeObjects([image]) {
                return true
            }

            return pasteboard.setData(imageData, forType: .png)
        }

        let snapshot = ClipboardRepresentations.Snapshot(
            rtfData: item.rtfData,
            htmlData: item.htmlData,
            fileURLs: item.fileURLs ?? [],
            extraTypes: item.extraTypes ?? []
        )
        return ClipboardRepresentations.write(plainText: item.fullText, snapshot: snapshot, to: pasteboard)
    }

    private func notePasteboardWrite(of item: ClipboardItem, plainText: Bool) {
        if !plainText && SpreadsheetImageFollowUp.isSpreadsheetTextItem(item) {
            monitor?.noteSpreadsheetPasteboardWrite()
        } else {
            monitor?.ignoreCurrentPasteboardUpdate()
        }
    }
}
