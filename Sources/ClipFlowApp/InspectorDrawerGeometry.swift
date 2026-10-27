import AppKit
import SwiftUI

/// Retain geometry, never a source row: lazy lists may recycle or remove it.
@MainActor
struct InspectorSourceAnchor {
    private weak var view: NSView?
    private let identifier: NSUserInterfaceItemIdentifier?
    init(view: NSView) { self.view = view; identifier = view.identifier }
    static func callback(for view: NSView, fallback: @escaping () -> Void,
                         anchored: ((InspectorSourceAnchor) -> Void)?) -> () -> Void {
        { [weak view] in
            guard let view else { return }
            if let anchored {
                let source = InspectorSourceAnchor(view: view)
                guard source.rectInWindow() != nil else { return }
                anchored(source)
            } else { fallback() }
        }
    }
    func rectInWindow() -> CGRect? {
        guard let view, let window = view.window, window.isVisible,
              !view.isHiddenOrHasHiddenAncestor, view.identifier == identifier else { return nil }
        var rect = view.convert(view.visibleRect.intersection(view.bounds), to: nil)
        if let clip = view.enclosingScrollView?.contentView {
            rect = rect.intersection(clip.convert(clip.bounds, to: nil))
        }
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}

struct InspectorDrawerLayout: Equatable {
    let shellRect: CGRect
    let coverTop: CGFloat
    let coverHeight: CGFloat
    let lipDepth: CGFloat

    static func resolve(progress: CGFloat, sourceRectInWindow: CGRect?,
                        destinationRectInWindow destination: CGRect, footerHeight: CGFloat,
                        reduceMotion: Bool) -> Self {
        let width = max(1, destination.width.isFinite ? destination.width : 1)
        let height = max(1, destination.height.isFinite ? destination.height : 1)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let p = min(1, max(0, progress.isFinite ? progress : 0))
        let footer = min(height, max(0, footerHeight))
        let source: CGRect
        if let rect = sourceRectInWindow, !rect.isNull, rect.width > 0, rect.height > 0,
           rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite {
            // Window coordinates are bottom-up; SwiftUI drawing coordinates are top-down.
            source = CGRect(x: rect.minX - destination.minX, y: destination.maxY - rect.maxY,
                            width: rect.width, height: rect.height)
        } else {
            source = CGRect(x: 8, y: height * 0.34, width: max(1, width - 16), height: min(96, height))
        }
        let expand = reduceMotion ? 1 : 1 - pow(1 - min(1, p / 0.68), 3)
        let t = min(1, max(0, (p - 0.12) / 0.70))
        let slide = reduceMotion ? 1 : t * t * (3 - 2 * t)
        func mix(_ a: CGFloat, _ b: CGFloat, _ fraction: CGFloat) -> CGFloat { a + (b - a) * fraction }
        let shell = CGRect(x: mix(source.minX, 0, expand), y: mix(source.minY, 0, expand),
            width: mix(source.width, width, expand), height: mix(source.height, height, expand))
        let top = min(shell.maxY, max(shell.minY, mix(source.minY, height - footer, slide)))
        return Self(shellRect: reduceMotion ? bounds : shell, coverTop: reduceMotion ? height - footer : top,
                    coverHeight: reduceMotion ? footer : max(0, shell.maxY - top), lipDepth: 10 * expand)
    }
}

/// Non-interactive native anchors keep window-space transforms independent of list preferences.
struct InspectorFrameReader: NSViewRepresentable {
    var name = "ClipFlowInspector.drawer"
    var onFrame: (CGRect) -> Void = { _ in }
    func makeNSView(context: Context) -> InspectorGeometryView {
        let view = InspectorGeometryView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        view.onFrame = onFrame
        return view
    }
    func updateNSView(_ view: InspectorGeometryView, context: Context) {
        view.onFrame = onFrame
        view.report()
    }
}

final class InspectorGeometryView: NSView {
    var onFrame: (CGRect) -> Void = { _ in }
    private var reported: CGRect?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reported = nil; report() }
    override func layout() { super.layout(); report() }
    func report() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let rect = convert(bounds, to: nil)
        guard rect != reported else { return }
        reported = rect
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.reported == rect else { return }
            self.onFrame(rect)
        }
    }
}

struct InspectorDrawerCoverShape: Shape {
    var lipDepth: CGFloat
    func path(in rect: CGRect) -> Path {
        let depth = min(lipDepth, max(0, rect.height / 3))
        let r = min(16, rect.height / 3, rect.width / 4)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + min(60, rect.width * 0.23), y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.minX + min(96, rect.width * 0.37), y: rect.minY + depth),
            control1: CGPoint(x: rect.minX + min(74, rect.width * 0.28), y: rect.minY),
            control2: CGPoint(x: rect.minX + min(80, rect.width * 0.31), y: rect.minY + depth))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + depth))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + depth + r),
                          control: CGPoint(x: rect.maxX, y: rect.minY + depth))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
