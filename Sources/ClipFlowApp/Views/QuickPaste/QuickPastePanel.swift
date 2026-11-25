import AppKit

final class QuickPastePanel: NSPanel {
    weak var clipboardList: QuickPasteListView?
    private var routedRowPress = false
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            routedRowPress = clipboardList?.routeMouseDown(event) == true
            if routedRowPress { return }
        } else if routedRowPress && (event.type == .leftMouseUp || event.type == .leftMouseDragged) {
            if event.type == .leftMouseUp { routedRowPress = false }
            return
        }
        super.sendEvent(event)
    }
    var onCancelInspector: (() -> Bool)?
    var onCancelPanel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if onCancelInspector?() == true { return }
        if let onCancelPanel { onCancelPanel() }
        else { orderOut(nil) }
    }
}
