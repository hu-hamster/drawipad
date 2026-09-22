import AppKit
import PencilKit
import SwiftUI

/// Mac 端画布页（Excalidraw 风格）：
/// 无限板面（缩放/平移）+ 页面纸张（白底 + 点阵网格 + 底图 + 墨迹 + 实时预览）。
/// 说明：PKCanvasView 仅存在于 iOS，macOS 用 PKDrawing 位图渲染显示。
struct MacCanvasPage: NSViewRepresentable {
    let drawing: PKDrawing
    let revision: Int
    let live: LiveStroke?
    let pageSize: CGSize
    let backgroundImage: NSImage?
    let model: MacAppModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BoardCanvasView {
        let board = BoardCanvasView()
        board.setContent(pageSize: pageSize)
        board.apply(drawing: drawing, revision: revision)
        board.setBackground(backgroundImage)
        board.onZoomChange = { [weak model] percent in
            model?.zoomPercent = percent
        }
        context.coordinator.appliedRevision = revision
        context.coordinator.board = board
        model.boardView = board
        return board
    }

    func updateNSView(_ board: BoardCanvasView, context: Context) {
        board.setContent(pageSize: pageSize)
        if context.coordinator.appliedRevision != revision {
            context.coordinator.appliedRevision = revision
            board.apply(drawing: drawing, revision: revision)
        }
        board.setBackground(backgroundImage)
        board.setLive(live)
    }

    final class Coordinator {
        var appliedRevision = -1
        weak var board: BoardCanvasView?
    }
}

/// 无限板面：承载页面容器，支持触控板捏合缩放、滚轮平移、⌘/⌥ 滚轮缩放。
/// 页面外的区域填充浅灰，与白纸形成层次。
final class BoardCanvasView: NSView {
    override var isFlipped: Bool { true }

    let content = PageContainerView()
    var onZoomChange: ((Int) -> Void)?

    private var scale: CGFloat = 1
    private var offset: CGPoint = .zero
    private var fitScale: CGFloat = 1
    private var fitPending = true
    /// 用户是否手动缩放/平移过（此前窗口尺寸变化自动重新适配）。
    private var userAdjusted = false
    private var lastBoundsSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 内容更新

    func setContent(pageSize: CGSize) {
        guard content.pageSize != pageSize else { return }
        content.pageSize = pageSize
        fitPending = true
        needsLayout = true
    }

    func apply(drawing: PKDrawing, revision: Int) {
        content.apply(drawing: drawing, revision: revision)
    }

    func setBackground(_ image: NSImage?) {
        content.setBackground(image)
    }

    func setLive(_ live: LiveStroke?) {
        content.setLive(live)
    }

    // MARK: - 布局与变换

    override func layout() {
        super.layout()
        guard content.pageSize.width > 1, content.pageSize.height > 1,
              bounds.width > 40, bounds.height > 40 else { return }
        let boundsChanged = abs(bounds.width - lastBoundsSize.width) > 1
            || abs(bounds.height - lastBoundsSize.height) > 1
        lastBoundsSize = bounds.size
        if fitPending || (boundsChanged && !userAdjusted) {
            fitPending = false
            userAdjusted = false
            fitScale = min(
                bounds.width / content.pageSize.width,
                bounds.height / content.pageSize.height
            )
            scale = fitScale
            centerContent()
        }
        place()
    }

    private func centerContent() {
        let size = CGSize(
            width: content.pageSize.width * scale,
            height: content.pageSize.height * scale
        )
        offset = CGPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
    }

    private func place() {
        let size = CGSize(
            width: content.pageSize.width * scale,
            height: content.pageSize.height * scale
        )
        content.frame = CGRect(origin: offset, size: size)
        // bounds 保持页面逻辑尺寸 → 内部一切按比例缩放
        content.bounds = CGRect(origin: .zero, size: content.pageSize)
        notifyZoom()
    }

    private func notifyZoom() {
        let percent = Int((scale / max(fitScale, 0.0001) * 100).rounded())
        onZoomChange?(percent)
    }

    // MARK: - 缩放/平移 API（浮动控件调用）

    func zoomIn() {
        zoom(by: 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomOut() {
        zoom(by: 0.8, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func fit() {
        fitPending = true
        needsLayout = true
    }

    private func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let newScale = min(8, max(0.15, scale * factor))
        let ratio = newScale / scale
        offset.x = anchor.x - (anchor.x - offset.x) * ratio
        offset.y = anchor.y - (anchor.y - offset.y) * ratio
        scale = newScale
        place()
    }

    // MARK: - 事件

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control) {
            zoom(
                by: 1 - event.scrollingDeltaY * 0.01,
                around: convert(event.locationInWindow, from: nil)
            )
        } else {
            offset.x -= event.scrollingDeltaX
            offset.y -= event.scrollingDeltaY
            clampPan()
            place()
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        // 双指双击：在 适配 与 200% 间切换
        if abs(scale - fitScale) < 0.01 {
            let anchor = convert(event.locationInWindow, from: nil)
            let target = fitScale * 2
            let ratio = target / scale
            offset.x = anchor.x - (anchor.x - offset.x) * ratio
            offset.y = anchor.y - (anchor.y - offset.y) * ratio
            scale = target
            place()
        } else {
            fit()
        }
    }

    /// 防止页面被完全拖出视野。
    private func clampPan() {
        let width = content.pageSize.width * scale
        let height = content.pageSize.height * scale
        let margin: CGFloat = 120
        offset.x = min(max(offset.x, bounds.width - width - margin), margin + max(0, bounds.width - width))
        offset.y = min(max(offset.y, bounds.height - height - margin), margin + max(0, bounds.height - height))
        // 内容小于视图时居中锁定
        if width <= bounds.width { offset.x = (bounds.width - width) / 2 }
        if height <= bounds.height { offset.y = (bounds.height - height) / 2 }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 页面外板面底色
        NSColor(srgbRed: 0.945, green: 0.945, blue: 0.94, alpha: 1).setFill()
        bounds.fill()
    }
}

/// 页面容器：白纸 + 点阵网格 + 底图 + 墨迹 + 实时预览。
/// 自身 bounds 始终为页面逻辑尺寸（缩放由外层 BoardCanvasView 的 frame/bounds 差实现）。
final class PageContainerView: NSView {
    override var isFlipped: Bool { true }

    var pageSize: CGSize = CGSize(width: 1366, height: 1024) {
        didSet {
            if oldValue != pageSize {
                inkView.pageSize = pageSize
                needsLayout = true
            }
        }
    }

    private let paper = NSView()
    private let bgView = BackgroundImageView()
    private let grid = DotGridView()
    private let inkView = PageInkView()
    private let overlay = LiveInkOverlay()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        paper.wantsLayer = true
        paper.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(paper)
        addSubview(bgView)
        addSubview(grid)
        addSubview(inkView)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        guard pageSize.width > 1, pageSize.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let pageBounds = CGRect(origin: .zero, size: pageSize)
        paper.frame = pageBounds
        bgView.frame = pageBounds
        grid.frame = pageBounds
        // 墨迹层按页面原始比例等比缩放居中（bounds == pageSize 时即 1:1）
        let contentScale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        let size = CGSize(width: pageSize.width * contentScale, height: pageSize.height * contentScale)
        let frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        inkView.frame = frame
        inkView.bounds = pageBounds
        overlay.frame = frame
        overlay.bounds = pageBounds
    }

    func apply(drawing: PKDrawing, revision: Int) {
        inkView.setDrawing(drawing, revision: revision)
    }

    func setBackground(_ image: NSImage?) {
        bgView.image = image
    }

    func setLive(_ live: LiveStroke?) {
        overlay.configure(
            id: live?.id,
            color: live?.color,
            width: live.map { CGFloat($0.width) } ?? 3,
            points: live?.points ?? []
        )
    }
}

/// 页面底图（等比适配页面区域，保持比例不变形）。
final class BackgroundImageView: NSView {
    override var isFlipped: Bool { true }

    var image: NSImage? {
        didSet {
            if image !== oldValue {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / width, bounds.height / height)
        let size = CGSize(width: width * fit, height: height * fit)
        let frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.current?.cgContext.draw(cg, in: frame)
    }
}

/// Excalidraw 风格点阵网格（24pt 间距，仅绘制脏区）。
final class DotGridView: NSView {
    override var isFlipped: Bool { true }

    static let spacing: CGFloat = 24

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07))
        let step = Self.spacing
        let start = CGPoint(
            x: (floor(dirtyRect.minX / step) * step).rounded(.down),
            y: (floor(dirtyRect.minY / step) * step).rounded(.down)
        )
        var y = start.y
        while y <= dirtyRect.maxY {
            var x = start.x
            while x <= dirtyRect.maxX {
                context.fillEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                x += step
            }
            y += step
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }
}

/// 已提交墨迹的位图渲染视图（只读，不接受事件）。
final class PageInkView: NSView {
    override var isFlipped: Bool { true }

    var pageSize: CGSize = CGSize(width: 1366, height: 1024)

    private var drawing: PKDrawing?
    private var renderedRevision = -1
    private var inkImage: NSImage?

    func setDrawing(_ drawing: PKDrawing, revision: Int) {
        self.drawing = drawing
        if renderedRevision != revision {
            renderedRevision = revision
            renderInk()
        }
    }

    private func renderInk() {
        guard let drawing else {
            inkImage = nil
            needsDisplay = true
            return
        }
        let rect = CGRect(origin: .zero, size: pageSize)
        inkImage = drawing.image(from: rect, scale: 2)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let inkImage else { return }
        inkImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

/// 实时预览线：iPad 采集的原始点按压力变宽绘制，抬笔后由真实笔迹替换。
final class LiveInkOverlay: NSView {
    override var isFlipped: Bool { true }

    private var strokeID: UUID?
    private var color: NSColor = .black
    private var width: CGFloat = 3
    private var points: [LivePoint] = []
    private var lastRenderedCount = -1

    func configure(id: UUID?, color: NSColor?, width: CGFloat, points: [LivePoint]) {
        let idChanged = id != strokeID
        if idChanged {
            strokeID = id
            lastRenderedCount = -1
        }
        if let color {
            self.color = color
        }
        self.width = width
        if idChanged || points.count != lastRenderedCount || (id == nil && !self.points.isEmpty) {
            self.points = points
            lastRenderedCount = points.count
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let force = CGFloat(max(0.25, min(1, (a.force + b.force) / 2)))
            path.lineWidth = max(1.2, width * force)
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.line(to: CGPoint(x: b.x, y: b.y))
            path.stroke()
        }
    }
}
