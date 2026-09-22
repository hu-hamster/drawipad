import PencilKit
import SwiftUI
import UIKit

// MARK: - 画布（固定页面尺寸，等比缩放适配屏幕）

/// PKCanvasView 是 UIScrollView 子类：contentSize = 页面逻辑尺寸，
/// zoomScale 锁定为适配比例，实现"页面坐标系固定 + 屏幕自适应"，
/// 笔迹数据坐标与 Mac 端完全一致。
final class FittingPKCanvas: PKCanvasView {
    var pageSize: CGSize = CGSize(width: 1366, height: 1024) {
        didSet {
            if oldValue != pageSize {
                lastAppliedFit = -1
                setNeedsLayout()
            }
        }
    }
    /// 布局时上报自身屏幕尺寸（用于新建页面的全屏尺寸）。
    var onLayoutSize: ((CGSize) -> Void)?

    private var lastAppliedFit: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        onLayoutSize?(bounds.size)
        guard pageSize.width > 1, pageSize.height > 1 else { return }
        let fit = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        guard abs(fit - lastAppliedFit) > 0.0001 else {
            // 布局参数未变，避免重复设置 zoom/inset 造成布局循环
            contentSize = pageSize
            return
        }
        lastAppliedFit = fit
        minimumZoomScale = fit
        maximumZoomScale = fit
        zoomScale = fit
        contentSize = pageSize
        let horizontal = max(0, (bounds.width - pageSize.width * fit) / 2)
        let vertical = max(0, (bounds.height - pageSize.height * fit) / 2)
        contentInset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical, right: horizontal
        )
    }
}

// MARK: - 实时点采集

/// 只观察不消费的手势识别器：挂在 PKCanvasView 上旁路采集 Apple Pencil
/// 触摸点（含合并触摸），不影响 PencilKit 自身绘制。
final class StrokeObserver: UIGestureRecognizer {
    var onBegan: (() -> Void)?
    var onPoints: (([LivePoint]) -> Void)?
    var onEnded: (() -> Void)?
    /// 采集点所属视图（页面坐标系），延迟解析（内容视图懒加载）。
    var coordinateViewProvider: (() -> UIView?)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        super.init(target: nil, action: nil)
    }

    private var active = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, touch.type == .pencil else { return }
        active = true
        onBegan?()
        emit(touch, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard active, let touch = touches.first else { return }
        emit(touch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish()
    }

    private func finish() {
        guard active else { return }
        active = false
        onEnded?()
    }

    private func emit(_ touch: UITouch, event: UIEvent) {
        guard let view = coordinateViewProvider?() else { return }
        let touches = event.coalescedTouches(for: touch) ?? [touch]
        var points: [LivePoint] = []
        points.reserveCapacity(touches.count)
        for item in touches {
            let location = item.location(in: view)
            let maxForce = item.maximumPossibleForce
            let force = maxForce > 0 ? Double(item.force / maxForce) : 0.5
            points.append(
                LivePoint(
                    x: Double(location.x),
                    y: Double(location.y),
                    force: force,
                    time: Double(item.timestamp)
                )
            )
        }
        if !points.isEmpty {
            onPoints?(points)
        }
    }
}

// MARK: - SwiftUI 桥接

/// 画布容器：白纸（页面边界）+ 底图 + 透明 PencilKit 画布 三层。
/// 页面区域 = 按页面比例适配屏幕的居中矩形（与 FittingPKCanvas 的
/// zoom/inset 居中结果一致），页面外露出浅灰边界。
final class PadCanvasContainer: UIView {
    let paperView = UIView()
    let bgImageView = UIImageView()
    let canvas: FittingPKCanvas

    var pageSize: CGSize {
        get { canvas.pageSize }
        set {
            canvas.pageSize = newValue
            setNeedsLayout()
        }
    }

    init(canvas: FittingPKCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.949, alpha: 1)
        paperView.backgroundColor = .white
        paperView.clipsToBounds = true
        bgImageView.contentMode = .scaleAspectFit
        addSubview(paperView)
        addSubview(bgImageView)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1,
              pageSize.width > 1, pageSize.height > 1 else { return }
        let fit = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        let size = CGSize(width: pageSize.width * fit, height: pageSize.height * fit)
        let rect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        paperView.frame = rect
        bgImageView.frame = rect
        canvas.frame = bounds
    }

    func setBackground(_ image: UIImage?) {
        bgImageView.image = image
    }
}

struct PadCanvasView: UIViewRepresentable {
    @ObservedObject var model: PadModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> PadCanvasContainer {
        let canvas = FittingPKCanvas()
        canvas.backgroundColor = .clear
        canvas.delegate = context.coordinator
        canvas.drawing = model.canvasDrawing
        canvas.tool = model.currentTool
        context.coordinator.appliedRevision = model.drawingRevision

        let container = PadCanvasContainer(canvas: canvas)
        model.canvasRef = canvas
        model.canvasContainer = container

        // 实时点采集（旁路观察，不影响 PencilKit 输入）
        let observer = StrokeObserver(target: nil, action: nil)
        observer.coordinateViewProvider = { [weak canvas] in
            canvas?.subviews.first ?? canvas
        }
        observer.onBegan = { [weak model] in
            model?.liveStrokeBegan()
        }
        observer.onPoints = { [weak model] points in
            model?.liveStrokeAppend(points)
        }
        observer.onEnded = { [weak model] in
            model?.liveStrokeEnded()
        }
        canvas.addGestureRecognizer(observer)
        context.coordinator.observer = observer

        canvas.onLayoutSize = { [weak model] size in
            model?.canvasScreenSize = size
        }
        return container
    }

    func updateUIView(_ container: PadCanvasContainer, context: Context) {
        let pageSize = model.currentPageSize ?? CGSize(width: 1366, height: 1024)
        if container.pageSize != pageSize {
            container.pageSize = pageSize
        }
        if context.coordinator.appliedRevision != model.drawingRevision {
            context.coordinator.appliedRevision = model.drawingRevision
            container.canvas.drawing = model.canvasDrawing
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let model: PadModel
        var observer: StrokeObserver?
        var appliedRevision = -1

        init(model: PadModel) {
            self.model = model
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            model.canvasDrawingDidChange()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            model.canvasDidEndStroke()
        }
    }
}
